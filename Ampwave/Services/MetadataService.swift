//
//  MetadataService.swift
//  Ampwave
//
//  Service for fetching metadata from online sources.
//  Uses MusicBrainz for metadata and Cover Art Archive for artwork.
//

import CryptoKit
import Foundation
import Observation
import SwiftData

#if os(iOS)
  import UIKit
#else
  import AppKit
#endif

@Observable
final class MetadataService {
  static let shared = MetadataService()

  var modelContext: ModelContext?

  // API Endpoints
  private let musicBrainzDefaultURL = "https://musicbrainz.org/ws/2"
  private let coverArtArchiveURL = "https://coverartarchive.org"
  private let fanartTVURL = "https://webservice.fanart.tv/v3/music"

  // Rate limiting - now MainActor isolated
  @MainActor private var lastRequestTime: Date?
  private let minimumRequestInterval: TimeInterval = 1.5  // Safer base rate limit

  // App identifier for MusicBrainz (required)
  private let appIdentifier = "AmpwavePlayer/1.0 (https://github.com/omeasraf/Ampwave)"

  private init() {}

  func setModelContext(_ context: ModelContext) {
    self.modelContext = context
  }

  // MARK: - Internal Request Helper

  private func performRequest(url: URL, retries: Int = 3) async -> Data? {
    var attempt = 0
    var backoffDelay: TimeInterval = 1.5

    while attempt < retries {
      if attempt > 0 {
        print(
          "[DEBUG] MetadataService: Retrying request (attempt \(attempt + 1)/\(retries)) after \(backoffDelay)s..."
        )
        try? await Task.sleep(nanoseconds: UInt64(backoffDelay * 1_000_000_000))
        backoffDelay *= 2.0  // Exponential backoff
      }

      var request = URLRequest(url: url)
      request.setValue(appIdentifier, forHTTPHeaderField: "User-Agent")
      request.timeoutInterval = 15.0

      do {
        let (data, response) = try await URLSession.shared.data(for: request)

        if let httpResponse = response as? HTTPURLResponse {
          if httpResponse.statusCode == 200 {
            return data
          } else if httpResponse.statusCode == 503 || httpResponse.statusCode == 429 {
            // Check for Retry-After header
            var retryAfter: TimeInterval = backoffDelay
            if let retryAfterHeader = httpResponse.value(forHTTPHeaderField: "Retry-After"),
              let seconds = Double(retryAfterHeader)
            {
              retryAfter = seconds
              print("[DEBUG] MetadataService: MusicBrainz requested Retry-After \(seconds)s")
            } else {
              print(
                "[DEBUG] MetadataService: Rate limited (HTTP \(httpResponse.statusCode)) - no header found"
              )
            }

            attempt += 1
            backoffDelay = max(backoffDelay, retryAfter)
            continue
          } else {
            print(
              "[DEBUG] MetadataService: Server error (HTTP \(httpResponse.statusCode)) for \(url.absoluteString)"
            )
            return nil
          }
        }
        return data
      } catch {
        print("[DEBUG] MetadataService: Network error: \(error.localizedDescription)")
        attempt += 1
      }
    }
    return nil
  }

  // MARK: - Public API

  /// Fetches metadata for a song from online sources
  func fetchMetadata(for song: LibrarySong) async -> FetchedMetadata? {
    print("[DEBUG] MetadataService.fetchMetadata: Starting for \(song.title)")
    // Respect rate limiting
    await respectRateLimit()

    // Search for recording on MusicBrainz
    print("[DEBUG] MetadataService.fetchMetadata: Searching MusicBrainz for recording")
    guard let recording = await searchRecording(song: song) else {
      print("[DEBUG] MetadataService.fetchMetadata: Recording search failed")
      return nil
    }

    // Parse release date
    let releaseYear = parseReleaseDate(recording.firstReleaseDate)

    // Fetch detailed metadata
    var metadata = FetchedMetadata(
      title: recording.title,
      artist: recording.artistCredit.first?.name ?? song.artist,
      album: recording.releases?.first?.title,
      year: releaseYear,
      genre: nil,
      trackNumber: nil,
      discNumber: nil,
      duration: recording.length.map { TimeInterval($0) / 1000.0 },
      musicBrainzId: recording.id,
      artworkURL: nil
    )

    // Fetch artwork if we have a release
    if let releaseId = recording.releases?.first?.id {
      print("[DEBUG] MetadataService.fetchMetadata: Fetching artwork URL for release \(releaseId)")
      metadata.artworkURL = await fetchArtworkURL(forRelease: releaseId)
    }

    return metadata
  }

