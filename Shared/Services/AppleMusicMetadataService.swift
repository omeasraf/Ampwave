//
//  AppleMusicMetadataService.swift
//  Ampwave
//
//  Service for fetching metadata from Apple Music using MusicKit.
//

import Foundation
import MusicKit
import Observation
import CoreGraphics

@MainActor
@Observable
final class AppleMusicMetadataService {
    // Internal typealiases to resolve shadowing of local models
    private typealias MKSONG = MusicKit.Song
    private typealias MKALB = MusicKit.Album
    private typealias MKART = MusicKit.Artist

    static let shared = AppleMusicMetadataService()
    
    private var isAuthorized = false
    private var cache: [String: FetchedMetadata] = [:]
    
    private init() {}
    
    /// Requests authorization for MusicKit if needed.
    func requestAuthorization() async -> Bool {
        let status = await MusicAuthorization.request()
        self.isAuthorized = (status == .authorized)
        return self.isAuthorized
    }
    
    /// Searches Apple Music for a song and returns the best match with full metadata.
    func fetchMetadata(title: String, artist: String, duration: TimeInterval? = nil) async -> FetchedMetadata? {
        let cacheKey = "\(artist.lowercased())|\(title.lowercased())"
        if let cached = cache[cacheKey] {
            return cached
        }

        if !isAuthorized {
            let authorized = await requestAuthorization()
            guard authorized else { return nil }
        }
        
        do {
            var request = MusicCatalogSearchRequest(term: "\(artist) \(title)", types: [MKSONG.self])
            request.limit = 3 // Reduced from 5 to minimize console noise from malformed placeholders
            
            let response = try await request.response()
            let songs = response.songs
            guard !songs.isEmpty else { return nil }
            
            // Score and find the best match
            let scoredMatches = songs.map { (song: MKSONG) -> (MKSONG, Double) in
                let score = MetadataMatcher.computeMatchScore(
                    title1: title, artist1: artist, duration1: duration,
                    title2: song.title, artist2: song.artistName, duration2: song.duration
                )
                return (song, score)
            }
            
            // Filter by threshold
            let filtered = scoredMatches.filter { $0.1 >= 0.75 }.sorted { $0.1 > $1.1 }
            
            guard let bestMatchItem = filtered.first?.0 else { 
                print("[DEBUG] AppleMusicMetadataService: No match above threshold for \(artist) - \(title)")
                return nil 
            }
            
            print("[DEBUG] AppleMusicMetadataService: Best match: \(bestMatchItem.artistName) - \(bestMatchItem.title) (ID: \(bestMatchItem.id.rawValue))")
            
            // Fetch detailed properties
            let song = try await bestMatchItem.with([.composers, .genres, .albums, .artists])
            
            var albumDescription: String?
            var artistBio: String?
            
            if let album = song.albums?.first {
                print("[DEBUG] AppleMusicMetadataService: Found album via relationship: \(album.title) (ID: \(album.id.rawValue))")
                albumDescription = try? await fetchAlbumEditorialNotes(album)
            } else {
                print("[DEBUG] AppleMusicMetadataService: No album relationship found, attempting fallback search for \(song.albumTitle ?? "unknown album")")
                if let albumTitle = song.albumTitle {
                    albumDescription = try? await fetchAlbumEditorialNotesByTitle(albumTitle)
                }
            }
            
            if let artist = song.artists?.first {
                print("[DEBUG] AppleMusicMetadataService: Found primary artist via relationship: \(artist.name) (ID: \(artist.id.rawValue))")
                artistBio = try? await fetchArtistEditorialNotes(artist)
            } else {
                print("[DEBUG] AppleMusicMetadataService: No artist relationship found, attempting fallback search for \(song.artistName)")
                artistBio = try? await fetchArtistEditorialNotesByName(song.artistName)
            }
            
            var directLyrics: String?
            if song.hasLyrics {
                print("[DEBUG] AppleMusicMetadataService: Song has lyrics, attempting experimental direct fetch...")
                directLyrics = await fetchLyricsDirectly(songId: song.id.rawValue)
            }
            
            var metadata = mapSongToMetadata(song, albumDescription: albumDescription, artistBio: artistBio)
            if let lyrics = directLyrics {
                metadata.lyrics = lyrics
            }
            cache[cacheKey] = metadata
            return metadata
        } catch {
            print("[DEBUG] AppleMusicMetadataService: Search error: \(error)")
            return nil
        }
    }

    private func fetchAlbumEditorialNotes(_ album: MKALB) async throws -> String? {
        if album.id.rawValue.isEmpty {
            return try await fetchAlbumEditorialNotesByTitle(album.title)
        }

        let request = MusicCatalogResourceRequest<MKALB>(matching: \.id, equalTo: album.id)
        let response = try await request.response()
        guard let detailed = response.items.first else { return nil }
        return cleanEditorialNotes(detailed.editorialNotes?.standard ?? detailed.editorialNotes?.short)
    }

