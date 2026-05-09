//
//  SongsListView.swift
//  Ampwave
//
//  Created by Ome Asraf on 5/2/26.
//

import SwiftData
internal import SwiftUI

struct SongsListView: View {
  @Environment(\.modelContext) private var modelContext
  @Environment(ThemeManager.self) private var themeManager
  @Query private var settings: [AppSettings]

  private var library: SongLibrary { SongLibrary.shared }
  private var playback: PlaybackController { PlaybackController.shared }
  private var playlistManager: PlaylistManager { PlaylistManager.shared }

  private var appSettings: AppSettings {
    settings.first ?? AppSettings.getOrCreate(in: modelContext)
  }

  private var sortedSongs: [LibrarySong] {
    sortSongs(library.songs)
  }

  var body: some View {
    List {
      if !sortedSongs.isEmpty {
        Button {
          playback.playQueue(sortedSongs)
        } label: {
          Label("Play All", systemImage: "play.circle.fill")
            .font(.system(size: 16, weight: .semibold))
        }
        .listRowBackground(themeManager.backgroundColor)
      }

      ForEach(sortedSongs) { song in
        SongRow(
          song: song,
          isCurrent: playback.currentItem?.id == song.id
        )
        .contentShape(Rectangle())
        .onTapGesture {
          playback.playQueue(
            sortedSongs,
            startingAt: sortedSongs.firstIndex(where: { $0.id == song.id }) ?? 0
          )
        }
        .listRowBackground(themeManager.backgroundColor)
        .swipeActions(edge: .trailing) {
          Button {
            playlistManager.toggleLike(song: song)
          } label: {
            Image(
              systemName: playlistManager.isLiked(song: song)
                ? "heart.slash" : "heart"
            )
          }
          .tint(playlistManager.isLiked(song: song) ? .gray : themeManager.accentColor)
        }
        .swipeActions(edge: .leading) {
          Button {
            Task { await playback.playNext(song) }
          } label: {
            Label("Play Next", systemImage: "text.insert")
          }
          .tint(.orange)
        }
      }
    }
    .listStyle(.plain)
    .scrollContentBackground(.hidden)
    .background(themeManager.backgroundColor)
    .overlay {
      if library.songs.isEmpty {
        ContentUnavailableView(
          "No Songs",
          systemImage: "music.note",
          description: Text(
            "Import songs from Settings to get started"
          )
        )
      }
    }
    .background(themeManager.backgroundColor)
  }

  private func sortSongs(_ songs: [LibrarySong]) -> [LibrarySong] {
    switch appSettings.songSortOrder {
    case .titleAscending:
      return songs.sorted {
        $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
      }
    case .titleDescending:
      return songs.sorted {
        $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedDescending
      }
    case .artistAscending:
      return songs.sorted {
        $0.artist.localizedCaseInsensitiveCompare($1.artist) == .orderedAscending
      }
    case .artistDescending:
      return songs.sorted {
        $0.artist.localizedCaseInsensitiveCompare($1.artist) == .orderedDescending
      }
    case .dateAddedDescending:
      return songs.sorted { $0.importedDate > $1.importedDate }
    case .dateAddedAscending:
      return songs.sorted { $0.importedDate < $1.importedDate }
    case .yearDescending:
      return songs.sorted { ($0.year ?? 0) > ($1.year ?? 0) }
    case .yearAscending:
      return songs.sorted { ($0.year ?? 0) < ($1.year ?? 0) }
    case .random:
      return songs.sorted { $0.id.uuidString < $1.id.uuidString }
    }
  }
}
