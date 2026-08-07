//
//  ArtistMetadata.swift
//  Ampwave
//

import Foundation

struct ArtistMetadata {
  var name: String
  var sortName: String?
  var disambiguation: String?
  var country: String?
  var origin: String?
  var activeYears: String?
  var genres: [String]?
  var biography: String?
  var musicBrainzId: String?
  var appleMusicId: String?
  var artworkURL: URL?
  var fanartURL: URL?

  init(
    name: String,
    sortName: String? = nil,
    disambiguation: String? = nil,
    country: String? = nil,
    origin: String? = nil,
    activeYears: String? = nil,
    genres: [String]? = nil,
    biography: String? = nil,
    musicBrainzId: String? = nil,
    appleMusicId: String? = nil,
    artworkURL: URL? = nil,
    fanartURL: URL? = nil
  ) {
    self.name = name
    self.sortName = sortName
    self.disambiguation = disambiguation
    self.country = country
    self.origin = origin
    self.activeYears = activeYears
    self.genres = genres
    self.biography = biography
    self.musicBrainzId = musicBrainzId
    self.appleMusicId = appleMusicId
    self.artworkURL = artworkURL
    self.fanartURL = fanartURL
  }
}
