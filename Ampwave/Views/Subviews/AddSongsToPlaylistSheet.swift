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

    return availableSongs.filter {
      $0.title.localizedCaseInsensitiveContains(searchText)
        || $0.artist.localizedCaseInsensitiveContains(searchText)
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
      .searchable(text: $searchText, prompt: "Search songs")
      .navigationTitle("Add Songs")
      .navigationBarTitleDisplayMode(.inline)
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
