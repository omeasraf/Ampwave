//
//  AmpwaveApp.swift
//  Ampwave
//
//  Main app entry point for Ampwave music player.
//

import AppIntents
import SwiftData
internal import SwiftUI

extension Notification.Name {
  /// Posted after the user resets their library so tabs can clear their navigation stacks.
  static let libraryDidReset = Notification.Name("com.ampwave.libraryDidReset")
  static let capsuleDidImport = Notification.Name("com.ampwave.capsuleDidImport")
  static let capsuleImportFailed = Notification.Name("com.ampwave.capsuleImportFailed")
}

/// Applies tint and color scheme from `ThemeManager` in the environment (observation-safe; avoids @State + singleton issues).
private struct AppThemeChrome: ViewModifier {
  @Environment(ThemeManager.self) private var themeManager

  func body(content: Content) -> some View {
    Group {
      if themeManager.usesSystemAppearance {
        content
      } else {
        content.tint(themeManager.accentColor)
      }
    }
    .preferredColorScheme(themeManager.colorScheme)
  }
}

@main
struct AmpwaveApp: App {
  #if os(iOS)
    @UIApplicationDelegateAdaptor(AmpwaveApplicationDelegate.self)
    private var applicationDelegate
  #endif

  // Shared model container for SwiftData
  let modelContainer: ModelContainer?
  let persistenceStartupError: String?
  @Environment(\.scenePhase) private var scenePhase

