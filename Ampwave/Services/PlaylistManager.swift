//
//  PlaylistManager.swift
//  Ampwave
//
//  Manages playlists: create, edit, delete, add/remove songs.
//  Handles "Liked Songs" and smart playlists.
//

import Foundation
import SwiftData
internal import SwiftUI

@MainActor
@Observable
final class PlaylistManager {
  static let shared = PlaylistManager()

  var modelContext: ModelContext?
  private let library = SongLibrary.shared

  private(set) var playlists: [Playlist] = []
  private(set) var likedSongsPlaylist: Playlist?

  private init() {}

  func setModelContext(_ context: ModelContext) {
    self.modelContext = context
    Task { await loadPlaylists() }
  }

  // MARK: - Load Playlists

  func loadPlaylists() async {
    print("[DEBUG] PlaylistManager.loadPlaylists: Loading playlists")
    guard let modelContext = modelContext else {
      print("[DEBUG] PlaylistManager.loadPlaylists: Error - No modelContext")
      return
    }

    do {
      let descriptor = FetchDescriptor<Playlist>()
      playlists = try modelContext.fetch(descriptor)
      print("[DEBUG] PlaylistManager.loadPlaylists: Fetched \(playlists.count) playlists")

      // Ensure "Liked Songs" playlist exists
      await ensureLikedSongsPlaylist()
      sortPlaylists()
    } catch {
      print("[DEBUG] PlaylistManager.loadPlaylists: Error: \(error)")
      playlists = []
    }
  }

  private func ensureLikedSongsPlaylist() async {
    if likedSongsPlaylist == nil {
      likedSongsPlaylist = playlists.first { $0.playlistType == .likedSongs }

      if likedSongsPlaylist == nil {
        // Create liked songs playlist
        likedSongsPlaylist = createPlaylist(
          name: "Liked Songs",
          description: "All your favorite songs in one place",
          playlistType: .likedSongs,
          icon: "heart.fill"
        )
      } else if likedSongsPlaylist?.icon == nil {
        // Backfill icon for existing databases created before icon persistence was fixed.
        likedSongsPlaylist?.icon = "heart.fill"
        save()
      }
    }
  }

  // MARK: - Create Playlist

  @discardableResult
  func createPlaylist(
    name: String,
    description: String? = nil,
    playlistType: PlaylistType = .custom,
    songs: [LibrarySong] = [],
    icon: String? = nil
  ) -> Playlist? {
    guard let modelContext = modelContext else { return nil }

    let playlist = Playlist(
      name: name,
      description: description,
      playlistType: playlistType,
      icon: icon
    )

    // Add initial songs
    for song in songs {
      playlist.addSong(song)
    }

    modelContext.insert(playlist)

    do {
      try modelContext.save()
      playlists.append(playlist)
      sortPlaylists()
      return playlist
    } catch {
      print("Failed to create playlist: \(error)")
      return nil
    }
  }

  // MARK: - Update Playlist

  func updatePlaylist(_ playlist: Playlist, name: String? = nil, description: String? = nil) {
    if let name = name {
      playlist.name = name
    }
    if let description = description {
      playlist.playlistDescription = description
    }
    playlist.touch()

    save()
    sortPlaylists()
  }

  // MARK: - Delete Playlist

  func deletePlaylist(_ playlist: Playlist) {
    guard let modelContext = modelContext else { return }

    // Don't delete system playlists
    guard playlist.playlistType == .custom || playlist.playlistType == .smart else {
      return
    }

    modelContext.delete(playlist)

    if let index = playlists.firstIndex(where: { $0.id == playlist.id }) {
      playlists.remove(at: index)
    }

    save()
  }

  func deletePlaylists(at offsets: IndexSet) {
    for index in offsets {
      let playlist = playlists[index]
      deletePlaylist(playlist)
    }
  }

  // MARK: - Add/Remove Songs

  func addSong(_ song: LibrarySong, to playlist: Playlist) {
    playlist.addSong(song)
    save()
    sortPlaylists()
  }

  func addSongs(_ songs: [LibrarySong], to playlist: Playlist) {
    for song in songs {
      playlist.addSong(song)
    }
    save()
    sortPlaylists()
  }

