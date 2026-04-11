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
  var artworkPath: String?
  var remoteArtworkURL: String?

  // MARK: - External IDs
  var musicBrainzId: String?

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

// MARK: - Artist Detail View Model

@MainActor
@Observable
class ArtistDetailViewModel {
  let artist: Artist
  private let library: SongLibrary

  var songs: [LibrarySong] = []
  var albums: [Album] = []
  var topSongs: [LibrarySong] = []
  var relatedArtists: [Artist] = []

  init(artist: Artist, library: SongLibrary = .shared) {
    self.artist = artist
    self.library = library
  }

  func loadData() async {
    // Get all songs by this artist (including featured)
    songs = library.getSongs(byArtist: artist.name)
      .sorted { $0.title < $1.title }

    // Get all albums by this artist
    let normalizedArtistName = artist.name.lowercased()
    albums = library.albums.filter {
      ($0.artist ?? "").lowercased() == normalizedArtistName
    }.sorted {
      ($0.year ?? 0) > ($1.year ?? 0)
    }

    // Get top songs (by play count or most played)
    // For now, just take first 5 songs
    topSongs = Array(songs.prefix(5))

    // Find related artists based on genre similarity
    await findRelatedArtists()
  }

  private func findRelatedArtists() async {
    guard let artistGenres = artist.genres else { return }

    let allArtists = await library.allArtists()
    relatedArtists = allArtists.filter { otherArtist in
      guard otherArtist.id != artist.id else { return false }
      guard let otherGenres = otherArtist.genres else { return false }

      // Check for genre overlap
      let commonGenres = Set(artistGenres).intersection(Set(otherGenres))
      return !commonGenres.isEmpty
    }.prefix(6).map { $0 }
  }
}
