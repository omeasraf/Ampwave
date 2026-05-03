//
//  AddSongsToPlaylistSheet.swift
//  Ampwave
//
//  Created by Ome Asraf on 4/10/26.
//
internal import SwiftUI

struct AddSongsToPlaylistSheet: View {
  let playlist: Playlist

  @State private var searchText = ""
  @State private var selectedSongs = Set<UUID>()
  @Environment(\.dismiss) private var dismiss

  private var library: SongLibrary { SongLibrary.shared }
  private var playlistManager: PlaylistManager { PlaylistManager.shared }

  var filteredSongs: [LibrarySong] {
    let existingIds = Set(playlist.songs.map { $0.id })
    let availableSongs = library.songs.filter {
      !existingIds.contains($0.id)
    }

    if searchText.isEmpty {
      return availableSongs
    }

    return availableSongs.filter { song in
      // Check basic fields
      let basicMatch =
        song.title.localizedCaseInsensitiveContains(searchText)
        || song.artist.localizedCaseInsensitiveContains(searchText)

      // Only check lyrics for longer search terms to avoid performance issues
      if searchText.count >= 3 {
        // Check plain lyrics
        let lyricsMatch = song.lyrics?.localizedCaseInsensitiveContains(searchText) ?? false

        // Check synced lyrics
        let syncedLyricsMatch =
          LyricsService.shared.getCachedLyrics(for: song)?
          .lines.contains { $0.text.localizedCaseInsensitiveContains(searchText) } ?? false

        return basicMatch || lyricsMatch || syncedLyricsMatch
      } else {
        return basicMatch
      }
    }
  }

  var body: some View {
    NavigationStack {
      List {
        if filteredSongs.isEmpty {
          Section {
            ContentUnavailableView(
              "No Songs Available",
              systemImage: "music.note",
              description: Text(
                "All songs are already in this playlist"
              )
            )
          }
        } else {
          Section {
            ForEach(filteredSongs) { song in
              HStack {
                SongRow(song: song, isCurrent: false)

                Spacer()

                if selectedSongs.contains(song.id) {
                  Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.pink)
                } else {
                  Image(systemName: "circle")
                    .foregroundStyle(.secondary)
                }
              }
              .contentShape(Rectangle())
              .onTapGesture {
                if selectedSongs.contains(song.id) {
                  selectedSongs.remove(song.id)
                } else {
                  selectedSongs.insert(song.id)
                }
              }
            }
          }
        }
      }
      .searchable(text: $searchText, prompt: "Search songs, artists, lyrics...")
      .navigationTitle("Add Songs")
      #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
      #endif
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Cancel") {
            dismiss()
          }
        }

        ToolbarItem(placement: .confirmationAction) {
          Button("Add (\(selectedSongs.count))") {
            let songsToAdd = library.songs.filter {
              selectedSongs.contains($0.id)
            }
            playlistManager.addSongs(songsToAdd, to: playlist)
            dismiss()
          }
          .disabled(selectedSongs.isEmpty)
        }
      }
    }
  }
}
