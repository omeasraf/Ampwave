import StoreKit
internal import SwiftUI

/// The first screen for new App Store customers and the access screen for a
/// lapsed subscription. No app data is removed when access ends.
struct AccessGateView: View {
  @State private var purchases = EntitlementManager.shared
  @Environment(ThemeManager.self) private var theme

  private var annualPrice: String? { purchases.annualProduct?.displayPrice }
  private var lifetimePrice: String? { purchases.lifetimeProduct?.displayPrice }

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 25) {
        Image(systemName: "waveform.circle.fill")
          .font(.system(size: 68))
          .foregroundStyle(theme.accentColor)
          .accessibilityHidden(true)

        VStack(alignment: .leading, spacing: 12) {
          Text(title)
            .font(.largeTitle.bold())
          Text(subtitle)
            .font(.body)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }

        VStack(alignment: .leading, spacing: 15) {
          Label("Your music, playlists, and lyrics", systemImage: "music.note.list")
          Label("Local, Jellyfin, and Plex libraries", systemImage: "externaldrive.connected.to.line.below")
          Label("One set of features, whichever plan you choose", systemImage: "checkmark.seal")
        }
        .font(.subheadline)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(20)
        .background(theme.cardBackgroundColor, in: RoundedRectangle(cornerRadius: 20))

        if let errorMessage = purchases.errorMessage {
          Text(errorMessage)
            .font(.footnote)
            .foregroundStyle(.orange)
            .fixedSize(horizontal: false, vertical: true)
        }

        if purchases.access == .purchaseRequired {
          VStack(spacing: 12) {
            Button {
              Task { await purchases.subscribe() }
            } label: {
              VStack(spacing: 4) {
                Text(annualActionTitle)
                  .font(.headline)
                if let annualPrice {
                  Text(annualActionDetail(price: annualPrice))
                    .font(.subheadline)
                }
              }
              .frame(maxWidth: .infinity)
              .padding(.vertical, 7)
            }
            .buttonStyle(.borderedProminent)
            .disabled(purchases.isBusy || annualPrice == nil
                      || purchases.trialConfigurationPending)

            Button {
              Task { await purchases.buyLifetime() }
            } label: {
              Text(lifetimePrice.map { "Lifetime access · \($0) once" }
                   ?? "Loading lifetime price…")
                .frame(maxWidth: .infinity)
                .padding(.vertical, 7)
            }
            .buttonStyle(.bordered)
            .disabled(purchases.isBusy || lifetimePrice == nil)
          }
          .controlSize(.large)
        }

        if purchases.access == .subscription {
          Label("Your annual access is active", systemImage: "checkmark.circle.fill")
            .foregroundStyle(theme.accentColor)
        }

        if purchases.access == .legacyOwner || purchases.access == .lifetime {
          Label("You have lifetime access", systemImage: "checkmark.circle.fill")
            .foregroundStyle(theme.accentColor)
        }

        VStack(spacing: 12) {
          if purchases.access == .verificationUnavailable
            || annualPrice == nil || lifetimePrice == nil
            || purchases.trialConfigurationPending
          {
            Button("Try Again") { Task { await purchases.refresh() } }
              .disabled(purchases.isBusy)
          }
          Button("Restore or Verify Purchases") { Task { await purchases.restorePurchases() } }
            .disabled(purchases.isBusy)
          if purchases.access == .subscription {
            Link("Manage Subscription", destination: URL(string: "https://apps.apple.com/account/subscriptions")!)
          }
        }
        .frame(maxWidth: .infinity)

        Text(terms)
          .font(.footnote)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }
      .frame(maxWidth: 480, alignment: .leading)
      .padding(28)
      .frame(maxWidth: .infinity)
    }
    .background(theme.backgroundColor.ignoresSafeArea())
  }

  private var title: String {
    switch purchases.access {
    case .verificationUnavailable: "Checking your purchase"
    case .purchaseRequired:
      purchases.trialAvailable || purchases.trialConfigurationPending
        ? "Try Ampwave free" : "Unlock Ampwave"
    default: "Your Ampwave access"
    }
  }

  private var subtitle: String {
    switch purchases.access {
    case .verificationUnavailable:
      return "We couldn't verify your App Store account yet. Retry or restore before purchasing again."
    case .purchaseRequired:
      if purchases.trialAvailable || purchases.trialConfigurationPending {
        return "Start with a 7-day free trial, or choose lifetime access. Your imported music stays yours."
      }
      return "Choose an annual plan or a one-time lifetime purchase. Your imported music stays yours."
    default:
      return "Thanks for supporting Ampwave."
    }
  }

  private var terms: String {
    if purchases.trialAvailable, let annualPrice, let lifetimePrice {
      return "The annual plan is free for 7 days, then \(annualPrice) per year unless you cancel before the trial ends. It renews automatically until canceled in your Apple account. Lifetime access is a separate, one-time \(lifetimePrice) purchase. Your music and playlists are never deleted if access expires. Previous paid Ampwave owners keep lifetime access."
    }
    if purchases.trialConfigurationPending, let annualPrice {
      return "The annual plan includes a 7-day free trial, then costs \(annualPrice) per year unless canceled before the trial ends. Ampwave won't start the yearly plan until the App Store confirms that trial. Lifetime access is a separate one-time purchase. Previous paid Ampwave owners keep lifetime access."
    }
    return "The annual plan renews automatically until canceled in your Apple account. Lifetime access is a separate one-time purchase. If an annual plan expires, playback pauses but your music and playlists remain on your device. Previous paid Ampwave owners keep lifetime access."
  }

  private var annualActionTitle: String {
    if purchases.trialAvailable { return "Start your 7-day free trial" }
    if purchases.trialConfigurationPending { return "7-day free trial temporarily unavailable" }
    return "Choose yearly access"
  }

  private func annualActionDetail(price: String) -> String {
    if purchases.trialAvailable { return "Then \(price) per year. Cancel anytime." }
    if purchases.trialConfigurationPending { return "Waiting for the App Store" }
    return "\(price) per year, automatically renews"
  }
}
