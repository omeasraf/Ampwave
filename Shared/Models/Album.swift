//
//  Album.swift
//  Ampwave
//
//  SwiftData model for an album.
//

import Foundation
import SwiftData

@Model
final class Album: Identifiable, Hashable {
  // MARK: - Identity & Core Properties
  @Attribute(.unique) var id: UUID
  var name: String
  var artist: String?

  // MARK: - Album Metadata
  var year: Int?
  var artworkPath: String?
  var embeddedArtworkPath: String?
  var artworkSourceRaw: String = "embedded"
  var artworkBackgroundColor: String?
  var artworkPrimaryTextColor: String?
  var artworkSecondaryTextColor: String?
  var artworkTertiaryTextColor: String?
  @Attribute(.externalStorage) var userEditedFields: [String] = []
  @Relationship(deleteRule: .cascade) var songs: [LibrarySong] = []

  enum ArtworkSource: String, Codable {
    case embedded
    case online
    case user
  }

  var artworkSource: ArtworkSource {
    get { ArtworkSource(rawValue: artworkSourceRaw) ?? .embedded }
    set { artworkSourceRaw = newValue.rawValue }
  }
  var createdDate: Date
  var isExplicit: Bool = false
  var isCompilation: Bool = false
  var genre: [String]?
  var albumDescription: String?
  var appleMusicId: String?

  init(
    name: String,
    artist: String? = nil,
    year: Int? = nil,
    artworkPath: String? = nil,
    embeddedArtworkPath: String? = nil,
    artworkBackgroundColor: String? = nil,
    artworkPrimaryTextColor: String? = nil,
    artworkSecondaryTextColor: String? = nil,
    artworkTertiaryTextColor: String? = nil,
    albumDescription: String? = nil,
    appleMusicId: String? = nil
  ) {
    self.id = UUID()
    self.name = name
    self.artist = artist
    self.year = year
    self.artworkPath = artworkPath
    self.embeddedArtworkPath = embeddedArtworkPath
    self.artworkBackgroundColor = artworkBackgroundColor
    self.artworkPrimaryTextColor = artworkPrimaryTextColor
    self.artworkSecondaryTextColor = artworkSecondaryTextColor
    self.artworkTertiaryTextColor = artworkTertiaryTextColor
    self.createdDate = Date()
    self.isExplicit = false
    self.genre = nil
    self.albumDescription = albumDescription
    self.appleMusicId = appleMusicId
  }

  /// Returns the song count for this album.
  var songCount: Int {
    songs.count
  }

  /// Updates album artwork if a song in the album has artwork.
  func updateArtwork(from song: LibrarySong) {
    if artworkPath == nil, let songArtwork = song.artworkPath {
      artworkPath = songArtwork
    }
    if embeddedArtworkPath == nil, let songEmbedded = song.embeddedArtworkPath {
      embeddedArtworkPath = songEmbedded
    }
    if artworkBackgroundColor == nil { artworkBackgroundColor = song.artworkBackgroundColor }
    if artworkPrimaryTextColor == nil { artworkPrimaryTextColor = song.artworkPrimaryTextColor }
    if artworkSecondaryTextColor == nil { artworkSecondaryTextColor = song.artworkSecondaryTextColor }
    if artworkTertiaryTextColor == nil { artworkTertiaryTextColor = song.artworkTertiaryTextColor }
  }

  static func == (lhs: Album, rhs: Album) -> Bool {
    lhs.id == rhs.id
  }

  func hash(into hasher: inout Hasher) {
    hasher.combine(id)
  }
}
