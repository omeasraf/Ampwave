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
    var genres: [String]?
    var biography: String?
    var musicBrainzId: String?
    var artworkURL: URL?
    
    init(
        name: String,
        sortName: String? = nil,
        disambiguation: String? = nil,
        country: String? = nil,
        genres: [String]? = nil,
        biography: String? = nil,
        musicBrainzId: String? = nil,
        artworkURL: URL? = nil
    ) {
        self.name = name
        self.sortName = sortName
        self.disambiguation = disambiguation
        self.country = country
        self.genres = genres
        self.biography = biography
        self.musicBrainzId = musicBrainzId
        self.artworkURL = artworkURL
    }
}
