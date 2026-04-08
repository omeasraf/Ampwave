//
//  FetchedMetadata.swift
//  Ampwave
//

import Foundation

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
    var artworkURL: URL?
    
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
        artworkURL: URL? = nil
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
        self.artworkURL = artworkURL
    }
}