    private func fetchAlbumEditorialNotesByTitle(_ title: String) async throws -> String? {
        print("[DEBUG] AppleMusicMetadataService: Searching album editorial notes by title: \(title)")
        var searchRequest = MusicCatalogSearchRequest(term: title, types: [MKALB.self])
        searchRequest.limit = 1
        let searchResponse = try await searchRequest.response()
        guard let found = searchResponse.albums.first else { return nil }
        return cleanEditorialNotes(found.editorialNotes?.standard ?? found.editorialNotes?.short)
    }

    private func fetchArtistEditorialNotes(_ artist: MKART) async throws -> String? {
        if artist.id.rawValue.isEmpty {
            return try await fetchArtistEditorialNotesByName(artist.name)
        }

        let request = MusicCatalogResourceRequest<MKART>(matching: \.id, equalTo: artist.id)
        let response = try await request.response()
        guard let detailed = response.items.first else { return nil }
        return cleanEditorialNotes(detailed.editorialNotes?.standard ?? detailed.editorialNotes?.short)
    }

    private func fetchArtistEditorialNotesByName(_ name: String) async throws -> String? {
        print("[DEBUG] AppleMusicMetadataService: Searching artist editorial notes by name: \(name)")
        var searchRequest = MusicCatalogSearchRequest(term: name, types: [MKART.self])
        searchRequest.limit = 1
        let searchResponse = try await searchRequest.response()
        guard let found = searchResponse.artists.first else { return nil }
        return cleanEditorialNotes(found.editorialNotes?.standard ?? found.editorialNotes?.short)
    }
    
    private func cleanEditorialNotes(_ notes: String?) -> String? {
        guard let notes = notes else { return nil }
        // Remove XML tags and decode common entities as per Apple Music API docs
        return notes.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&apos;", with: "'")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
    
    private func mapSongToMetadata(_ song: MKSONG, albumDescription: String? = nil, artistBio: String? = nil) -> FetchedMetadata {
        let composers = song.composers?.compactMap { $0.name }.joined(separator: " / ")
        let genres = song.genreNames.filter { $0 != "Music" }.joined(separator: " / ")

        let artists = song.artists?.compactMap { $0.name } ?? []
        let combinedArtist = artists.isEmpty ? song.artistName : artists.joined(separator: " & ")

        // Use album artist from the album relationship when available
        let albumArtist = song.albums?.first?.artistName ?? combinedArtist

        let isExplicit: Bool? = {
            switch song.contentRating {
            case .explicit: return true
            case .clean: return false
            default: return nil
            }
        }()

        return FetchedMetadata(
            title: song.title,
            artist: combinedArtist,
            album: song.albumTitle,
            year: extractYear(from: song.releaseDate),
            genre: genres.isEmpty ? nil : genres,
            trackNumber: song.trackNumber,
            discNumber: song.discNumber,
            duration: song.duration,
            appleMusicId: song.id.rawValue,
            artworkURL: song.artwork?.url(width: 1000, height: 1000),
            albumArtist: albumArtist,
            composer: composers ?? song.composerName,
            isrc: song.isrc,
            appleMusicURL: song.url,
            albumDescription: albumDescription,
            artistBio: artistBio,
            hasLyrics: song.hasLyrics,
            isExplicit: isExplicit,
            artworkBackgroundColor: hexString(from: song.artwork?.backgroundColor),
            artworkPrimaryTextColor: hexString(from: song.artwork?.primaryTextColor),
            artworkSecondaryTextColor: hexString(from: song.artwork?.secondaryTextColor),
            artworkTertiaryTextColor: hexString(from: song.artwork?.tertiaryTextColor),
            source: .appleMusic
        )
    }
    
    private func extractYear(from date: Date?) -> Int? {
        guard let date = date else { return nil }
        return Calendar.current.component(.year, from: date)
    }

    private func hexString(from color: CGColor?) -> String? {
        guard let color = color, let components = color.components else { return nil }
        let r, g, b: CGFloat
        if components.count >= 3 {
            r = components[0]
            g = components[1]
            b = components[2]
        } else {
            r = components[0]
            g = components[0]
            b = components[0]
        }
        return String(format: "#%02X%02X%02X", Int(r * 255), Int(g * 255), Int(b * 255))
    }

    private func fetchLyricsDirectly(songId: String) async -> String? {
        do {
            let storefront = try await MusicDataRequest.currentCountryCode
            let url = URL(string: "https://api.music.apple.com/v1/catalog/\(storefront)/songs/\(songId)/lyrics")!
            let request = MusicDataRequest(urlRequest: URLRequest(url: url))
            let response = try await request.response()
            
            // The response for lyrics is complex and usually returns TTML data
            // We'll try to extract something readable if it succeeds
            let json = try JSONSerialization.jsonObject(with: response.data) as? [String: Any]
            if let data = json?["data"] as? [[String: Any]], let first = data.first {
                if let attributes = first["attributes"] as? [String: Any], let ttml = attributes["ttml"] as? String {
                    print("[DEBUG] AppleMusicMetadataService: Successfully retrieved TTML lyrics")
                    return ttml
                }
            }
            return nil
        } catch {
            print("[DEBUG] AppleMusicMetadataService: Experimental lyrics fetch failed: \(error)")
            return nil
        }
    }
}
