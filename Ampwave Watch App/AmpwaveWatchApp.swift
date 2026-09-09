//
//  AmpwaveWatchApp.swift
//  Ampwave Watch App
//

import SwiftData
internal import SwiftUI

@main
struct AmpwaveWatchApp: App {
  let container: ModelContainer?
  let persistenceStartupError: String?

  init() {
    let schema = Schema([
      LibrarySong.self,
      Playlist.self,
      SyncedLyric.self,
    ])
    let config = ModelConfiguration(schema: schema)
    do {
      let modelContainer = try ModelContainer(for: schema, configurations: [config])
      container = modelContainer
      persistenceStartupError = nil

      // Initialize Watch side sync service
      WatchSyncManager.shared.setModelContext(modelContainer.mainContext)
    } catch {
      container = nil
      persistenceStartupError = error.localizedDescription
    }
  }

  var body: some Scene {
    WindowGroup {
      if let container {
        WatchContentView()
          .modelContainer(container)
      } else {
        VStack(spacing: 8) {
          Image(systemName: "externaldrive.badge.exclamationmark")
          Text("Library Unavailable")
            .font(.headline)
          Text("Restart Ampwave on your iPhone and Apple Watch.")
            .font(.caption2)
            .multilineTextAlignment(.center)
          if let persistenceStartupError {
            Text(persistenceStartupError)
              .font(.system(size: 8))
              .lineLimit(3)
          }
        }
        .padding()
      }
    }
  }
}
