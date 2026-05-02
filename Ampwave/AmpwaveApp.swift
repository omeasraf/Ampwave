//
//  AmpwaveApp.swift
//  Ampwave
//
//  Main app entry point for Ampwave music player.
//

import SwiftData
internal import SwiftUI

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

  @State private var themeManager = ThemeManager.shared

  var body: some Scene {
    WindowGroup {
      #if os(macOS)
      MacOSMainView()
        .environment(\.modelContext, modelContainer.mainContext)
        .environment(themeManager)
        .tint(themeManager.accentColor)
        .preferredColorScheme(themeManager.colorScheme)
      #else
      ContentView()
        .environment(\.modelContext, modelContainer.mainContext)
        .environment(themeManager)
        .tint(themeManager.accentColor)
        .preferredColorScheme(themeManager.colorScheme)
        .onAppear {
          print("[DEBUG] App completely loaded and onAppear")
        }
      #endif
    }
    .modelContainer(modelContainer)

    #if os(macOS)
    Window("Lyrics", id: "lyrics") {
      MacOSLyricsWindowView()
        .environment(\.modelContext, modelContainer.mainContext)
        .environment(themeManager)
        .preferredColorScheme(themeManager.colorScheme)
    }
    .windowStyle(.hiddenTitleBar)
    .windowResizability(.automatic)
    .defaultSize(width: 400, height: 600)
    #endif
  }
}
