//
//  WatchPlaylistView.swift
//  Ampwave Watch App
//

internal import SwiftUI

struct WatchPlaylistView: View {
    let playlist: Playlist
    @State private var showPlayer = false
    
    var body: some View {
        List {
            Section {
                VStack(spacing: 8) {
                    // Playlist Header
                    HStack {
                        Image(systemName: "music.note.list")
                            .font(.largeTitle)
                            .foregroundColor(.accentColor)
                        VStack(alignment: .leading) {
                            Text(playlist.name)
                                .font(.headline)
                            Text("\(playlist.songs.count) songs")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                    .padding(.vertical)
                }
            }
            
            Section {
                ForEach(playlist.songs) { song in
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
        .navigationTitle(playlist.name)
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
        .navigationDestination(isPresented: $showPlayer) {
            WatchNowPlayingView()
        }
    }
}
