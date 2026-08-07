//
//  FetchedMetadata.swift
//  Ampwave
//

import Foundation

enum MetadataSource: String, Codable {
  case embedded
  case filename
  case appleMusic
  case musicBrainz
  case manual
}

struct FetchedMetadata {
  var title: String?
  var artist: String?
  var album: String?
  var year: Int?
  var genre: String?
  var trackNumber: Int?
  var discNumber: Int?
  var duration: TimeInterval?
  var musicBrainzId: String?
  var appleMusicId: String?
  var albumAppleMusicId: String?
  var artistAppleMusicId: String?
  var artworkURL: URL?
  var songDescription: String?
  var albumArtist: String?
  var composer: String?
  var lyricist: String?
  var isrc: String?
  var appleMusicURL: URL?
  var albumDescription: String?
  var artistBio: String?
  var hasLyrics: Bool = false
  var lyrics: String?
  var isExplicit: Bool?
  var artworkBackgroundColor: String?
  var artworkPrimaryTextColor: String?
  var artworkSecondaryTextColor: String?
  var artworkTertiaryTextColor: String?
  var source: MetadataSource = .appleMusic

  init(
    title: String? = nil,
    artist: String? = nil,
    album: String? = nil,
    year: Int? = nil,
    genre: String? = nil,
    trackNumber: Int? = nil,
    discNumber: Int? = nil,
    duration: TimeInterval? = nil,
    musicBrainzId: String? = nil,
    appleMusicId: String? = nil,
    albumAppleMusicId: String? = nil,
    artistAppleMusicId: String? = nil,
    artworkURL: URL? = nil,
    songDescription: String? = nil,
    albumArtist: String? = nil,
    composer: String? = nil,
    lyricist: String? = nil,
    isrc: String? = nil,
    appleMusicURL: URL? = nil,
    albumDescription: String? = nil,
    artistBio: String? = nil,
    hasLyrics: Bool = false,
    lyrics: String? = nil,
    isExplicit: Bool? = nil,
    artworkBackgroundColor: String? = nil,
    artworkPrimaryTextColor: String? = nil,
    artworkSecondaryTextColor: String? = nil,
    artworkTertiaryTextColor: String? = nil,
    source: MetadataSource = .appleMusic
  ) {
    self.title = title
    self.artist = artist
    self.album = album
    self.year = year
    self.genre = genre
    self.trackNumber = trackNumber
    self.discNumber = discNumber
    self.duration = duration
    self.musicBrainzId = musicBrainzId
    self.appleMusicId = appleMusicId
    self.albumAppleMusicId = albumAppleMusicId
    self.artistAppleMusicId = artistAppleMusicId
    self.artworkURL = artworkURL
    self.songDescription = songDescription
    self.albumArtist = albumArtist
    self.composer = composer
    self.lyricist = lyricist
    self.isrc = isrc
    self.appleMusicURL = appleMusicURL
    self.albumDescription = albumDescription
    self.artistBio = artistBio
    self.hasLyrics = hasLyrics
    self.lyrics = lyrics
    self.isExplicit = isExplicit
    self.artworkBackgroundColor = artworkBackgroundColor
    self.artworkPrimaryTextColor = artworkPrimaryTextColor
    self.artworkSecondaryTextColor = artworkSecondaryTextColor
    self.artworkTertiaryTextColor = artworkTertiaryTextColor
    self.source = source
  }
}
