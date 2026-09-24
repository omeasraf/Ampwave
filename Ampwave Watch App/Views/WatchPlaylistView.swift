//
//  WatchPlaylistView.swift
//  Ampwave Watch App
//

internal import SwiftUI

struct WatchPlaylistView: View {
  let playlist: Playlist
  @State private var showPlayer = false
  @State private var showPhoneUnavailable = false

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
              Text("\(playlist.orderedSongs.count) songs")
                .font(.caption)
                .foregroundColor(.secondary)
            }
          }
          .padding(.vertical)
        }
      }

      Section {
        ForEach(playlist.orderedSongs) { song in
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
    .alert("iPhone Unavailable", isPresented: $showPhoneUnavailable) {
      Button("OK", role: .cancel) {}
    } message: {
      Text("You can browse this playlist here, but playing a song requires your paired iPhone to be reachable.")
    }
  }
}
