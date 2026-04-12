//
//  AmpwaveWatchApp.swift
//  Ampwave Watch App
//

internal import SwiftUI
import SwiftData

@main
struct AmpwaveWatchApp: App {
    let container: ModelContainer

    init() {
        let schema = Schema([
            LibrarySong.self,
            Playlist.self,
            SyncedLyric.self
        ])
        let config = ModelConfiguration(schema: schema)
        do {
            container = try ModelContainer(for: schema, configurations: [config])
            
            // Initialize Watch side sync service
            WatchSyncManager.shared.setModelContext(container.mainContext)
        } catch {
            fatalError("Could not initialize ModelContainer: \(error)")
        }
    }

    var body: some Scene {
        WindowGroup {
            WatchContentView()
                .modelContainer(container)
        }
    }
}
