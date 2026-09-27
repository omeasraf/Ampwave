import Foundation
import Observation
import StoreKit

extension Notification.Name {
  static let ampwaveAccessDidChange = Notification.Name("com.ampwave.accessDidChange")
}

enum AmpwavePurchasePolicy {
  static let annualID = "com.ome.Ampwave.annual.subscription"
  static let lifetimeID = "com.ome.Ampwave.lifetime.access"
  // Build numbers cannot identify paid owners: v1.0 shipped as build 40,
  // later releases reset the build number, and v1.2 build 9 was sold before
  // the free price took effect. Apple's signed original purchase date remains
  // stable across updates, so every production acquisition before this cutoff
  // keeps lifetime access.
  static let freeAcquisitionCutover = Date(timeIntervalSince1970: 1_791_288_000)

  static func isLegacyOwner(
    originalPurchaseDate: Date,
    isProduction: Bool
  ) -> Bool {
    // Sandbox and TestFlight transactions use synthetic purchase history and
    // must never grant a production lifetime entitlement.
    guard isProduction else { return false }
    return originalPurchaseDate < freeAcquisitionCutover
  }
}

enum AmpwaveAccess: Equatable {
  case checking
  case legacyOwner
  case lifetime
  case subscription
  case purchaseRequired
  case verificationUnavailable

  var isUnlocked: Bool {
    switch self {
    case .legacyOwner, .lifetime, .subscription: true
    default: false
    }
  }
}

@MainActor
@Observable
final class EntitlementManager {
  static let shared = EntitlementManager()

  private(set) var access: AmpwaveAccess = .checking
  private(set) var annualProduct: Product?
  private(set) var lifetimeProduct: Product?
  private(set) var offersSevenDayTrial = false
  private(set) var canReceiveIntroOffer = false
  private(set) var isUsingTestStore = false
  private(set) var isBusy = false
  private(set) var errorMessage: String?

  var canUseApp: Bool {
    #if os(iOS)
      access.isUnlocked
    #else
      true // The paid-to-free rollout is iOS-only for now.
    #endif
  }

  private var updatesTask: Task<Void, Never>?
  private var expiryTask: Task<Void, Never>?
  private var refreshing = false
  private var pendingRefresh = false
  private var loadingProducts = false
  private var lastVerifiedAnnualDeadline: Date?

  private init() {
    updatesTask = Task { [weak self] in
      for await result in Transaction.updates {
        guard let self else { return }
        if case .verified(let transaction) = result,
          [AmpwavePurchasePolicy.annualID, AmpwavePurchasePolicy.lifetimeID]
            .contains(transaction.productID)
        {
          await self.refresh()
          await transaction.finish()
        }
      }
    }
  }

