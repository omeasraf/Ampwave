//
//  Playlist.swift
//  Ampwave
//
//  SwiftData model for user-created playlists.
//  Supports liked songs, custom playlists, and smart playlists.
//

import Foundation
import SwiftData
internal import SwiftUI
import UIKit

@Model
final class Playlist: Identifiable, Hashable {
  // MARK: - Identity
  @Attribute(.unique) var id: UUID
  var name: String
  var playlistDescription: String?

  // MARK: - Metadata
  var createdDate: Date
  var lastModifiedDate: Date
  var artworkPath: String?
  private var rawArtworkType: String = PlaylistArtworkType.grid.rawValue

  var artworkType: PlaylistArtworkType {
    get { PlaylistArtworkType(rawValue: rawArtworkType) ?? .grid }
    set { rawArtworkType = newValue.rawValue }
  }

  var icon: PlaylistIcon?


  // MARK: - Playlist Type
  var playlistType: PlaylistType

  // MARK: - Relationships
  @Relationship(deleteRule: .nullify) var songs: [LibrarySong] = []

  // MARK: - Smart Playlist Rules (for smart playlists)
  var smartRules: SmartPlaylistRules?

  // MARK: - User Preferences
  var isPinned: Bool
  var sortOrder: PlaylistSortOrder

  init(
    name: String,
    description: String? = nil,
    playlistType: PlaylistType = .custom,
    artworkPath: String? = nil,
    icon: PlaylistIcon? = nil,
    artworkType: PlaylistArtworkType = .grid
  ) {
    self.id = UUID()
    self.name = name
    self.playlistDescription = description
    self.playlistType = playlistType
    self.artworkPath = artworkPath
    self.icon = icon
    self.rawArtworkType = artworkType.rawValue
    self.createdDate = Date()
    self.lastModifiedDate = Date()
    self.isPinned = false
    self.sortOrder = .manual
  }

  /// Returns the song count for this playlist
  var songCount: Int {
    songs.count
  }

  /// Returns total duration of all songs in the playlist
  var totalDuration: TimeInterval {
    songs.reduce(0) { $0 + $1.duration }
  }

  /// Updates the last modified date
  func touch() {
    lastModifiedDate = Date()
  }

  /// Adds a song to the playlist if not already present
  func addSong(_ song: LibrarySong) {
    guard !songs.contains(where: { $0.id == song.id }) else { return }
    songs.append(song)
    touch()
  }

  /// Removes a song from the playlist
  func removeSong(_ song: LibrarySong) {
    if let index = songs.firstIndex(where: { $0.id == song.id }) {
      songs.remove(at: index)
      touch()
    }
  }

  /// Moves a song from one index to another
  func moveSong(from source: IndexSet, to destination: Int) {
    songs.move(fromOffsets: source, toOffset: destination)
    touch()
  }

  /// Checks if the playlist contains a specific song
  func contains(_ song: LibrarySong) -> Bool {
    songs.contains(where: { $0.id == song.id })
  }

  /// Returns the artwork paths to use for the playlist cover
  func getArtworkPaths() -> [String] {
    // If it's a custom artwork, return that
    if artworkType == .custom, let path = artworkPath {
      return [path]
    }

    // Get unique artwork paths from songs
    let allPaths = songs.compactMap { $0.artworkPath }
    let uniquePaths = allPaths.uniqued()

    if artworkType == .single || uniquePaths.isEmpty {
      return Array(uniquePaths.prefix(1))
    }

    // If we have at least 4 unique artworks, use the first 4 unique ones
    if uniquePaths.count >= 4 {
      return Array(uniquePaths.prefix(4))
    }

    // If we have between 1 and 3 unique artworks, and we want a grid:
    // We can either return just the unique ones and let the view handle it,
    // or return a single one if it's not "enough" for a good grid.
    // Most apps only show the grid if there are 4+ unique albums.
    // But to "respect the 2x2 grid" selection, let's return up to 4 paths even if we repeat.

    if artworkType == .grid && !allPaths.isEmpty {
      // If we have 4+ songs, just take the first 4 even if they aren't unique
      if allPaths.count >= 4 {
        return Array(allPaths.prefix(4))
      }
      // If we have fewer than 4 songs, return all of them
      return allPaths
    }

    return Array(uniquePaths.prefix(1))
  }

  /// Generates a collage artwork from song artworks
  func generateArtwork(from library: SongLibrary) -> String? {
    // For now, we use getArtworkPaths() in the view for on-the-fly rendering
    return getArtworkPaths().first
  }

  static func == (lhs: Playlist, rhs: Playlist) -> Bool {
    lhs.id == rhs.id
  }

  func hash(into hasher: inout Hasher) {
    hasher.combine(id)
  }
}

// MARK: - Playlist Artwork Type
enum PlaylistArtworkType: String, Codable {
  case grid
  case single
  case custom
  case icon
}

// MARK: - Playlist Icon
@Model
final class PlaylistIcon: Identifiable, Hashable {
  // MARK: - Identity
  @Attribute(.unique) var id: UUID
  var icon: String
  var colorHex: String

  init(icon: String, color: Color) {
    self.id = UUID()
    self.icon = icon
    self.colorHex = color.toHexString()
  }

  var color: Color {
    get { Color(hex: colorHex) }
    set { colorHex = newValue.toHexString() }
  }
}

// MARK: - Helpers

extension Sequence where Element: Hashable {
  func uniqued() -> [Element] {
    var seen = Set<Element>()
    return filter { seen.insert($0).inserted }
  }
}
extension Color {
  /// Returns the hex string representation for this Color (assuming UIColor backend).
  func toHexString() -> String {
    let uiColor = UIColor(self)
    var r: CGFloat = 0
    var g: CGFloat = 0
    var b: CGFloat = 0
    var a: CGFloat = 0
    uiColor.getRed(&r, green: &g, blue: &b, alpha: &a)
    let rgb: Int = (Int)(r * 255) << 16 | (Int)(g * 255) << 8 | (Int)(b * 255) << 0
    return String(format: "#%06x", rgb)
  }

  /// Initializes Color from a hex string.
  init(hex: String) {
    var hex = hex
    if hex.hasPrefix("#") { hex.removeFirst() }
    var int = UInt64()
    Scanner(string: hex).scanHexInt64(&int)
    let r = Double((int >> 16) & 0xFF) / 255.0
    let g = Double((int >> 8) & 0xFF) / 255.0
    let b = Double(int & 0xFF) / 255.0
    self = Color(red: r, green: g, blue: b)
  }
}
