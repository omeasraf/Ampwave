//
//  WatchSyncSettingsView.swift
//  Ampwave
//

internal import SwiftUI
import SwiftData

struct WatchSyncSettingsView: View {
    @Environment(\.modelContext) private var modelContext
    
    @Query(filter: #Predicate<LibrarySong> { $0.shouldSyncToWatch == true }, sort: \LibrarySong.title)
    private var syncedSongs: [LibrarySong]
    
    @Query(filter: #Predicate<Playlist> { $0.shouldSyncToWatch == true }, sort: \Playlist.name)
    private var syncedPlaylists: [Playlist]
    
    var body: some View {
        List {
            Section(header: Text("Synced Playlists")) {
                if syncedPlaylists.isEmpty {
                    Text("No playlists synced")
                        .foregroundColor(.secondary)
                } else {
                    ForEach(syncedPlaylists) { playlist in
                        HStack {
                            VStack(alignment: .leading) {
                                Text(playlist.name)
                                    .font(.headline)
                                Text("\(playlist.songs.count) songs")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            Spacer()
                            Button(role: .destructive) {
                                WatchSyncService.shared.updateSyncStatus(for: playlist, shouldSync: false)
                            } label: {
                                Image(systemName: "applewatch.slash")
                            }
                            .buttonStyle(.borderless)
                        }
                    }
                }
            }
            
            Section(header: Text("Synced Songs")) {
                if syncedSongs.isEmpty {
                    Text("No songs synced")
                        .foregroundColor(.secondary)
                } else {
                    ForEach(syncedSongs) { song in
                        HStack {
                            VStack(alignment: .leading) {
                                Text(song.title)
                                    .font(.headline)
                                Text(song.artist)
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            Spacer()
                            Button(role: .destructive) {
                                WatchSyncService.shared.updateSyncStatus(for: song, shouldSync: false)
                            } label: {
                                Image(systemName: "applewatch.slash")
                            }
                            .buttonStyle(.borderless)
                        }
                    }
                }
            }
        }
        .navigationTitle("Apple Watch Sync")
    }
}