  func refresh() async {
    guard !refreshing else {
      pendingRefresh = true
      DiagnosticLog.shared.log("storekit", "Entitlement refresh queued behind active refresh")
      return
    }
    refreshing = true
    DiagnosticLog.shared.log("storekit", "Entitlement refresh started")
    defer {
      refreshing = false
      DiagnosticLog.shared.log("storekit", "Entitlement refresh finished access=\(access)")
      if pendingRefresh {
        pendingRefresh = false
        Task { await self.refresh() }
      }
    }

    let appTransaction: AppTransaction?
    do {
      let result = try await AppTransaction.shared
      if case .verified(let verified) = result,
        verified.bundleID == Bundle.main.bundleIdentifier
      {
        appTransaction = verified
      } else {
        appTransaction = nil
      }
    } catch {
      DiagnosticLog.shared.log(
        "storekit",
        "App transaction unavailable error=\(String(reflecting: error))"
      )
      appTransaction = nil
    }
    DiagnosticLog.shared.log(
      "storekit",
      "App transaction resolved verified=\(appTransaction != nil) environment=\(appTransaction.map { String(describing: $0.environment) } ?? "none") originalVersion=\(appTransaction?.originalAppVersion ?? "none") originalPurchaseDate=\(appTransaction.map { String(describing: $0.originalPurchaseDate) } ?? "none")"
    )
    if let appTransaction {
      isUsingTestStore = appTransaction.environment != .production
    }

    var ownsLifetime = false
    var hasActiveAnnual = false
    var nextExpiration: Date?
    for await result in Transaction.currentEntitlements {
      guard case .verified(let transaction) = result else { continue }
      switch transaction.productID {
      case AmpwavePurchasePolicy.lifetimeID:
        ownsLifetime = true
      case AmpwavePurchasePolicy.annualID:
        hasActiveAnnual = true // Includes an Apple-granted billing grace period.
        lastVerifiedAnnualDeadline = max(
          transaction.expirationDate ?? Date(), Date()
        ).addingTimeInterval(24 * 60 * 60)
        if let expiration = transaction.expirationDate, expiration > Date() {
          nextExpiration = expiration
        }
      default:
        break
      }
    }
    DiagnosticLog.shared.log(
      "storekit",
      "Current entitlements resolved lifetime=\(ownsLifetime) annual=\(hasActiveAnnual)"
    )

    let resolved: AmpwaveAccess
    if ownsLifetime {
      resolved = .lifetime
    } else if let appTransaction,
      AmpwavePurchasePolicy.isLegacyOwner(
        originalPurchaseDate: appTransaction.originalPurchaseDate,
        isProduction: appTransaction.environment == .production
      )
    {
      resolved = .legacyOwner
    } else if hasActiveAnnual {
      resolved = .subscription
    } else if appTransaction != nil {
      resolved = .purchaseRequired
    } else {
      // Never sell someone a second copy because Apple couldn't verify the
      // app purchase. The customer can retry or explicitly tap Restore.
      resolved = .verificationUnavailable
    }

    // Keep a previously verified permanent purchase through a transient
    // outage. Annual access has a bounded offline grace after its last
    // verified term; it must not stay unlocked indefinitely without StoreKit.
    let mayKeepVerifiedAccess = access == .legacyOwner || access == .lifetime
      || (access == .subscription && Date() < (lastVerifiedAnnualDeadline ?? .distantPast))
    if resolved != .verificationUnavailable || !mayKeepVerifiedAccess {
      setAccess(resolved)
    }
    scheduleExpirationCheck(nextExpiration)

    if resolved != .legacyOwner && resolved != .lifetime,
      annualProduct == nil || lifetimeProduct == nil || trialConfigurationPending
    {
      await loadProducts()
    }
  }

  func loadProducts() async {
    guard !loadingProducts else { return }
    loadingProducts = true
    defer { loadingProducts = false }

    let requestedIDs = [
      AmpwavePurchasePolicy.annualID,
      AmpwavePurchasePolicy.lifetimeID,
    ]
    DiagnosticLog.shared.log(
      "storekit",
      "Loading products ids=\(requestedIDs.joined(separator: ","))"
    )

    do {
      let products = try await Product.products(for: requestedIDs)
      annualProduct = products.first {
        $0.id == AmpwavePurchasePolicy.annualID && $0.type == .autoRenewable
          && $0.subscription?.subscriptionPeriod.unit == .year
          && $0.subscription?.subscriptionPeriod.value == 1
      }
      lifetimeProduct = products.first {
        $0.id == AmpwavePurchasePolicy.lifetimeID && $0.type == .nonConsumable
      }
      let offer = annualProduct?.subscription?.introductoryOffer
      offersSevenDayTrial = offer?.paymentMode == .freeTrial
        && offer?.period.unit == .week && offer?.period.value == 1
      canReceiveIntroOffer = await annualProduct?.subscription?.isEligibleForIntroOffer ?? false
      let returnedProducts = products
        .map { "\($0.id):\($0.type)" }
        .sorted()
        .joined(separator: ",")
      DiagnosticLog.shared.log(
        "storekit",
        "Products returned count=\(products.count) values=\(returnedProducts.isEmpty ? "none" : returnedProducts) annualLoaded=\(annualProduct != nil) lifetimeLoaded=\(lifetimeProduct != nil) sevenDayTrial=\(offersSevenDayTrial) introEligible=\(canReceiveIntroOffer)"
      )

      switch (annualProduct, lifetimeProduct) {
      case (.some, .some):
        errorMessage = trialConfigurationPending
          ? "The App Store hasn't made the 7-day free trial available yet. Try again shortly. Ampwave won't start a paid yearly plan until the trial is confirmed."
          : nil
      case (.none, .none):
        errorMessage = "The App Store hasn't made Ampwave's purchase options available yet. Please try again shortly."
      case (.none, .some):
        errorMessage = "The yearly plan is temporarily unavailable. Lifetime access is still available."
      case (.some, .none):
        errorMessage = "Lifetime access is temporarily unavailable. The yearly plan is still available."
      }
    } catch {
      DiagnosticLog.shared.log(
        "storekit",
        "Product load failed error=\(String(reflecting: error))"
      )
      errorMessage = "Could not load App Store prices. Please try again."
    }
  }

