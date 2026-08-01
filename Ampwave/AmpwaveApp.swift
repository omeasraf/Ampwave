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
  // Shared model container for SwiftData
  let modelContainer: ModelContainer
  @Environment(\.scenePhase) private var scenePhase

  init() {
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
      modelContainer = try ModelContainer(
        for: schema,
        configurations: [modelConfiguration]
      )
      print("[DEBUG] ModelContainer created successfully")

      // Update Siri App Shortcuts
      if #available(iOS 17.0, macOS 14.0, *) {
        AmpwaveShortcuts.updateAppShortcutParameters()
      }

    } catch {
      fatalError("Could not initialize ModelContainer: \(error)")
    }

  }

  var body: some Scene {
    WindowGroup {
      // `ThemeManager` must be on an ancestor of `AppThemeChrome` — environment only flows down,
      // so it cannot be read from a ViewModifier applied after `.environment(...)` on the same leaf.
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
      .environment(ThemeManager.shared)
      .environment(SleepTimerService.shared)
      .onOpenURL { AmpwaveURLRouter.handle($0) }
      #if os(iOS)
        .onChange(of: scenePhase) { _, phase in
          // Leaving the app: ask for a later window so anything the
          // post-backgrounding grace period doesn't finish still gets done.
          guard phase == .background else { return }
          if SongLibrary.shared.hasPendingMetadataWork {
            BackgroundWorkCoordinator.scheduleMetadataRefresh()
          }
        }
      #endif
    }
    .modelContainer(modelContainer)

    #if os(macOS)
      Window("Lyrics", id: "lyrics") {
        Group {
          MacOSLyricsWindowView()
            .environment(\.modelContext, modelContainer.mainContext)
            .modifier(AppThemeChrome())
        }
        .environment(ThemeManager.shared)
        .environment(SleepTimerService.shared)
      }
      .windowStyle(.hiddenTitleBar)
      .windowResizability(.automatic)
      .defaultSize(width: 400, height: 600)
    #endif
  }
}