  /// Fetches metadata for an album
  func fetchMetadata(for album: Album) async -> FetchedMetadata? {
    await respectRateLimit()

    guard let release = await searchRelease(album: album) else {
      return nil
    }

    // Parse release date
    let releaseYear = parseReleaseDate(release.date)

    var metadata = FetchedMetadata(
      title: nil,
      artist: release.artistCredit?.first?.name ?? album.artist,
      album: release.title,
      year: releaseYear,
      genre: nil,
      trackNumber: nil,
      discNumber: nil,
      duration: nil,
      musicBrainzId: release.id,
      artworkURL: nil
    )

    // Fetch artwork
    metadata.artworkURL = await fetchArtworkURL(forRelease: release.id)

    return metadata
  }

  /// Fetches metadata for an artist
  func fetchMetadata(for artist: Artist) async -> ArtistMetadata? {
    await respectRateLimit()

    guard let artistInfo = await searchArtist(artist: artist) else {
      return nil
    }

    return ArtistMetadata(
      name: artistInfo.name,
      sortName: artistInfo.sortName,
      disambiguation: artistInfo.disambiguation,
      country: artistInfo.country,
      genres: artistInfo.genres?.map { $0.name },
      biography: nil,  // Would need additional API
      musicBrainzId: artistInfo.id,
      artworkURL: nil
    )
  }

  /// Downloads and caches artwork
  func downloadArtwork(from url: URL) async -> String? {
    do {
      let (data, _) = try await URLSession.shared.data(from: url)

      // Validate that data is valid image
      #if os(iOS)
        guard UIImage(data: data) != nil else { return nil }
      #else
        guard NSImage(data: data) != nil else { return nil }
      #endif

      // Cache the artwork
      return await cacheArtwork(data, for: nil)
    } catch {
      print("Failed to download artwork: \(error)")
      return nil
    }
  }

  /// Refreshes metadata for a song
  @MainActor
  func refreshMetadata(for song: LibrarySong) async {
    guard let metadata = await fetchMetadata(for: song) else { return }

    // Update song with new metadata
    await applyMetadata(metadata, to: song)
  }

  /// Refreshes metadata for an album
  @MainActor
  func refreshMetadata(for album: Album) async {
    guard let metadata = await fetchMetadata(for: album) else { return }

    // Update album with new metadata
    await applyMetadata(metadata, to: album)
  }

  // MARK: - Private Methods

  @MainActor
  private func respectRateLimit() async {
    let now = Date()
    var waitTime: TimeInterval = 0

    if let lastTime = lastRequestTime {
      let timeSinceLastRequest = now.timeIntervalSince(lastTime)
      if timeSinceLastRequest < minimumRequestInterval {
        waitTime = minimumRequestInterval - timeSinceLastRequest
      }
    }

    if waitTime > 0 {
      lastRequestTime = now.addingTimeInterval(waitTime)
    } else {
      lastRequestTime = now
    }

    if waitTime > 0 {
      try? await Task.sleep(nanoseconds: UInt64(waitTime * 1_000_000_000))
    }
  }

  // MARK: - MusicBrainz Search

  private func searchRecording(song: LibrarySong) async -> MusicBrainzRecording? {
    let query = "recording:\"\(song.title)\" AND artist:\"\(song.artist)\""

    var components = URLComponents(string: "\(musicBrainzDefaultURL)/recording")
    components?.queryItems = [
      URLQueryItem(name: "query", value: query),
      URLQueryItem(name: "fmt", value: "json"),
      URLQueryItem(name: "limit", value: "5"),
    ]

    guard let url = components?.url else { return nil }
    print("[DEBUG] MetadataService.searchRecording: URL: \(url.absoluteString)")

    guard let data = await performRequest(url: url) else { return nil }

    do {
      let response = try JSONDecoder().decode(MusicBrainzRecordingSearchResponse.self, from: data)
      return response.recordings?.first
    } catch {
      print("[DEBUG] MetadataService.searchRecording: Decoding error: \(error)")
      return nil
    }
  }

  private func searchRelease(album: Album) async -> MusicBrainzRelease? {
    let artistName = album.artist ?? "Unknown Artist"
    let query = "release:\"\(album.name)\" AND artist:\"\(artistName)\""

    var components = URLComponents(string: "\(musicBrainzDefaultURL)/release")
    components?.queryItems = [
      URLQueryItem(name: "query", value: query),
      URLQueryItem(name: "fmt", value: "json"),
      URLQueryItem(name: "limit", value: "5"),
    ]

    guard let url = components?.url else { return nil }
    print("[DEBUG] MetadataService.searchRelease: URL: \(url.absoluteString)")

    guard let data = await performRequest(url: url) else { return nil }

    do {
      let response = try JSONDecoder().decode(MusicBrainzReleaseSearchResponse.self, from: data)
      return response.releases?.first
    } catch {
      print("[DEBUG] MetadataService.searchRelease: Decoding error: \(error)")
      return nil
    }
  }

