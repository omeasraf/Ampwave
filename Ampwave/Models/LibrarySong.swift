//
//  LibrarySong.swift
//  Ampwave
//
//  SwiftData model for a song in the user's library.
//

import CryptoKit
import Foundation
import SwiftData

@Model
final class LibrarySong: Identifiable, Hashable {
  // MARK: - Required (identity & storage)
  @Attribute(.unique) var id: UUID
  var fileName: String
  var fileHash: String
  var importedDate: Date
  var size: Int

  // MARK: - Core display
  var title: String
  var artist: String
  @Attribute(.externalStorage) var artists: [String]  // All artists (parsed from artist field)
  var duration: TimeInterval

  // MARK: - Extended metadata (optional)
  var lyrics: String?
  var album: String?
  var albumArtist: String?
  var genre: String?
  var songDescription: String?
  var trackNumber: Int?
  var discNumber: Int?
  var year: Int?
  var composer: String?
  var artworkPath: String?
  var albumReference: Album?

  init(
    title: String,
    artist: String,
    fileName: String,
    fileHash: String,
    size: Int,
    duration: TimeInterval = 0,
    lyrics: String? = nil,
    album: String? = nil,
    albumArtist: String? = nil,
    genre: String? = nil,
    songDescription: String? = nil,
    trackNumber: Int? = nil,
    discNumber: Int? = nil,
    year: Int? = nil,
    composer: String? = nil,
    artworkPath: String? = nil
  ) {
    self.id = UUID()
    self.title = title
    self.artist = artist
    self.artists = ArtistParser.parseArtists(from: artist)
    self.fileName = fileName
    self.fileHash = fileHash
    self.size = size
    self.importedDate = Date()
    self.duration = duration
    self.lyrics = lyrics
    self.album = album
    self.albumArtist = albumArtist
    self.genre = genre
    self.songDescription = songDescription
    self.trackNumber = trackNumber
    self.discNumber = discNumber
    self.year = year
    self.composer = composer
    self.artworkPath = artworkPath
  }

  static func == (lhs: LibrarySong, rhs: LibrarySong) -> Bool {
    lhs.id == rhs.id
  }

  func hash(into hasher: inout Hasher) {
    hasher.combine(id)
  }
}
