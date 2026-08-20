//
//  Artist.swift
//  Ampwave
//
//  SwiftData model for artists.
//  Artists are derived from song metadata and aggregated for display.
//

import Foundation
import SwiftData

@Model
final class Artist: Identifiable, Hashable {
  // MARK: - Identity
  @Attribute(.unique) var id: UUID
  var name: String

  // MARK: - Metadata
  var biography: String?
  var genres: [String]?
  var origin: String?
  var activeYears: String?
  var fanartURL: String?
  var fanartPath: String?
  var artworkPath: String?
  var isDedicatedArtwork: Bool = false
  var remoteArtworkURL: String?
  /// Prevents a library-wide opt-in pass from retrying an artist with no API
  /// match every time the app launches.
  var metadataCheckAttempted: Bool = false

  // New caching fields
  var cachedBiography: String?
  var cachedOrigin: String?
  var cachedActiveYears: String?
  var cachedGenres: [String]?

  // MARK: - External IDs
  var musicBrainzId: String?
  var appleMusicId: String?

  // MARK: - Statistics
  var songCount: Int
  var albumCount: Int
  var totalPlayCount: Int
  var lastAddedDate: Date = Date.distantPast

  // MARK: - Timestamps
  var createdDate: Date
  var lastUpdatedDate: Date

  // MARK: - User Data
  var isFavorite: Bool

  init(name: String) {
    self.id = UUID()
    self.name = name
    self.songCount = 0
    self.albumCount = 0
    self.totalPlayCount = 0
    self.createdDate = Date()
    self.lastUpdatedDate = Date()
    self.isFavorite = false
  }

  /// Updates statistics based on songs
  func updateStatistics(songs: [LibrarySong], albums: [Album]) {
    // Direct filter without async call
    let artistSongs = songs.filter { song in
      let songArtists =
        song.artists.isEmpty ? [song.artist] : song.artists
      return songArtists.contains { $0.lowercased() == name.lowercased() }
    }
    self.songCount = artistSongs.count
    let normalizedName = name.lowercased()
    self.albumCount =
      albums.filter { ($0.artist ?? "").lowercased() == normalizedName }
      .count
    self.lastUpdatedDate = Date()
  }

  /// Returns a formatted string of genres
  var genresDisplay: String? {
    guard let genres = genres, !genres.isEmpty else { return nil }
    return genres.joined(separator: " • ")
  }

  static func == (lhs: Artist, rhs: Artist) -> Bool {
    lhs.id == rhs.id
  }

  func hash(into hasher: inout Hasher) {
    hasher.combine(id)
  }
}
