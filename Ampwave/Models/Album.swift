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
    @Relationship(deleteRule: .cascade) var songs: [LibrarySong] = []
    var createdDate: Date
    var isExplicit: Bool = false
    var genre: [String]?
    
    init(
        name: String,
        artist: String? = nil,
        year: Int? = nil,
        artworkPath: String? = nil
    ) {
        self.id = UUID()
        self.name = name
        self.artist = artist
        self.year = year
        self.artworkPath = artworkPath
        self.createdDate = Date()
        self.isExplicit = false
        self.genre = nil
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
    }
    
    static func == (lhs: Album, rhs: Album) -> Bool {
        lhs.id == rhs.id
    }
    
    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}