  var trialAvailable: Bool {
    offersSevenDayTrial && canReceiveIntroOffer
  }

  var trialConfigurationPending: Bool {
    annualProduct != nil && canReceiveIntroOffer && !offersSevenDayTrial
  }

  func subscribe() async {
    // Do not sell a full-price first subscription when the promised trial
    // wasn't configured in App Store Connect. Returning subscribers who have
    // used an introductory offer may subscribe at the regular price.
    guard access == .purchaseRequired else { return }
    guard !canReceiveIntroOffer || offersSevenDayTrial else {
      errorMessage = "The App Store hasn't confirmed the 7-day free trial yet. Please try again shortly."
      return
    }
    await purchase(annualProduct)
  }

  func buyLifetime() async {
    guard access == .purchaseRequired else { return }
    await purchase(lifetimeProduct)
  }

  private func purchase(_ product: Product?) async {
    guard !isBusy else { return }
    guard let product else { await loadProducts(); return }
    isBusy = true
    errorMessage = nil
    defer { isBusy = false }
    do {
      switch try await product.purchase() {
      case .success(.verified(let transaction)):
        if transaction.revocationDate == nil {
          if transaction.productID == AmpwavePurchasePolicy.lifetimeID {
            setAccess(.lifetime)
          } else if transaction.productID == AmpwavePurchasePolicy.annualID,
            (transaction.expirationDate ?? .distantPast) > Date()
          {
            setAccess(.subscription)
          }
        }
        await refresh()
        await transaction.finish()
      case .success(.unverified):
        errorMessage = "Apple couldn't verify the purchase. Try Restore Purchases."
      case .pending:
        errorMessage = "This purchase is awaiting approval. Access will update when Apple completes it."
      case .userCancelled:
        break
      @unknown default:
        errorMessage = "The purchase did not complete. Please try again."
      }
    } catch {
      errorMessage = error.localizedDescription
    }
  }

  func restorePurchases() async {
    guard !isBusy else { return }
    isBusy = true
    errorMessage = nil
    defer { isBusy = false }
    do {
      try await AppStore.sync() // Only after an explicit Restore tap.
      // Refresh the app transaction as well as in-app transactions. This is
      // what proves that someone downloaded the earlier paid App Store build.
      // It may prompt for authentication, so it only runs from this button.
      _ = try await AppTransaction.refresh()
      await refresh()
      if !access.isUnlocked {
        errorMessage = isUsingTestStore
          ? "TestFlight uses sandbox purchase history and can't verify a previous paid App Store download. The App Store release will check your real purchase history."
          : "No active subscription, lifetime purchase, or earlier paid Ampwave download was found for this App Store account."
      }
    } catch {
      errorMessage = error.localizedDescription
    }
  }

  private func scheduleExpirationCheck(_ expiration: Date?) {
    expiryTask?.cancel()
    guard access == .subscription else { return }
    let delay = expiration.map { max(1, $0.timeIntervalSinceNow + 1) } ?? 15 * 60
    expiryTask = Task { [weak self] in
      try? await Task.sleep(for: .seconds(delay))
      guard !Task.isCancelled else { return }
      await self?.refresh()
    }
  }

  private func setAccess(_ newAccess: AmpwaveAccess) {
    guard access != newAccess else { return }
    access = newAccess
    NotificationCenter.default.post(name: .ampwaveAccessDidChange, object: nil)
  }
}