  private func searchArtist(artist: Artist) async -> MusicBrainzArtist? {
    let query = "\"\(artist.name)\""

    var components = URLComponents(string: "\(musicBrainzDefaultURL)/artist")
    components?.queryItems = [
      URLQueryItem(name: "query", value: query),
      URLQueryItem(name: "fmt", value: "json"),
      URLQueryItem(name: "limit", value: "5"),
    ]

    guard let url = components?.url else { return nil }
    print("[DEBUG] MetadataService.searchArtist: URL: \(url.absoluteString)")

    guard let data = await performRequest(url: url) else { return nil }

    do {
      let response = try JSONDecoder().decode(MusicBrainzArtistSearchResponse.self, from: data)
      return response.artists?.first
    } catch {
      print("[DEBUG] MetadataService.searchArtist: Decoding error: \(error)")
      return nil
    }
  }

  // MARK: - Cover Art Archive

  private func fetchArtworkURL(forRelease releaseId: String) async -> URL? {
    let urlString = "\(coverArtArchiveURL)/release/\(releaseId)"

    guard let url = URL(string: urlString) else { return nil }

    do {
      let (data, _) = try await URLSession.shared.data(from: url)
      let response = try JSONDecoder().decode(CoverArtArchiveResponse.self, from: data)

      // Find the front cover with the highest resolution
      let frontImages = response.images.filter { $0.types.contains("Front") }
      let bestImage = frontImages.max { $0.image.width ?? 0 < $1.image.width ?? 0 }

      return bestImage?.image.url ?? response.images.first?.image.url
    } catch {
      print("Failed to fetch artwork: \(error)")
      return nil
    }
  }

  // MARK: - Artwork Caching

  private func cacheArtwork(_ data: Data, for song: LibrarySong?) async -> String? {
    let hash = data.sha256()
    let fileName = "\(hash).jpg"

    let library = SongLibrary.shared
    let artworkURL = library.artworkCacheDirectory.appendingPathComponent(fileName)

    // Check if already cached
    if FileManager.default.fileExists(atPath: artworkURL.path) {
      return PathManager.relativePath(from: artworkURL.path)
    }

    // Write to cache
    do {
      try data.write(to: artworkURL)
      return PathManager.relativePath(from: artworkURL.path)
    } catch {
      print("Failed to cache artwork: \(error)")
      return nil
    }
  }

  // MARK: - Apply Metadata

  @MainActor
  private func applyMetadata(_ metadata: FetchedMetadata, to song: LibrarySong) async {
    guard let modelContext = modelContext else { return }

    // Update song fields
    if let title = metadata.title, !title.isEmpty {
      song.title = title
    }
    if let artist = metadata.artist, !artist.isEmpty {
      song.artist = artist
    }
    if let album = metadata.album, !album.isEmpty {
      song.album = album
    }
    if let year = metadata.year {
      song.year = year
    }
    if let genre = metadata.genre, !genre.isEmpty {
      song.genre = genre
    }
    if let duration = metadata.duration, duration > 0 {
      song.duration = duration
    }

    // Download and cache artwork if available
    if let artworkURL = metadata.artworkURL {
      if let artworkPath = await downloadArtwork(from: artworkURL) {
        song.artworkPath = artworkPath
        song.isRemoteArtwork = true
      }
    }

    song.metadataCheckAttempted = true
    try? modelContext.save()
  }

  @MainActor
  private func applyMetadata(_ metadata: FetchedMetadata, to album: Album) async {
    guard let modelContext = modelContext else { return }

    // Update album fields
    if let artist = metadata.artist, !artist.isEmpty {
      album.artist = artist
    }
    if let year = metadata.year {
      album.year = year
    }

    // Download and cache artwork if available
    if let artworkURL = metadata.artworkURL {
      if let artworkPath = await downloadArtwork(from: artworkURL) {
        album.artworkPath = artworkPath
      }
    }

    try? modelContext.save()
  }

  // MARK: - Date Parsing

  private func parseReleaseDate(_ dateString: String?) -> Int? {
    guard let dateString = dateString else { return nil }

    let formatter = DateFormatter()
    formatter.dateFormat = "yyyy-MM-dd"

    if let date = formatter.date(from: dateString) {
      return Calendar.current.component(.year, from: date)
    }

    // Try year only
    formatter.dateFormat = "yyyy"
    if let date = formatter.date(from: dateString) {
      return Calendar.current.component(.year, from: date)
    }

    return nil
  }
}