  init() {
    DiagnosticLog.shared.log("lifecycle", "Application init build=\(Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "unknown")")
    print("[DEBUG] AmpwaveApp init started")

    // Must register before the app finishes launching, or BGTaskScheduler traps.
    #if os(iOS)
      BackgroundWorkCoordinator.activate()
    #endif

    // Initialize model container with all our data models
    let schema = Schema([
      LibrarySong.self,
      Album.self,
      Playlist.self,
      PlaylistIcon.self,
      RadioStation.self,
      Artist.self,
      ListeningHistory.self,
      SongPlayStatistics.self,
      SyncedLyric.self,
      AppSettings.self,
      UserPreferences.self,
      PlaybackState.self,
      PendingScrobble.self,
      AmpwaveCapsule.self,
      SonicAnalysisRecord.self,
    ])

    // Configure storage in App Group for sharing with extensions
    let storeURL: URL
    if let sharedURL = PathManager.sharedContainerURL {
      let appSupport = sharedURL.appendingPathComponent("Library/Application Support", isDirectory: true)
      try? FileManager.default.createDirectory(at: appSupport, withIntermediateDirectories: true)
      storeURL = appSupport.appendingPathComponent("default.store")
      print("[DEBUG] Using App Group storage: \(storeURL.path)")
    } else {
      storeURL = PathManager.documentsDirectory.appendingPathComponent("default.store")
      print("[DEBUG] Falling back to Documents storage: \(storeURL.path)")
    }

    let modelConfiguration = ModelConfiguration(
      url: storeURL,
      allowsSave: true,
      cloudKitDatabase: .none
    )

    do {
      print("[DEBUG] Creating ModelContainer")
      let container = try ModelContainer(
        for: schema,
        configurations: [modelConfiguration]
      )
      modelContainer = container
      persistenceStartupError = nil
      print("[DEBUG] ModelContainer created successfully")
      if #available(iOS 17.0, macOS 14.0, *) {
        SiriIntentEnvironment.configure(modelContext: container.mainContext)
      }
      SonicRecommendationService.shared.setModelContext(container.mainContext)
      SongLibrary.songWasImported = { song in
        SonicRecommendationService.shared.enqueueAnalysis(for: song)
      }
      SongLibrary.libraryDidLoad = { songs in
        SonicRecommendationService.shared.enqueueMissingAnalysis(for: songs)
      }

      // Update Siri App Shortcuts
      if #available(iOS 17.0, macOS 14.0, *) {
        AmpwaveShortcuts.updateAppShortcutParameters()
      }

    } catch {
      modelContainer = nil
      persistenceStartupError = error.localizedDescription
      DiagnosticLog.shared.log(
        "persistence",
        "ModelContainer initialization failed without modifying the store: \(error)"
      )
    }

  }

  var body: some Scene {
    WindowGroup {
      // `ThemeManager` must be on an ancestor of `AppThemeChrome` — environment only flows down,
      // so it cannot be read from a ViewModifier applied after `.environment(...)` on the same leaf.
      Group {
        if let modelContainer {
          Group {
            #if os(macOS)
              MacOSMainView()
                .environment(\.modelContext, modelContainer.mainContext)
                .modifier(AppThemeChrome())
            #else
              ContentView()
                .environment(\.modelContext, modelContainer.mainContext)
                .modifier(AppThemeChrome())
                .onAppear {
                  print("[DEBUG] App completely loaded and onAppear")
                  // Re-register shortcuts once the scene is fully live so Siri
                  // picks up the latest phrase list even if init() ran too early.
                  if #available(iOS 17.0, macOS 14.0, *) {
                    AmpwaveShortcuts.updateAppShortcutParameters()
                  }
                }
            #endif
          }
          .modelContainer(modelContainer)
        } else {
          PersistenceUnavailableView(details: persistenceStartupError)
            .modifier(AppThemeChrome())
        }
      }
      .environment(ThemeManager.shared)
      .environment(SleepTimerService.shared)
      .onOpenURL { handleOpenURL($0) }
      #if os(iOS)
        .onChange(of: scenePhase) { _, phase in
          switch phase {
          case .active:
            DiagnosticLog.shared.log("lifecycle", "Scene became active")
            SonicRecommendationService.shared.applicationDidBecomeActive()
            PlaybackController.shared.applicationDidBecomeActive()
            LibraryMonitorService.shared.applicationDidBecomeActive()
          case .background:
            DiagnosticLog.shared.log(
              "lifecycle",
              "Scene entered background playing=\(PlaybackController.shared.isPlaying) song=\(PlaybackController.shared.currentItem?.title ?? "none")"
            )
            SonicRecommendationService.shared.applicationWillResignActive()
            LibraryMonitorService.shared.applicationDidEnterBackground()
            // Leaving the app: ask for a later window so anything the
            // post-backgrounding grace period doesn't finish still gets done.
            if SongLibrary.shared.hasPendingMetadataWork {
              BackgroundWorkCoordinator.scheduleMetadataRefresh()
            }
          case .inactive:
            SonicRecommendationService.shared.applicationWillResignActive()
          @unknown default:
            break
          }
        }
      #endif
    }

    #if os(macOS)
      Window("Lyrics", id: "lyrics") {
        Group {
          if let modelContainer {
            MacOSLyricsWindowView()
              .environment(\.modelContext, modelContainer.mainContext)
              .modifier(AppThemeChrome())
              .modelContainer(modelContainer)
          } else {
            PersistenceUnavailableView(details: persistenceStartupError)
              .modifier(AppThemeChrome())
          }
        }
        .environment(ThemeManager.shared)
        .environment(SleepTimerService.shared)
      }
      .windowStyle(.hiddenTitleBar)
      .windowResizability(.automatic)
      .defaultSize(width: 400, height: 600)
    #endif
  }

  private func handleOpenURL(_ url: URL) {
    guard url.pathExtension.lowercased() == CapsulePackage.fileExtension else {
      AmpwaveURLRouter.handle(url)
      return
    }

    guard let modelContainer else {
      NotificationCenter.default.post(
        name: .capsuleImportFailed,
        object: "The library database is unavailable. Restart Ampwave and try again."
      )
      return
    }

    Task { @MainActor in
      let secured = url.startAccessingSecurityScopedResource()
      defer { if secured { url.stopAccessingSecurityScopedResource() } }
      do {
        let capsule = try await CapsulePackage.importCapsule(
          from: url,
          into: modelContainer.mainContext,
          library: SongLibrary.shared
        )
        NotificationCenter.default.post(name: .capsuleDidImport, object: capsule.id)
      } catch {
        NotificationCenter.default.post(
          name: .capsuleImportFailed,
          object: error.localizedDescription
        )
      }
    }
  }
}

private struct PersistenceUnavailableView: View {
  let details: String?
  @Environment(ThemeManager.self) private var themeManager

  var body: some View {
    VStack(spacing: 18) {
      Image(systemName: "externaldrive.badge.exclamationmark")
        .font(.system(size: 46, weight: .medium))
        .foregroundStyle(themeManager.accentColor)

      Text("Library Unavailable")
        .font(.title2.bold())
        .foregroundStyle(themeManager.primaryTextColor)

      Text(
        "Ampwave could not open its library database. Your music and database files were left untouched. Restart the app, and share the latest diagnostic log if the problem continues."
      )
      .font(.body)
      .foregroundStyle(themeManager.secondaryTextColor)
      .multilineTextAlignment(.center)

      if let details, !details.isEmpty {
        Text(details)
          .font(.caption)
          .foregroundStyle(themeManager.secondaryTextColor)
          .multilineTextAlignment(.center)
          .textSelection(.enabled)
      }
    }
    .padding(32)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(themeManager.backgroundColor)
  }
}
