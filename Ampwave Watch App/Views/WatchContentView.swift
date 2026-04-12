//
//  WatchContentView.swift
//  Ampwave Watch App
//

internal import SwiftUI
import SwiftData

struct WatchContentView: View {
    @Query(filter: #Predicate<LibrarySong> { _ in true }, sort: \LibrarySong.title)
    private var songs: [LibrarySong]
    
    @Query(filter: #Predicate<Playlist> { _ in true }, sort: \Playlist.name)
    private var playlists: [Playlist]
    
    @State private var showPlayer = false
    
    var body: some View {
        NavigationStack {
            List {
                Section("Playlists") {
                    ForEach(playlists) { playlist in
                        NavigationLink(value: playlist) {
                            HStack {
                                Image(systemName: "music.note.list")
                                    .foregroundColor(.accentColor)
                                Text(playlist.name)
                            }
                        }
                    }
                }
                
                Section("Songs") {
                    ForEach(songs) { song in
                        Button(action: {
                            WatchPlaybackManager.shared.play(song)
                            showPlayer = true
                        }) {
                            VStack(alignment: .leading) {
                                Text(song.title)
                                    .font(.headline)
                                Text(song.artist)
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        }
                    }
                }
            }
            .navigationTitle("Ampwave")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button(action: {
                        showPlayer = true
                    }) {
                        Image(systemName: "play.circle.fill")
                            .foregroundColor(.accentColor)
                    }
                }
            }
            .navigationDestination(for: Playlist.self) { playlist in
                WatchPlaylistView(playlist: playlist)
            }
            .navigationDestination(isPresented: $showPlayer) {
                WatchNowPlayingView()
            }
        }
    }
}