  func removeSong(_ song: LibrarySong, from playlist: Playlist) {
    playlist.removeSong(song)
    save()
  }

  func removeSongs(at offsets: IndexSet, from playlist: Playlist) {
    playlist.songs.remove(atOffsets: offsets)
    playlist.touch()
    save()
  }

  func moveSongs(in playlist: Playlist, from source: IndexSet, to destination: Int) {
    playlist.moveSong(from: source, to: destination)
    save()
  }

  // MARK: - Like/Unlike Songs

  func toggleLike(song: LibrarySong) -> Bool {
    guard let likedPlaylist = likedSongsPlaylist else { return false }

    if likedPlaylist.contains(song) {
      likedPlaylist.removeSong(song)
      save()
      return false  // Now unliked
    } else {
      likedPlaylist.addSong(song)
      save()
      return true  // Now liked
    }
  }

  func isLiked(song: LibrarySong) -> Bool {
    guard let likedPlaylist = likedSongsPlaylist else { return false }
    return likedPlaylist.contains(song)
  }

  func getLikedSongs() -> [LibrarySong] {
    return likedSongsPlaylist?.songs ?? []
  }

  // MARK: - Add Album to Playlist

  func addAlbum(_ album: Album, to playlist: Playlist) {
    for song in album.songs.sorted(by: { ($0.trackNumber ?? 0) < ($1.trackNumber ?? 0) }) {
      playlist.addSong(song)
    }
    save()
    sortPlaylists()
  }

  // MARK: - Add Artist to Playlist

  func addArtist(_ artist: Artist, to playlist: Playlist) {
    let artistSongs = library.getSongs(byArtist: artist.name)
      .sorted { $0.title < $1.title }

    for song in artistSongs {
      playlist.addSong(song)
    }
    save()
    sortPlaylists()
  }

  // MARK: - Pin/Unpin Playlist

  func togglePin(_ playlist: Playlist) {
    playlist.isPinned.toggle()
    save()
    sortPlaylists()
  }

  // MARK: - Smart Playlists

  func createSmartPlaylist(
    name: String,
    description: String? = nil,
    rules: SmartPlaylistRules
  ) -> Playlist? {
    guard let modelContext = modelContext else { return nil }

    let playlist = Playlist(
      name: name,
      description: description,
      playlistType: .smart
    )
    playlist.smartRules = rules

    // Populate with matching songs
    updateSmartPlaylist(playlist)

    modelContext.insert(playlist)

    do {
      try modelContext.save()
      playlists.append(playlist)
      sortPlaylists()
      return playlist
    } catch {
      print("Failed to create smart playlist: \(error)")
      return nil
    }
  }

  func updateSmartPlaylist(_ playlist: Playlist) {
    guard playlist.playlistType == .smart,
      let rules = playlist.smartRules
    else { return }

    let matchingSongs = applySmartRules(rules, to: library.songs)

    // Apply limit if enabled
    let limitedSongs: [LibrarySong]
    if rules.limitEnabled {
      limitedSongs = Array(matchingSongs.prefix(rules.limitCount))
    } else {
      limitedSongs = matchingSongs
    }

    // Update playlist songs
    playlist.songs = limitedSongs
    playlist.touch()

    save()
  }

  private func applySmartRules(_ rules: SmartPlaylistRules, to songs: [LibrarySong])
    -> [LibrarySong]
  {
    let filtered = songs.filter { song in
      let results = rules.rules.map { rule in
        evaluateRule(rule, for: song)
      }

      return rules.matchAll ? results.allSatisfy { $0 } : results.contains { $0 }
    }

    // Apply sorting based on limit settings
    if rules.limitEnabled {
      switch rules.limitBy {
      case .random:
        return filtered.shuffled()
      case .recentlyAdded:
        return filtered.sorted { $0.importedDate > $1.importedDate }
      case .recentlyPlayed:
        let tracker = ListeningHistoryTracker.shared
        return filtered.sorted {
          let stats1 = tracker.getStatistics(for: $0)
          let stats2 = tracker.getStatistics(for: $1)
          return (stats1?.lastPlayedAt ?? Date.distantPast)
            > (stats2?.lastPlayedAt ?? Date.distantPast)
        }
      case .mostPlayed:
        let tracker = ListeningHistoryTracker.shared
        return filtered.sorted {
          let stats1 = tracker.getStatistics(for: $0)
          let stats2 = tracker.getStatistics(for: $1)
          return (stats1?.playCount ?? 0) > (stats2?.playCount ?? 0)
        }
      case .alphabetical:
        return filtered.sorted { $0.title < $1.title }
      }
    }

    return filtered
  }

