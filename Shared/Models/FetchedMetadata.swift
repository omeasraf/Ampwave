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

enum BackstageCreditCategory: String, Codable, CaseIterable, Sendable {
  case performance
  case songwriting
  case production
  case engineering
  case other

  var displayName: String {
    switch self {
    case .performance: return "Performance"
    case .songwriting: return "Songwriting"
    case .production: return "Production"
    case .engineering: return "Engineering"
    case .other: return "Additional Credits"
    }
  }

  var systemImage: String {
    switch self {
    case .performance: return "music.mic"
    case .songwriting: return "pencil.and.scribble"
    case .production: return "waveform.badge.magnifyingglass"
    case .engineering: return "slider.horizontal.3"
    case .other: return "sparkles"
    }
  }
}

enum BackstageCreditSource: String, Codable, CaseIterable, Sendable {
  case embedded
  case appleMusic
  case musicBrainz

  var displayName: String {
    switch self {
    case .embedded: return "File"
    case .appleMusic: return "Apple Music"
    case .musicBrainz: return "MusicBrainz"
    }
  }
}

/// A normalized person/role pair used by the Backstage credits experience.
/// Stored as compact JSON on `LibrarySong` so richer provider data can evolve
/// without introducing a large SwiftData relationship graph.
struct BackstageCredit: Codable, Hashable, Identifiable, Sendable {
  let name: String
  let role: String
  let category: BackstageCreditCategory
  var sources: [BackstageCreditSource]
  var musicBrainzArtistID: String?

  var id: String {
    "\(Self.normalized(name))|\(Self.normalized(role))"
  }

  init(
    name: String,
    role: String,
    category: BackstageCreditCategory,
    sources: [BackstageCreditSource],
    musicBrainzArtistID: String? = nil
  ) {
    self.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
    self.role = role.trimmingCharacters(in: .whitespacesAndNewlines)
    self.category = category
    self.sources = Array(Set(sources)).sorted { $0.rawValue < $1.rawValue }
    self.musicBrainzArtistID = musicBrainzArtistID
  }

  /// Deduplicates providers that report the same contribution while retaining
  /// every source that corroborated it. Apple Music entries are kept first.
  static func merged(_ groups: [[BackstageCredit]]) -> [BackstageCredit] {
    var merged: [String: BackstageCredit] = [:]

    for credit in groups.flatMap({ $0 }) where !credit.name.isEmpty && !credit.role.isEmpty {
      if var existing = merged[credit.id] {
        existing.sources = Array(Set(existing.sources + credit.sources)).sorted {
          sourceRank($0) < sourceRank($1)
        }
        if existing.musicBrainzArtistID == nil {
          existing.musicBrainzArtistID = credit.musicBrainzArtistID
        }
        merged[credit.id] = existing
      } else {
        merged[credit.id] = credit
      }
    }

    return merged.values.sorted {
      let lhsCategory = BackstageCreditCategory.allCases.firstIndex(of: $0.category) ?? .max
      let rhsCategory = BackstageCreditCategory.allCases.firstIndex(of: $1.category) ?? .max
      if lhsCategory != rhsCategory { return lhsCategory < rhsCategory }
      if $0.role != $1.role { return $0.role.localizedCaseInsensitiveCompare($1.role) == .orderedAscending }
      return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
    }
  }

  private static func normalized(_ value: String) -> String {
    value
      .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
      .replacingOccurrences(of: "[^a-z0-9]", with: "", options: .regularExpression)
  }

  private static func sourceRank(_ source: BackstageCreditSource) -> Int {
    switch source {
    case .appleMusic: return 0
    case .musicBrainz: return 1
    case .embedded: return 2
    }
  }
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
  var backstageCredits: [BackstageCredit]
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
    backstageCredits: [BackstageCredit] = [],
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
    self.backstageCredits = backstageCredits
    self.source = source
  }
}
