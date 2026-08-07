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
      // Smart playlists are snapshots of the library, so they go stale as songs
      // are imported or removed. Re-evaluate them once the library is loaded.
      refreshAllSmartPlaylists()
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
          icon: PlaylistIcon(icon: "heart.fill", color: .pink),
          artworkType: .icon
        )
      } else {
        // Ensure "Liked Songs" uses the correct icon and color
        likedSongsPlaylist?.icon = PlaylistIcon(icon: "heart.fill", color: .pink)
        likedSongsPlaylist?.artworkType = .icon
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
    icon: PlaylistIcon? = nil,
    artworkType: PlaylistArtworkType = .grid,
    artworkPath: String? = nil
  ) -> Playlist? {
    guard let modelContext = modelContext else { return nil }

    let playlist = Playlist(
      name: name,
      description: description,
      playlistType: playlistType,
      artworkPath: artworkPath,
      icon: icon,
      artworkType: artworkType
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

  func updatePlaylistArtwork(
    _ playlist: Playlist, artworkType: PlaylistArtworkType, artworkPath: String? = nil
  ) {
    playlist.artworkType = artworkType
    if artworkType == .custom {
      playlist.artworkPath = artworkPath
    }
    playlist.touch()
    save()
  }

  // MARK: - Delete Playlist

  func deletePlaylist(_ playlist: Playlist) {
    guard let modelContext = modelContext else { return }

    // Don't delete system playlists
    guard playlist.playlistType == .custom || playlist.playlistType == .smart else {
      return
    }

    // Access property to ensure it's loaded into the context before deletion
    _ = playlist.artworkType
    _ = playlist.id

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

  /// Swaps every occurrence of `song` for `replacement` across all playlists,
  /// keeping position. Used when merging duplicates so playlist entries survive
  /// the copy they pointed at being removed.
  func replaceSong(_ song: LibrarySong, with replacement: LibrarySong) {
    guard song.id != replacement.id else { return }

    for playlist in playlists {
      guard playlist.songs.contains(where: { $0.id == song.id }) else { continue }

      if playlist.songs.contains(where: { $0.id == replacement.id }) {
        // Already present — drop the duplicate entry rather than listing it twice.
        playlist.songs.removeAll { $0.id == song.id }
        playlist.songOrder.removeAll { $0 == song.id }
      } else {
        playlist.songs = playlist.songs.map { $0.id == song.id ? replacement : $0 }
        playlist.songOrder = playlist.songOrder.map { $0 == song.id ? replacement.id : $0 }
      }
      playlist.touch()
    }
    save()
  }

  func removeSong(_ song: LibrarySong, from playlist: Playlist) {
    playlist.removeSong(song)
    save()
  }

  func removeSongs(at offsets: IndexSet, from playlist: Playlist) {
    let songsToRemove = offsets.map { playlist.orderedSongs[$0] }
    for song in songsToRemove {
      playlist.removeSong(song)
    }
    save()
  }

  func moveSongs(in playlist: Playlist, from source: IndexSet, to destination: Int) {
    playlist.moveSong(from: source, to: destination)
    save()
  }

  // MARK: - Like/Unlike Songs

  func toggleLike(song: LibrarySong) -> Bool {
    let newValue = !isLiked(song: song)
    setLiked(newValue, for: song)
    return newValue
  }

  func isLiked(song: LibrarySong) -> Bool {
    guard let likedPlaylist = likedSongsPlaylist else { return false }
    return likedPlaylist.contains(song)
  }

  func setLiked(_ isLiked: Bool, for song: LibrarySong) {
    guard let likedPlaylist = likedSongsPlaylist else { return }
    let historyTracker = ListeningHistoryTracker.shared

    if isLiked {
      likedPlaylist.addSong(song)
      historyTracker.setLiked(true, for: song)
      historyTracker.setDisliked(false, for: song)
    } else {
      likedPlaylist.removeSong(song)
      historyTracker.setLiked(false, for: song)
    }

    save()
  }

  func setDisliked(_ isDisliked: Bool, for song: LibrarySong) {
    let historyTracker = ListeningHistoryTracker.shared

    if isDisliked {
      likedSongsPlaylist?.removeSong(song)
      historyTracker.setLiked(false, for: song)
      historyTracker.setDisliked(true, for: song)
    } else {
      historyTracker.setDisliked(false, for: song)
    }

    save()
  }

  func toggleDisliked(song: LibrarySong) -> Bool {
    let newValue = !isDisliked(song: song)
    setDisliked(newValue, for: song)
    return newValue
  }

  func isDisliked(song: LibrarySong) -> Bool {
    ListeningHistoryTracker.shared.isDisliked(song: song)
  }

  func getLikedSongs() -> [LibrarySong] {
    return likedSongsPlaylist?.songs ?? []
  }

  // MARK: - Add Album to Playlist

  func addAlbum(_ album: Album, to playlist: Playlist) {
    for song in album.songs.sorted(by: LibrarySong.albumTrackOrder) {
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

    // SmartPlaylistEvaluator applies the limit itself; doing it again here is
    // what made a limit of 0 empty the playlist.
    let matchingSongs = SmartPlaylistEvaluator.evaluate(
      songs: library.songs,
      rules: rules,
      stats: ListeningHistoryTracker.shared.statisticsBySongId()
    )

    playlist.songs = matchingSongs
    playlist.songOrder = matchingSongs.map { $0.id }
    playlist.touch()

    save()
  }

  /// Re-evaluates every smart playlist. Call after the library changes, so
  /// smart playlists don't quietly go stale as songs are added or removed.
  func refreshAllSmartPlaylists() {
    let smart = playlists.filter { $0.playlistType == .smart && $0.smartRules != nil }
    guard !smart.isEmpty else { return }

    let songs = library.songs
    let stats = ListeningHistoryTracker.shared.statisticsBySongId()

    for playlist in smart {
      guard let rules = playlist.smartRules else { continue }
      let matching = SmartPlaylistEvaluator.evaluate(songs: songs, rules: rules, stats: stats)
      playlist.songs = matching
      playlist.songOrder = matching.map { $0.id }
    }
    save()
  }

  // MARK: - Generate Playlist Cover

  func generatePlaylistCover(for playlist: Playlist) -> String? {
    return playlist.generateArtwork(from: library)
  }

  // MARK: - Helper Methods

  private func save() {
    print("[DEBUG] PlaylistManager.save: Saving modelContext")
    guard let modelContext = modelContext else {
      print("[DEBUG] PlaylistManager.save: Error - No modelContext")
      return
    }
    do {
      try modelContext.save()
      print("[DEBUG] PlaylistManager.save: Successfully saved")
    } catch {
      print("[DEBUG] PlaylistManager.save: Error saving: \(error)")
    }
  }

  private func sortPlaylists() {
    playlists.sort {
      // Liked Songs always at the top
      if $0.playlistType == .likedSongs && $1.playlistType != .likedSongs {
        return true
      }
      if $1.playlistType == .likedSongs && $0.playlistType != .likedSongs {
        return false
      }

      // Then pinned playlists
      if $0.isPinned != $1.isPinned {
        return $0.isPinned && !$1.isPinned
      }

      // Finally by last modified date
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
