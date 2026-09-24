//
//  WatchContentView.swift
//  Ampwave Watch App
//

import SwiftData
internal import SwiftUI

struct WatchContentView: View {
  @Query(filter: #Predicate<LibrarySong> { _ in true }, sort: \LibrarySong.title)
  private var songs: [LibrarySong]

  @Query(filter: #Predicate<Playlist> { _ in true }, sort: \Playlist.name)
  private var playlists: [Playlist]

  @State private var showPlayer = false
  @State private var showPhoneUnavailable = false

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
              if WatchPlaybackManager.shared.play(song) {
                showPlayer = true
              } else {
                showPhoneUnavailable = true
              }
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
          }
        }
      }
      .navigationDestination(for: Playlist.self) { playlist in
        WatchPlaylistView(playlist: playlist)
      }
      .navigationDestination(isPresented: $showPlayer) {
        WatchNowPlayingView()
      }
      .alert("iPhone Unavailable", isPresented: $showPhoneUnavailable) {
        Button("OK", role: .cancel) {}
      } message: {
        Text("You can browse your library here, but playing a song requires your paired iPhone to be reachable.")
      }
      .onAppear { WatchSyncManager.shared.requestCatalog() }
    }
  }
}

#Preview {
  WatchContentView()
}
