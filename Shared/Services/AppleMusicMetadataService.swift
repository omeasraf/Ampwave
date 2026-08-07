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

struct AppleMusicArtistProfile {
    let id: String
    let biography: String?
    let genres: [String]
    let artworkURL: URL?
}

struct AppleMusicAlbumProfile {
    let id: String
    let description: String?
    let artworkURL: URL?
}

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
    private var artistArtworkCache: [String: URL?] = [:]
    private var albumArtworkCache: [String: URL?] = [:]
    
    /// MusicKit does its own networking, so it never passes through
    /// `MetadataService.performRequest` where Offline Mode is enforced for
    /// every other provider. Each public entry point checks here instead.
    private var networkAllowed: Bool {
        guard UserPreferences.networkAllowed else {
            print("[DEBUG] AppleMusicMetadataService: Offline Mode on — skipping request")
            return false
        }
        return true
    }

    private init() {}
    
    /// Requests authorization for MusicKit if needed.
    func requestAuthorization() async -> Bool {
        let status = await MusicAuthorization.request()
        self.isAuthorized = (status == .authorized)
        return self.isAuthorized
    }
    
    /// Searches Apple Music for a song and returns the best match with full metadata.
    func fetchMetadata(title: String, artist: String, duration: TimeInterval? = nil) async -> FetchedMetadata? {
        guard networkAllowed else { return nil }
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
            var albumAppleMusicId: String?
            var artistAppleMusicId: String?
            
            if let album = song.albums?.first {
                print("[DEBUG] AppleMusicMetadataService: Found album via relationship: \(album.title) (ID: \(album.id.rawValue))")
                albumAppleMusicId = album.id.rawValue
                albumDescription = try? await fetchAlbumEditorialNotes(album)
            } else {
                print("[DEBUG] AppleMusicMetadataService: No album relationship found, attempting fallback search for \(song.albumTitle ?? "unknown album")")
                if let albumTitle = song.albumTitle {
                    let profile = await fetchAlbumProfile(album: albumTitle, artist: song.artistName)
                    albumAppleMusicId = profile?.id
                    albumDescription = profile?.description
                }
            }
            
            if let artist = song.artists?.first {
                print("[DEBUG] AppleMusicMetadataService: Found primary artist via relationship: \(artist.name) (ID: \(artist.id.rawValue))")
                artistAppleMusicId = artist.id.rawValue
                artistBio = try? await fetchArtistEditorialNotes(artist)
            } else {
                print("[DEBUG] AppleMusicMetadataService: No artist relationship found, attempting fallback search for \(song.artistName)")
                let profile = await fetchArtistProfile(name: song.artistName)
                artistAppleMusicId = profile?.id
                artistBio = profile?.biography
            }
            
            let metadata = mapSongToMetadata(
                song,
                albumDescription: albumDescription,
                artistBio: artistBio,
                albumAppleMusicId: albumAppleMusicId,
                artistAppleMusicId: artistAppleMusicId
            )
            cache[cacheKey] = metadata
            return metadata
        } catch {
            print("[DEBUG] AppleMusicMetadataService: Search error: \(error)")
            return nil
        }
    }

    private func fetchAlbumEditorialNotes(_ album: MKALB) async throws -> String? {
        guard networkAllowed else { return nil }
        if album.id.rawValue.isEmpty {
            return try await fetchAlbumEditorialNotesByTitle(album.title)
        }

        let request = MusicCatalogResourceRequest<MKALB>(matching: \.id, equalTo: album.id)
        let response = try await request.response()
        guard let detailed = response.items.first else { return nil }
        return cleanEditorialNotes(detailed.editorialNotes?.standard ?? detailed.editorialNotes?.short)
    }

    private func fetchAlbumEditorialNotesByTitle(_ title: String) async throws -> String? {
        guard networkAllowed else { return nil }
        print("[DEBUG] AppleMusicMetadataService: Searching album editorial notes by title: \(title)")
        var searchRequest = MusicCatalogSearchRequest(term: title, types: [MKALB.self])
        searchRequest.limit = 1
        let searchResponse = try await searchRequest.response()
        guard let found = searchResponse.albums.first else { return nil }
        return cleanEditorialNotes(found.editorialNotes?.standard ?? found.editorialNotes?.short)
    }

    /// Apple Music's artist image for `name`, if the catalog has one.
    ///
    /// Artist metadata otherwise comes from MusicBrainz/TheAudioDB, which have
    /// patchy image coverage — Apple Music has a proper photo for most artists.
    func fetchArtistArtworkURL(name: String, width: Int = 800, height: Int = 800) async -> URL? {
        guard networkAllowed else { return nil }
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        if let cached = artistArtworkCache[name.lowercased()] { return cached }

        do {
            var request = MusicCatalogSearchRequest(term: name, types: [MKART.self])
            request.limit = 5
            let response = try await request.response()

            // Exact-ish name match only: a fuzzy hit would attach a stranger's
            // photo to the artist, which is worse than showing no image.
            let target = normalizedArtistName(name)
            let match = response.artists.first { normalizedArtistName($0.name) == target }
            guard let match else {
                print("[DEBUG] AppleMusicMetadataService: No artist artwork match for \(name)")
                return nil
            }

            let url = match.artwork?.url(width: width, height: height)
            artistArtworkCache[name.lowercased()] = url
            return url
        } catch {
            print("[DEBUG] AppleMusicMetadataService: Artist artwork search error: \(error)")
            return nil
        }
    }

    /// A strictly matched Apple Music artist, including its editorial profile.
    func fetchArtistProfile(
        name: String,
        width: Int = 800,
        height: Int = 800
    ) async -> AppleMusicArtistProfile? {
        guard networkAllowed else { return nil }
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { return nil }
        if !isAuthorized, !(await requestAuthorization()) { return nil }

        do {
            var search = MusicCatalogSearchRequest(term: trimmedName, types: [MKART.self])
            search.limit = 5
            let response = try await search.response()
            let target = normalizedArtistName(trimmedName)
            guard let match = response.artists.first(where: {
                normalizedArtistName($0.name) == target
            }) else { return nil }

            let request = MusicCatalogResourceRequest<MKART>(matching: \.id, equalTo: match.id)
            let detailed = try await request.response().items.first ?? match
            return AppleMusicArtistProfile(
                id: detailed.id.rawValue,
                biography: cleanEditorialNotes(
                    detailed.editorialNotes?.standard ?? detailed.editorialNotes?.short
                ),
                genres: (detailed.genreNames ?? []).filter { $0 != "Music" },
                artworkURL: detailed.artwork?.url(width: width, height: height)
            )
        } catch {
            print("[DEBUG] AppleMusicMetadataService: Artist profile search error: \(error)")
            return nil
        }
    }

    /// Apple Music's cover art for an album, if the catalog has it.
    ///
    /// Preferred over the Cover Art Archive: better coverage and consistently
    /// higher resolution.
    func fetchAlbumArtworkURL(
        album: String,
        artist: String?,
        width: Int = 1000,
        height: Int = 1000
    ) async -> URL? {
        guard networkAllowed else { return nil }
        let trimmedAlbum = album.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedAlbum.isEmpty else { return nil }

        let cacheKey = "\(artist?.lowercased() ?? "")|\(trimmedAlbum.lowercased())"
        if let cached = albumArtworkCache[cacheKey] { return cached }

        do {
            let term = [artist, trimmedAlbum].compactMap { $0 }.joined(separator: " ")
            var request = MusicCatalogSearchRequest(term: term, types: [MKALB.self])
            request.limit = 10
            let response = try await request.response()

            let targetAlbum = normalizedArtistName(trimmedAlbum)
            let targetArtist = artist.map { normalizedArtistName($0) }

            // Title must match; artist only when we know it, so
            // "Greatest Hits" doesn't pull a different act's cover.
            let match = response.albums.first { candidate in
                guard normalizedArtistName(candidate.title) == targetAlbum else { return false }
                guard let targetArtist, !targetArtist.isEmpty else { return true }
                return normalizedArtistName(candidate.artistName) == targetArtist
            }

            guard let match else {
                print("[DEBUG] AppleMusicMetadataService: No album artwork match for \(term)")
                return nil
            }

            let url = match.artwork?.url(width: width, height: height)
            albumArtworkCache[cacheKey] = url
            return url
        } catch {
            print("[DEBUG] AppleMusicMetadataService: Album artwork search error: \(error)")
            return nil
        }
    }

    /// A strictly matched Apple Music album, including its editorial profile.
    func fetchAlbumProfile(
        album: String,
        artist: String?,
        width: Int = 1000,
        height: Int = 1000
    ) async -> AppleMusicAlbumProfile? {
        guard networkAllowed else { return nil }
        let trimmedAlbum = album.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedAlbum.isEmpty else { return nil }
        if !isAuthorized, !(await requestAuthorization()) { return nil }

        do {
            let term = [artist, trimmedAlbum].compactMap { $0 }.joined(separator: " ")
            var search = MusicCatalogSearchRequest(term: term, types: [MKALB.self])
            search.limit = 10
            let response = try await search.response()
            let targetAlbum = normalizedArtistName(trimmedAlbum)
            let targetArtist = artist.map(normalizedArtistName)
            guard let match = response.albums.first(where: { candidate in
                guard normalizedArtistName(candidate.title) == targetAlbum else { return false }
                guard let targetArtist, !targetArtist.isEmpty else { return true }
                return normalizedArtistName(candidate.artistName) == targetArtist
            }) else { return nil }

            let request = MusicCatalogResourceRequest<MKALB>(matching: \.id, equalTo: match.id)
            let detailed = try await request.response().items.first ?? match
            return AppleMusicAlbumProfile(
                id: detailed.id.rawValue,
                description: cleanEditorialNotes(
                    detailed.editorialNotes?.standard ?? detailed.editorialNotes?.short
                ),
                artworkURL: detailed.artwork?.url(width: width, height: height)
            )
        } catch {
            print("[DEBUG] AppleMusicMetadataService: Album profile search error: \(error)")
            return nil
        }
    }

    private func normalizedArtistName(_ name: String) -> String {
        name.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .replacingOccurrences(of: "[^a-z0-9]", with: "", options: .regularExpression)
    }

    private func fetchArtistEditorialNotes(_ artist: MKART) async throws -> String? {
        guard networkAllowed else { return nil }
        if artist.id.rawValue.isEmpty {
            return try await fetchArtistEditorialNotesByName(artist.name)
        }

        let request = MusicCatalogResourceRequest<MKART>(matching: \.id, equalTo: artist.id)
        let response = try await request.response()
        guard let detailed = response.items.first else { return nil }
        return cleanEditorialNotes(detailed.editorialNotes?.standard ?? detailed.editorialNotes?.short)
    }

    private func fetchArtistEditorialNotesByName(_ name: String) async throws -> String? {
        guard networkAllowed else { return nil }
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
    
    private func mapSongToMetadata(
        _ song: MKSONG,
        albumDescription: String? = nil,
        artistBio: String? = nil,
        albumAppleMusicId: String? = nil,
        artistAppleMusicId: String? = nil
    ) -> FetchedMetadata {
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
            albumAppleMusicId: albumAppleMusicId,
            artistAppleMusicId: artistAppleMusicId,
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

}