  private func evaluateRule(_ rule: SmartRule, for song: LibrarySong) -> Bool {
    let value = getFieldValue(rule.field, for: song)

    switch rule.operation {
    case .is_:
      return value?.caseInsensitiveCompare(rule.value) == .orderedSame
    case .isNot:
      return value?.caseInsensitiveCompare(rule.value) != .orderedSame
    case .contains:
      return value?.lowercased().contains(rule.value.lowercased()) ?? false
    case .doesNotContain:
      return !(value?.lowercased().contains(rule.value.lowercased()) ?? false)
    case .greaterThan:
      if let numValue = Double(value ?? ""), let ruleValue = Double(rule.value) {
        return numValue > ruleValue
      }
      return false
    case .lessThan:
      if let numValue = Double(value ?? ""), let ruleValue = Double(rule.value) {
        return numValue < ruleValue
      }
      return false
    case .inTheLast:
      // For date-based rules (e.g., "in the last 7 days")
      if let days = Int(rule.value), let dateValue = getDateFieldValue(rule.field, for: song) {
        let cutoffDate = Calendar.current.date(byAdding: .day, value: -days, to: Date())!
        return dateValue > cutoffDate
      }
      return false
    }
  }

  private func getFieldValue(_ field: RuleField, for song: LibrarySong) -> String? {
    switch field {
    case .artist:
      return song.artist
    case .album:
      return song.album
    case .genre:
      return song.genre
    case .year:
      return song.year.map { String($0) }
    case .playCount:
      let stats = ListeningHistoryTracker.shared.getStatistics(for: song)
      return stats.map { String($0.playCount) }
    case .lastPlayed:
      let stats = ListeningHistoryTracker.shared.getStatistics(for: song)
      return stats?.lastPlayedAt?.description
    case .rating:
      let stats = ListeningHistoryTracker.shared.getStatistics(for: song)
      return stats?.userRating.map { String($0) }
    case .duration:
      return String(song.duration)
    }
  }

  private func getDateFieldValue(_ field: RuleField, for song: LibrarySong) -> Date? {
    switch field {
    case .lastPlayed:
      let stats = ListeningHistoryTracker.shared.getStatistics(for: song)
      return stats?.lastPlayedAt
    default:
      return nil
    }
  }

  // MARK: - Generate Playlist Cover

  func generatePlaylistCover(for playlist: Playlist) -> String? {
    return playlist.generateArtwork(from: library)
  }

  // MARK: - Helper Methods

  private func save() {
    guard let modelContext = modelContext else { return }
    try? modelContext.save()
  }

  private func sortPlaylists() {
    playlists.sort {
      if $0.isPinned != $1.isPinned {
        return $0.isPinned && !$1.isPinned
      }
      return $0.lastModifiedDate > $1.lastModifiedDate
    }
  }

  // MARK: - Import/Export

  /// Exports a playlist to M3U format
  func exportToM3U(_ playlist: Playlist) -> String {
    var m3u = "#EXTM3U\n"

    for song in playlist.songs {
      m3u += "#EXTINF:\(Int(song.duration)),\(song.artist) - \(song.title)\n"
      m3u += "\(song.fileName)\n"
    }

    return m3u
  }

  /// Imports a playlist from M3U format
  func importFromM3U(_ m3uContent: String, name: String) -> Playlist? {
    let lines = m3uContent.split(separator: "\n")
    var songs: [LibrarySong] = []

    for line in lines {
      let trimmed = line.trimmingCharacters(in: .whitespaces)

      // Skip EXTINF lines and process file paths
      if trimmed.hasPrefix("#") { continue }

      // Find matching song in library
      let fileName = String(trimmed.split(separator: "/").last ?? trimmed[...])
      if let song = library.songs.first(where: { $0.fileName == fileName }) {
        songs.append(song)
      }
    }

    return createPlaylist(name: name, songs: songs)
  }
}

