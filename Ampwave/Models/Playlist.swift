//
//  Playlist.swift
//  Ampwave
//
//  SwiftData model for user-created playlists.
//  Supports liked songs, custom playlists, and smart playlists.
//

import Foundation
import SwiftData
internal import SwiftUI

@Model
final class Playlist: Identifiable, Hashable {
    // MARK: - Identity
    @Attribute(.unique) var id: UUID
    var name: String
    var playlistDescription: String?
    
    // MARK: - Metadata
    var createdDate: Date
    var lastModifiedDate: Date
    var artworkPath: String?
    
    var icon: String?
    
    // MARK: - Playlist Type
    var playlistType: PlaylistType
    
    // MARK: - Relationships
    @Relationship(deleteRule: .nullify) var songs: [LibrarySong] = []
    
    // MARK: - Smart Playlist Rules (for smart playlists)
    var smartRules: SmartPlaylistRules?
    
    // MARK: - User Preferences
    var isPinned: Bool
    var sortOrder: PlaylistSortOrder
    
    init(
        name: String,
        description: String? = nil,
        playlistType: PlaylistType = .custom,
        artworkPath: String? = nil,
        icon: String? = nil
    ) {
        self.id = UUID()
        self.name = name
        self.playlistDescription = description
        self.playlistType = playlistType
        self.artworkPath = artworkPath
        self.icon = icon
        self.createdDate = Date()
        self.lastModifiedDate = Date()
        self.isPinned = false
        self.sortOrder = .manual
    }
    
    /// Returns the song count for this playlist
    var songCount: Int {
        songs.count
    }
    
    /// Returns total duration of all songs in the playlist
    var totalDuration: TimeInterval {
        songs.reduce(0) { $0 + $1.duration }
    }
    
    /// Updates the last modified date
    func touch() {
        lastModifiedDate = Date()
    }
    
    /// Adds a song to the playlist if not already present
    func addSong(_ song: LibrarySong) {
        guard !songs.contains(where: { $0.id == song.id }) else { return }
        songs.append(song)
        touch()
    }
    
    /// Removes a song from the playlist
    func removeSong(_ song: LibrarySong) {
        if let index = songs.firstIndex(where: { $0.id == song.id }) {
            songs.remove(at: index)
            touch()
        }
    }
    
    /// Moves a song from one index to another
    func moveSong(from source: IndexSet, to destination: Int) {
        songs.move(fromOffsets: source, toOffset: destination)
        touch()
    }
    
    /// Checks if the playlist contains a specific song
    func contains(_ song: LibrarySong) -> Bool {
        songs.contains(where: { $0.id == song.id })
    }
    
    /// Generates a collage artwork from song artworks
    func generateArtwork(from library: SongLibrary) -> String? {
        // Get up to 4 unique artwork paths from songs
        let artworkPaths = songs.compactMap { $0.artworkPath }.uniqued().prefix(4)
        guard !artworkPaths.isEmpty else { return nil }
        
        // If only one artwork, use it directly
        if artworkPaths.count == 1 {
            return artworkPaths.first
        }
        
        // TODO: Generate collage image from multiple artworks
        // For now, return the first artwork
        return artworkPaths.first
    }
    
    static func == (lhs: Playlist, rhs: Playlist) -> Bool {
        lhs.id == rhs.id
    }
    
    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}

// MARK: - Helpers

extension Sequence where Element: Hashable {
    func uniqued() -> [Element] {
        var seen = Set<Element>()
        return filter { seen.insert($0).inserted }
    }
}
