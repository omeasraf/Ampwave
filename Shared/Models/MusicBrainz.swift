//
//  MusicBrainz.swift
//  Ampwave
//

import Foundation

struct MusicBrainzRecordingSearchResponse: Codable {
  let recordings: [MusicBrainzRecording]?

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    recordings = try container.decodeIfPresent([MusicBrainzRecording].self, forKey: .recordings)
  }

  enum CodingKeys: String, CodingKey {
    case recordings
  }

  func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encodeIfPresent(recordings, forKey: .recordings)
  }
}

struct MusicBrainzRecording: Codable {
  let id: String
  let title: String
  let length: Int?
  let firstReleaseDate: String?
  let artistCredit: [MusicBrainzArtistCredit]
  let releases: [MusicBrainzReleaseRef]?

  enum CodingKeys: String, CodingKey {
    case id
    case title
    case length
    case firstReleaseDate = "first-release-date"
    case artistCredit = "artist-credit"
    case releases
  }
}

struct MusicBrainzArtistCredit: Codable {
  let name: String
  let artist: MusicBrainzArtistRef
}

struct MusicBrainzArtistRef: Codable {
  let id: String
  let name: String
}

struct MusicBrainzReleaseRef: Codable {
  let id: String
  let title: String
}

struct MusicBrainzReleaseSearchResponse: Codable {
  let releases: [MusicBrainzRelease]?

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    releases = try container.decodeIfPresent([MusicBrainzRelease].self, forKey: .releases)
  }

  enum CodingKeys: String, CodingKey {
    case releases
  }

  func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encodeIfPresent(releases, forKey: .releases)
  }
}

struct MusicBrainzRelease: Codable {
  let id: String
  let title: String
  let date: String?
  let artistCredit: [MusicBrainzArtistCredit]?

  enum CodingKeys: String, CodingKey {
    case id
    case title
    case date
    case artistCredit = "artist-credit"
  }
}

struct MusicBrainzArtistSearchResponse: Codable {
  let artists: [MusicBrainzArtist]?

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    artists = try container.decodeIfPresent([MusicBrainzArtist].self, forKey: .artists)
  }

  enum CodingKeys: String, CodingKey {
    case artists
  }

  func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encodeIfPresent(artists, forKey: .artists)
  }
}

struct MusicBrainzArtist: Codable {
  let id: String
  let name: String
  let sortName: String?
  let disambiguation: String?
  let country: String?
  let genres: [MusicBrainzGenre]?

  enum CodingKeys: String, CodingKey {
    case id
    case name
    case sortName = "sort-name"
    case disambiguation
    case country
    case genres
  }
}

struct MusicBrainzGenre: Codable {
  let name: String
}
