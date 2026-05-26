//
//  SongsListView.swift
//  Ampwave
//
//  Created by Ome Asraf on 5/2/26.
//

import SwiftData
internal import SwiftUI

// MARK: - Nonisolated sort helper (safe to call from Task.detached)

private func sortSongs(
  _ songs: [LibrarySong],
  order: LibrarySortOrder,
  ratings: [UUID: Int]
) -> [LibrarySong] {
  switch order {
  case .titleAscending:
    return songs.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
  case .titleDescending:
    return songs.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedDescending }
  case .artistAscending:
    return songs.sorted { $0.artist.localizedCaseInsensitiveCompare($1.artist) == .orderedAscending }
  case .artistDescending:
    return songs.sorted { $0.artist.localizedCaseInsensitiveCompare($1.artist) == .orderedDescending }
  case .dateAddedDescending:
    return songs.sorted { $0.importedDate > $1.importedDate }
  case .dateAddedAscending:
    return songs.sorted { $0.importedDate < $1.importedDate }
  case .yearDescending:
    return songs.sorted { ($0.year ?? 0) > ($1.year ?? 0) }
  case .yearAscending:
    return songs.sorted { ($0.year ?? 0) < ($1.year ?? 0) }
  case .ratingDescending:
    // ratings dict is pre-built — O(1) lookup per comparison, no DB hit
    return songs.sorted { (ratings[$0.id] ?? 0) > (ratings[$1.id] ?? 0) }
  case .ratingAscending:
    return songs.sorted { (ratings[$0.id] ?? 0) < (ratings[$1.id] ?? 0) }
  case .random:
    return songs.sorted { $0.id.uuidString < $1.id.uuidString }
  }
}

// MARK: - View

struct SongsListView: View {
  @Environment(\.modelContext) private var modelContext
  @Environment(ThemeManager.self) private var themeManager
  @Query private var settings: [AppSettings]
  /// Cached sort result — updated off the main thread via .task(id:).
  @State private var sortedSongs: [LibrarySong] = []

  private var library: SongLibrary { SongLibrary.shared }
  private var playback: PlaybackController { PlaybackController.shared }
  private var playlistManager: PlaylistManager { PlaylistManager.shared }
  private var historyTracker: ListeningHistoryTracker { ListeningHistoryTracker.shared }

  private var appSettings: AppSettings {
    settings.first ?? AppSettings.getOrCreate(in: modelContext)
  }

  /// Changes when sort order or library size changes — triggers a re-sort.
  private var sortCacheKey: String {
    "\(appSettings.songSortOrder.rawValue)-\(library.songs.count)"
  }

  var body: some View {
    songList
      .listStyle(.plain)
      .scrollContentBackground(.hidden)
      .background(themeManager.backgroundColor)
      // Re-sort off the main thread whenever sort order or library size changes.
      .task(id: sortCacheKey) {
        let songs = library.songs
        let order = appSettings.songSortOrder
        // Fetch rating stats once here (ModelContext is main-actor-bound).
        let ratingsDict: [UUID: Int]
        if order == .ratingDescending || order == .ratingAscending {
          let fetched = (try? modelContext.fetch(FetchDescriptor<SongPlayStatistics>())) ?? []
          ratingsDict = Dictionary(
            uniqueKeysWithValues: fetched.compactMap { s in s.userRating.map { (s.songId, $0) } }
          )
        } else {
          ratingsDict = [:]
        }
        // Do the actual sort on a background thread so the main thread stays responsive.
        let result = await Task.detached(priority: .userInitiated) {
          sortSongs(songs, order: order, ratings: ratingsDict)
        }.value
        sortedSongs = result
      }
      .overlay {
        if library.songs.isEmpty {
          ContentUnavailableView(
            "No Songs",
            systemImage: "music.note",
            description: Text("Import songs from Settings to get started")
          )
        }
      }
  }

  // MARK: - Sub-views

  private var songList: some View {
    List {
      if !sortedSongs.isEmpty {
        Button { playback.playQueue(sortedSongs) } label: {
          Label("Play All", systemImage: "play.circle.fill")
            .font(.system(size: 16, weight: .semibold))
        }
        .listRowBackground(themeManager.backgroundColor)
      }

      ForEach(sortedSongs) { song in
        songRow(song)
      }
    }
  }

  private func songRow(_ song: LibrarySong) -> some View {
    SongRow(song: song, isCurrent: playback.currentItem?.id == song.id)
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
          Image(systemName: playlistManager.isLiked(song: song) ? "heart.slash" : "heart")
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
