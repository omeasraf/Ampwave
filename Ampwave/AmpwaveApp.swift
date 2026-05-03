//
//  AmpwaveApp.swift
//  Ampwave
//
//  Main app entry point for Ampwave music player.
//

import SwiftData
internal import SwiftUI

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

  init() {
    print("[DEBUG] AmpwaveApp init started")
    // Initialize model container with all our data models
    let schema = Schema([
      LibrarySong.self,
      Album.self,
      Playlist.self,
      Artist.self,
      ListeningHistory.self,
      SongPlayStatistics.self,
      SyncedLyric.self,
      AppSettings.self,
      UserPreferences.self,
      PlaybackState.self,
    ])

    let modelConfiguration = ModelConfiguration(
      schema: schema,
      isStoredInMemoryOnly: false
    )

    do {
      print("[DEBUG] Creating ModelContainer")
      modelContainer = try ModelContainer(
        for: schema,
        configurations: [modelConfiguration]
      )
      print("[DEBUG] ModelContainer created successfully")

      // Initialize shared services with the main context immediately
      let context = modelContainer.mainContext
      SongLibrary.shared.setModelContext(context)
      PlaybackController.shared.setModelContext(context)
      PlaylistManager.shared.setModelContext(context)
      ListeningHistoryTracker.shared.setModelContext(context)
      MetadataService.shared.setModelContext(context)
      LyricsService.shared.setModelContext(context)
      #if os(iOS)
        WatchSyncService.shared.setModelContext(context)
      #endif

      // Setup preferences and theme
      _ = UserPreferences.getOrCreate(in: context)

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
            }
        #endif
      }
      .environment(ThemeManager.shared)
      .onOpenURL { AmpwaveURLRouter.handle($0) }
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
      }
      .windowStyle(.hiddenTitleBar)
      .windowResizability(.automatic)
      .defaultSize(width: 400, height: 600)
    #endif
  }
}
