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

@MainActor
@Observable
final class MetadataService {
  static let shared = MetadataService()

  var modelContext: ModelContext?

  // API Endpoints
  private let musicBrainzDefaultURL = "https://musicbrainz.org/ws/2"
  private let coverArtArchiveURL = "https://coverartarchive.org"
  private let fanartTVURL = "https://webservice.fanart.tv/v3/music"
  private let theAudioDBURL = "https://www.theaudiodb.com/api/v1/json/2"

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

  func performRequest(url: URL, retries: Int = 3) async -> Data? {
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
    
    // 1. Try Apple Music first (Primary)
    if let amMetadata = await AppleMusicMetadataService.shared.fetchMetadata(
      title: song.title,
      artist: song.artist,
      duration: song.duration
    ) {
      print("[DEBUG] MetadataService.fetchMetadata: Found match on Apple Music")
      return amMetadata
    }

    // 2. Fallback to MusicBrainz (Secondary)
    print("[DEBUG] MetadataService.fetchMetadata: Apple Music failed, falling back to MusicBrainz")
    await respectRateLimit()

    // Search for recording on MusicBrainz
    print("[DEBUG] MetadataService.fetchMetadata: Searching MusicBrainz for recording")
    guard let searchMatch = await searchRecording(song: song) else {
      print("[DEBUG] MetadataService.fetchMetadata: Recording search failed")
      return nil
    }

    // Fetch full recording details with genres and releases
    print("[DEBUG] MetadataService.fetchMetadata: Fetching details for recording \(searchMatch.id)")
    guard let recording = await fetchRecordingDetails(mbid: searchMatch.id) else {
      print("[DEBUG] MetadataService.fetchMetadata: Recording details fetch failed")
      return nil
    }

    // Parse release date
    let releaseYear = parseReleaseDate(recording.firstReleaseDate)

    // Extract genres from both 'genres' and 'tags'
    let genreLabel = extractGenreLabel(genres: recording.genres, tags: recording.tags)

    // Fetch detailed metadata
    let firstRelease = recording.releases?.first
    let recordingArtist = recording.artistCredit?.first?.name ?? song.artist
    var metadata = FetchedMetadata(
      title: recording.title,
      artist: recordingArtist,
      album: firstRelease?.title,
      year: releaseYear,
      genre: genreLabel,
      trackNumber: nil,
      discNumber: nil,
      duration: recording.length.map { TimeInterval($0) / 1000.0 },
      musicBrainzId: recording.id,
      artworkURL: nil,
      songDescription: song.songDescription,
      albumArtist: firstRelease?.artistCredit?.first?.name ?? recordingArtist,
      isrc: recording.isrcs?.first,
      source: .musicBrainz
    )

    // Fetch artwork if we have a release
    if let releaseId = recording.releases?.first?.id {
      print("[DEBUG] MetadataService.fetchMetadata: Fetching artwork URL for release \(releaseId)")
      metadata.artworkURL = await fetchArtworkURL(forRelease: releaseId)
    }

    // Fallback: If no artwork found via recording, but we have an album title, search for the release specifically
    if metadata.artworkURL == nil, let albumTitle = metadata.album {
      print(
        "[DEBUG] MetadataService.fetchMetadata: No artwork found via recording, searching release for \(albumTitle)"
      )
      let searchArtist = metadata.artist ?? song.artist
      if let release = await searchRelease(albumTitle: albumTitle, artist: searchArtist) {
        metadata.artworkURL = await fetchArtworkURL(forRelease: release.id)
        if metadata.year == nil || metadata.year == 0 {
          metadata.year = parseReleaseDate(release.date)
        }
        if metadata.albumArtist == nil {
          metadata.albumArtist = release.artistCredit?.first?.name
        }
      }
    }

    return metadata
  }

  /// Lightweight genre lookup (MusicBrainz recording tags) for backfill and partial updates.
  func fetchGenreTags(for song: LibrarySong) async -> String? {
    await respectRateLimit()
    guard let recording = await searchRecording(song: song) else { return nil }
    guard let details = await fetchRecordingDetails(mbid: recording.id) else { return nil }
    return extractGenreLabel(genres: details.genres, tags: details.tags)
  }

  private func fetchRecordingDetails(mbid: String) async -> MusicBrainzRecordingDetailResponse? {
    let urlString = "\(musicBrainzDefaultURL)/recording/\(mbid)?inc=genres+tags+artist-credits+releases+release-groups+isrcs&fmt=json"
    guard let url = URL(string: urlString) else { return nil }
    guard let data = await performRequest(url: url) else { return nil }
    do {
      let detail = try JSONDecoder().decode(MusicBrainzRecordingDetailResponse.self, from: data)
      return detail
    } catch {
      print("[DEBUG] MetadataService.fetchRecordingDetails: decode error \(error)")
      return nil
    }
  }

  private func extractGenreLabel(genres: [MusicBrainzGenre]?, tags: [MusicBrainzCountedTag]?) -> String? {
    var genreNames = Set<String>()

    // 1. Process explicit genres first
    if let genres = genres {
      for g in genres {
        if let normalized = normalizeGenreName(g.name) {
          genreNames.insert(normalized)
        }
      }
    }

    // 2. Process tags if we don't have enough genres yet
    if genreNames.count < 3, let tags = tags {
      let sortedTags = tags.sorted { ($0.count ?? 0) > ($1.count ?? 0) }
      for tag in sortedTags {
        if let normalized = normalizeGenreName(tag.name) {
          genreNames.insert(normalized)
        }
        if genreNames.count >= 3 { break }
      }
    }

    let sorted = Array(genreNames).sorted()
    return sorted.isEmpty ? nil : sorted.joined(separator: " / ")
  }

  private func fetchGenreTagsForRecording(mbid: String) async -> String? {
    guard let details = await fetchRecordingDetails(mbid: mbid) else { return nil }
    return extractGenreLabel(genres: details.genres, tags: details.tags)
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

    let artistInfo = await searchArtist(artist: artist)
    let theAudioDBInfo = await searchTheAudioDBArtist(artist: artist)
    // Apple Music has artist photos for far more artists than TheAudioDB, so
    // prefer it and fall back to the TheAudioDB thumbnail.
    let appleArtworkURL = await AppleMusicMetadataService.shared.fetchArtistArtworkURL(
      name: artist.name
    )

    var genres: Set<String> = []
    if let mbGenres = artistInfo?.genres {
      for g in mbGenres { genres.insert(g.name) }
    }

    if let tdbGenre = theAudioDBInfo?.strGenre, !tdbGenre.isEmpty {
      genres.insert(tdbGenre)
    }
    if let tdbStyle = theAudioDBInfo?.strStyle, !tdbStyle.isEmpty {
      genres.insert(tdbStyle)
    }

    return ArtistMetadata(
      name: artistInfo?.name ?? theAudioDBInfo?.strArtist ?? artist.name,
      sortName: artistInfo?.sortName,
      disambiguation: artistInfo?.disambiguation,
      country: artistInfo?.country ?? theAudioDBInfo?.strCountry,
      origin: theAudioDBInfo?.strCountry,
      activeYears: calculateActiveYears(tdb: theAudioDBInfo),
      genres: Array(genres).sorted(),
      biography: theAudioDBInfo?.strBiography,
      musicBrainzId: artistInfo?.id ?? theAudioDBInfo?.strMusicBrainzID,
      artworkURL: appleArtworkURL ?? theAudioDBInfo?.strArtistThumb.flatMap { URL(string: $0) },
      fanartURL: theAudioDBInfo?.strArtistFanart.flatMap { URL(string: $0) }
    )
  }

  private func calculateActiveYears(tdb: TheAudioDBArtist?) -> String? {
    guard let tdb = tdb else { return nil }

    let start = tdb.intBornYear ?? tdb.intFormedYear
    let end = tdb.strDisbanded == "Yes" ? "Disbanded" : "Present"

    if let startYear = start {
      return "\(startYear) – \(end)"
    }
    return nil
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
    // Escape double quotes for Lucene query
    let title = song.title.replacingOccurrences(of: "\"", with: "\\\"")
    let artist = song.artist.replacingOccurrences(of: "\"", with: "\\\"")

    // Primary query: strict recording + artist
    let query = "recording:\"\(title)\" AND artist:\"\(artist)\""

    var components = URLComponents(string: "\(musicBrainzDefaultURL)/recording")
    components?.queryItems = [
      URLQueryItem(name: "query", value: query),
      URLQueryItem(name: "fmt", value: "json"),
      URLQueryItem(name: "limit", value: "5"),
    ]

    guard let url = components?.url else { return nil }
    print("[DEBUG] MetadataService.searchRecording: URL: \(url.absoluteString)")

    if let data = await performRequest(url: url) {
      do {
        let response = try JSONDecoder().decode(MusicBrainzRecordingSearchResponse.self, from: data)
        if let match = bestRecordingMatch(for: song, in: response.recordings ?? []),
          !response.recordings!.isEmpty
        {
          return match
        }
      } catch {
        print("[DEBUG] MetadataService.searchRecording: Decoding error: \(error)")
      }
    }

    // Fallback query: just search text (less strict)
    print("[DEBUG] MetadataService.searchRecording: Strict search failed, trying fallback")
    let fallbackQuery = "\(title) \(artist)"
    var fallbackComponents = URLComponents(string: "\(musicBrainzDefaultURL)/recording")
    fallbackComponents?.queryItems = [
      URLQueryItem(name: "query", value: fallbackQuery),
      URLQueryItem(name: "fmt", value: "json"),
      URLQueryItem(name: "limit", value: "5"),
    ]

    if let fallbackUrl = fallbackComponents?.url,
      let data = await performRequest(url: fallbackUrl)
    {
      do {
        let response = try JSONDecoder().decode(MusicBrainzRecordingSearchResponse.self, from: data)
        return bestRecordingMatch(for: song, in: response.recordings ?? [])
      } catch {
        print("[DEBUG] MetadataService.searchRecording Fallback: Decoding error: \(error)")
      }
    }

    return nil
  }

  private func searchRelease(albumTitle: String, artist: String) async -> MusicBrainzRelease? {
    let cleanTitle = albumTitle.replacingOccurrences(of: "\"", with: "\\\"")
    let cleanArtist = artist.replacingOccurrences(of: "\"", with: "\\\"")
    let query = "release:\"\(cleanTitle)\" AND artist:\"\(cleanArtist)\""

    var components = URLComponents(string: "\(musicBrainzDefaultURL)/release")
    components?.queryItems = [
      URLQueryItem(name: "query", value: query),
      URLQueryItem(name: "fmt", value: "json"),
      URLQueryItem(name: "limit", value: "5"),
    ]

    guard let url = components?.url else { return nil }

    if let data = await performRequest(url: url) {
      do {
        let response = try JSONDecoder().decode(MusicBrainzReleaseSearchResponse.self, from: data)
        if let match = response.releases?.first {
          return match
        }
      } catch {}
    }

    // Fallback
    let fallbackQuery = "\(cleanTitle) \(cleanArtist)"
    var fallbackComponents = URLComponents(string: "\(musicBrainzDefaultURL)/release")
    fallbackComponents?.queryItems = [
      URLQueryItem(name: "query", value: fallbackQuery),
      URLQueryItem(name: "fmt", value: "json"),
      URLQueryItem(name: "limit", value: "5"),
    ]

    if let fallbackUrl = fallbackComponents?.url,
      let data = await performRequest(url: fallbackUrl)
    {
      do {
        let response = try JSONDecoder().decode(MusicBrainzReleaseSearchResponse.self, from: data)
        return response.releases?.first
      } catch {}
    }

    return nil
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
      return bestReleaseMatch(for: album, in: response.releases ?? [])
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

  private func searchTheAudioDBArtist(artist: Artist) async -> TheAudioDBArtist? {
    var components = URLComponents(string: "\(theAudioDBURL)/search.php")
    components?.queryItems = [
      URLQueryItem(name: "s", value: artist.name)
    ]

    guard let url = components?.url else { return nil }
    print("[DEBUG] MetadataService.searchTheAudioDBArtist: URL: \(url.absoluteString)")

    guard let data = await performRequest(url: url) else { return nil }

    do {
      let response = try JSONDecoder().decode(TheAudioDBArtistSearchResponse.self, from: data)
      return response.artists?.first
    } catch {
      print("[DEBUG] MetadataService.searchTheAudioDBArtist: Decoding error: \(error)")
      return nil
    }
  }

  /// Searches for multiple artwork options for a song or album
  func searchArtworkOptions(title: String, artist: String) async -> [URL] {
    print("[DEBUG] MetadataService.searchArtworkOptions: Searching for \(title) by \(artist)")

    // 1. Search for releases on MusicBrainz
    let query =
      "release:\"\(title.replacingOccurrences(of: "\"", with: "\\\""))\" AND artist:\"\(artist.replacingOccurrences(of: "\"", with: "\\\""))\""
    var components = URLComponents(string: "\(musicBrainzDefaultURL)/release")
    components?.queryItems = [
      URLQueryItem(name: "query", value: query),
      URLQueryItem(name: "fmt", value: "json"),
      URLQueryItem(name: "limit", value: "10"),
    ]

    guard let url = components?.url else { return [] }

    var artworkURLs: [URL] = []
    if let data = await performRequest(url: url) {
      do {
        let response = try JSONDecoder().decode(MusicBrainzReleaseSearchResponse.self, from: data)
        if let releases = response.releases {
          // Fetch artwork for each release ID
          for release in releases {
            if let artworkURL = await fetchArtworkURL(forRelease: release.id) {
              if !artworkURLs.contains(artworkURL) {
                artworkURLs.append(artworkURL)
              }
            }
            if artworkURLs.count >= 12 { break }  // Limit to 12 results
          }
        }
      } catch {
        print("[DEBUG] MetadataService.searchArtworkOptions: Decoding error: \(error)")
      }
    }

    // 2. If we have very few results, try a broader search
    if artworkURLs.count < 3 {
      let fallbackQuery = "\(title) \(artist)"
      var fallbackComponents = URLComponents(string: "\(musicBrainzDefaultURL)/release")
      fallbackComponents?.queryItems = [
        URLQueryItem(name: "query", value: fallbackQuery),
        URLQueryItem(name: "fmt", value: "json"),
        URLQueryItem(name: "limit", value: "10"),
      ]

      if let fallbackUrl = fallbackComponents?.url,
        let data = await performRequest(url: fallbackUrl)
      {
        do {
          let response = try JSONDecoder().decode(MusicBrainzReleaseSearchResponse.self, from: data)
          if let releases = response.releases {
            for release in releases {
              if let artworkURL = await fetchArtworkURL(forRelease: release.id) {
                if !artworkURLs.contains(artworkURL) {
                  artworkURLs.append(artworkURL)
                }
              }
              if artworkURLs.count >= 12 { break }
            }
          }
        } catch {}
      }
    }

    return artworkURLs
  }

  // MARK: - Cover Art Archive

  private func fetchArtworkURL(forRelease releaseId: String) async -> URL? {
    let urlString = "\(coverArtArchiveURL)/release/\(releaseId)"

    guard let url = URL(string: urlString) else { return nil }

    if let data = await performRequest(url: url) {
      do {
        // If data starts with '<', it's likely HTML/XML (e.g. error page)
        if let firstByte = data.first, firstByte == 60 {  // '<' character
          print(
            "[DEBUG] MetadataService.fetchArtworkURL: Received non-JSON response for release \(releaseId)"
          )
          return nil
        }

        let response = try JSONDecoder().decode(CoverArtArchiveResponse.self, from: data)

        // Prefer a reasonably sized front cover thumbnail before falling back to originals.
        let frontImages = response.images.filter { $0.types.contains("Front") }
        let bestImage = frontImages.max { $0.image.width ?? 0 < $1.image.width ?? 0 }

        let artworkURL =
          bestImage?.thumbnails.thumb500
          ?? bestImage?.thumbnails.large
          ?? bestImage?.image.url
          ?? response.images.first?.thumbnails.thumb500
          ?? response.images.first?.image.url

        return artworkURL.flatMap { forceHTTPS($0) }
      } catch {
        print("Failed to decode artwork JSON: \(error)")
        return nil
      }
    }
    return nil
  }

  // MARK: - Artwork Caching

  /// Downloads and caches artwork
  func downloadArtwork(from url: URL) async -> String? {
    let secureURL = forceHTTPS(url)
    print("[DEBUG] MetadataService.downloadArtwork: Downloading from \(secureURL.absoluteString)")

    do {
      // Use performRequest for consistent User-Agent and retry logic
      if let data = await performRequest(url: secureURL) {
        // Cache the artwork
        return await cacheArtwork(data, for: nil)
      }
      return nil
    } catch {
      print("Failed to download artwork: \(error)")
      return nil
    }
  }

  private func forceHTTPS(_ url: URL) -> URL {
    guard url.scheme == "http" else { return url }
    var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
    components?.scheme = "https"
    return components?.url ?? url
  }

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

    var needsSave = false

    // Update song fields only if they're empty or generic (Preserve user edits)
    if let title = metadata.title, !title.isEmpty,
      !song.userEditedFields.contains("title"),
      (song.titleConfidence < 0.8 || song.title == song.fileName || song.title.contains("Untitled"))
    {
      song.title = title
      song.titleConfidence = (metadata.source == .appleMusic) ? 0.95 : MetadataConfidenceScorer.scoreMusicBrainz(value: title)
      song.metadataSourceTitle = metadata.source.rawValue
      needsSave = true
    }
    if let artist = metadata.artist, !artist.isEmpty,
      !song.userEditedFields.contains("artist"),
      (song.artistConfidence < 0.8 || song.artist == "Unknown Artist" || song.artist.isEmpty)
    {
      song.artist = artist
      song.artistConfidence = (metadata.source == .appleMusic) ? 0.95 : MetadataConfidenceScorer.scoreMusicBrainz(value: artist)
      song.metadataSourceArtist = metadata.source.rawValue
      needsSave = true
    }
    if let album = metadata.album, !album.isEmpty,
      !song.userEditedFields.contains("album"),
      (song.albumConfidence < 0.8 || song.album == nil || song.album == "Unknown Album" || song.album?.isEmpty == true)
    {
      song.album = album
      song.albumConfidence = (metadata.source == .appleMusic) ? 0.95 : MetadataConfidenceScorer.scoreMusicBrainz(value: album)
      song.metadataSourceAlbum = metadata.source.rawValue
      needsSave = true
    }
    if let year = metadata.year,
      !song.userEditedFields.contains("year"),
      song.year == nil || song.year == 0
    {
      song.year = year
      needsSave = true
    }
    if let trackNumber = metadata.trackNumber,
      !song.userEditedFields.contains("trackNumber"),
      song.trackNumber == nil
    {
      song.trackNumber = trackNumber
      needsSave = true
    }
    if let discNumber = metadata.discNumber,
      !song.userEditedFields.contains("discNumber"),
      song.discNumber == nil
    {
      song.discNumber = discNumber
      needsSave = true
    }
    if let explicit = metadata.isExplicit, explicit != song.isExplicit {
      song.isExplicit = explicit
      needsSave = true
    }
    if let genre = metadata.genre, !genre.isEmpty,
      !song.userEditedFields.contains("genre"),
      song.genre == nil || song.genre?.isEmpty == true
    {
      song.genre = normalizedGenreLabel(from: genre)
      needsSave = true
    }
    if let albumArtist = metadata.albumArtist, !albumArtist.isEmpty,
      !song.userEditedFields.contains("albumArtist"),
      song.albumArtist == nil || song.albumArtist?.isEmpty == true
    {
      song.albumArtist = albumArtist
      needsSave = true
    }
    if let composer = metadata.composer, !composer.isEmpty,
      !song.userEditedFields.contains("composer"),
      song.composer == nil || song.composer?.isEmpty == true
    {
      song.composer = composer
      needsSave = true
    }
    if let lyricist = metadata.lyricist, !lyricist.isEmpty,
      !song.userEditedFields.contains("lyricist"),
      song.lyricist == nil || song.lyricist?.isEmpty == true
    {
        song.lyricist = lyricist
        needsSave = true
    }
    if let isrc = metadata.isrc, !isrc.isEmpty {
      song.isrc = isrc
      needsSave = true
    }
    if let appleMusicURL = metadata.appleMusicURL {
      song.appleMusicURL = appleMusicURL.absoluteString
      needsSave = true
    }

    // Save artwork colors
    if let bgColor = metadata.artworkBackgroundColor {
        song.artworkBackgroundColor = bgColor
        needsSave = true
    }
    if let primaryColor = metadata.artworkPrimaryTextColor {
        song.artworkPrimaryTextColor = primaryColor
        needsSave = true
    }
    if let secondaryColor = metadata.artworkSecondaryTextColor {
        song.artworkSecondaryTextColor = secondaryColor
        needsSave = true
    }
    if let tertiaryColor = metadata.artworkTertiaryTextColor {
        song.artworkTertiaryTextColor = tertiaryColor
        needsSave = true
    }
    
    // Save experimental lyrics if found
    if let lyrics = metadata.lyrics, (song.lyrics == nil || song.lyrics?.isEmpty == true) {
        song.lyrics = lyrics
        needsSave = true
    }
    
    // Update related models
    if let albumRef = song.albumReference {
        if let desc = metadata.albumDescription, (albumRef.albumDescription == nil || albumRef.albumDescription?.isEmpty == true) {
            albumRef.albumDescription = desc
        }
        if albumRef.appleMusicId == nil {
            albumRef.appleMusicId = metadata.appleMusicId
        }
        if let explicit = metadata.isExplicit {
            albumRef.isExplicit = explicit
        }
    }
    
    let artistNames = ArtistParser.parseArtists(from: metadata.albumArtist ?? metadata.artist ?? song.artist)
    if let primaryArtist = artistNames.first {
        let artist = SongLibrary.shared.getArtist(named: primaryArtist)
        if let artist = artist {
            if let bio = metadata.artistBio, (artist.biography == nil || artist.biography?.isEmpty == true) {
                artist.biography = bio
            }
            if artist.appleMusicId == nil {
                artist.appleMusicId = metadata.appleMusicId // Note: this might be song ID, not artist ID. Need to fix in service if so.
            }
        }
    }

    if let duration = metadata.duration, duration > 0, song.duration <= 0 {
      song.duration = duration
      needsSave = true
    }

    // Download and cache artwork if available
    if let artworkURL = metadata.artworkURL {
      // Only replace if no artwork or if remote artwork is preferred and not user-selected
      let prefs = UserPreferences.getOrCreate(in: modelContext)
      let isUserSelected = song.artworkSource == .user
      let hasEmbeddedArt = song.embeddedArtworkPath != nil

      // If preferEmbeddedArtwork is true and we have embedded art, don't replace
      let shouldRespectEmbedded = prefs.preferEmbeddedArtwork && hasEmbeddedArt

      if song.artworkPath == nil
        || (prefs.preferOnlineArtwork && !isUserSelected && !shouldRespectEmbedded)
      {
        if let artworkPath = await downloadArtwork(from: artworkURL) {
          song.artworkPath = artworkPath
          song.isRemoteArtwork = true
          song.artworkSource = .online
          needsSave = true
        }
      }
    }

    if needsSave {
      song.metadataCheckAttempted = true
      try? modelContext.save()
    }
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

    // Save artwork colors
    if let bgColor = metadata.artworkBackgroundColor {
        album.artworkBackgroundColor = bgColor
    }
    if let primaryColor = metadata.artworkPrimaryTextColor {
        album.artworkPrimaryTextColor = primaryColor
    }
    if let secondaryColor = metadata.artworkSecondaryTextColor {
        album.artworkSecondaryTextColor = secondaryColor
    }
    if let tertiaryColor = metadata.artworkTertiaryTextColor {
        album.artworkTertiaryTextColor = tertiaryColor
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

  private func bestRecordingMatch(
    for song: LibrarySong,
    in candidates: [MusicBrainzRecording]
  ) -> MusicBrainzRecording? {
    let scored =
      candidates
      .map { ($0, scoreRecording($0, against: song)) }
      .sorted { $0.1 > $1.1 }

    // Increased threshold from 1.5 to 2.2 for higher confidence
    guard let best = scored.first, best.1 >= 2.2 else {
      print(
        "[DEBUG] MetadataService.bestRecordingMatch: No candidate reached threshold (Best: \(scored.first?.1 ?? 0))"
      )
      return nil
    }
    return best.0
  }

  private func bestReleaseMatch(
    for album: Album,
    in candidates: [MusicBrainzRelease]
  ) -> MusicBrainzRelease? {
    let albumTitle = normalizedSearchText(album.name)
    let albumArtist = normalizedSearchText(album.artist ?? "")

    let scored =
      candidates
      .map { release -> (MusicBrainzRelease, Double) in
        var score = stringSimilarityScore(normalizedSearchText(release.title), albumTitle)
        if let releaseArtist = release.artistCredit?.first?.name {
          score += stringSimilarityScore(normalizedSearchText(releaseArtist), albumArtist)
        }
        return (release, score)
      }
      .sorted { $0.1 > $1.1 }

    guard let best = scored.first, best.1 >= 1.3 else { return nil }
    return best.0
  }

  private func scoreRecording(_ recording: MusicBrainzRecording, against song: LibrarySong)
    -> Double
  {
    let localTitle = normalizedSearchText(song.title)
    let localArtist = normalizedSearchText(song.artist)
    let localAlbum = normalizedSearchText(song.album ?? "")

    var score = 0.0

    // Title match (Weighted high)
    let titleSimilarity = stringSimilarityScore(normalizedSearchText(recording.title), localTitle)
    score += titleSimilarity * 2.0

    // Artist match (Weighted high)
    if let artistName = recording.artistCredit.first?.name {
      let artistSimilarity = stringSimilarityScore(normalizedSearchText(artistName), localArtist)
      score += artistSimilarity * 1.5
    }

    // Album match (Weighted medium - very important to avoid wrong artwork)
    if let release = recording.releases?.first {
      let releaseTitle = normalizedSearchText(release.title)
      if !localAlbum.isEmpty && localAlbum != "unknown album" {
        let albumSimilarity = stringSimilarityScore(releaseTitle, localAlbum)
        score += albumSimilarity * 1.2

        // Bonus for exact album match
        if releaseTitle == localAlbum {
          score += 0.5
        }
      } else {
        // If we don't have a local album, we can't be as sure, but we don't penalize
        score += 0.2
      }
    }

    // Duration match (Crucial for identifying correct version/track)
    if let remoteDuration = recording.length.map({ TimeInterval($0) / 1000.0 }), song.duration > 0 {
      let difference = abs(remoteDuration - song.duration)
      if difference <= 3 {
        score += 1.0  // Very high confidence
      } else if difference <= 8 {
        score += 0.6
      } else if difference <= 20 {
        score += 0.2
      } else if difference >= 60 {
        score -= 1.0  // Likely a different version or extended mix
      }
    }

    return score
  }

  private func stringSimilarityScore(_ lhs: String, _ rhs: String) -> Double {
    guard !lhs.isEmpty, !rhs.isEmpty else { return 0 }
    if lhs == rhs { return 1.0 }
    if lhs.hasPrefix(rhs) || rhs.hasPrefix(lhs) { return 0.85 }
    if lhs.contains(rhs) || rhs.contains(lhs) { return 0.65 }

    let lhsTokens = Set(lhs.split(separator: " ").map(String.init))
    let rhsTokens = Set(rhs.split(separator: " ").map(String.init))
    let overlap = lhsTokens.intersection(rhsTokens).count
    let union = lhsTokens.union(rhsTokens).count
    guard union > 0 else { return 0 }
    return Double(overlap) / Double(union)
  }

  private func normalizedSearchText(_ value: String) -> String {
    value
      .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
      .replacingOccurrences(
        of: "[^a-z0-9 ]",
        with: " ",
        options: .regularExpression
      )
      .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .lowercased()
  }

  private func normalizeGenreName(_ value: String) -> String? {
    let cleaned = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !cleaned.isEmpty else { return nil }

    let normalized = cleaned.lowercased()

    // Blacklist common non-genre MusicBrainz tags
    let blacklist: Set<String> = [
      "favorite", "seen live", "good", "best", "awesome", "classic", "beautiful",
      "amazing", "great", "love", "chill", "relax", "mellow", "fast", "slow",
      "instrumental", "vocal", "female vocalists", "male vocalists", "canadian",
      "british", "american", "japanese", "german", "french", "swedish", "under 2000 listeners",
      "top", "playlist", "spotify", "apple music", "itunes", "2010s", "2020s", "90s", "80s", "70s",
      "60s",
      "remix", "cover", "bootleg", "live", "recording", "studio", "independent", "indie",
      "heard on pandora", "heard on xm", "heard on radio", "heard on tv", "soundtrack",
    ]

    if blacklist.contains(normalized) {
      return nil
    }

    let mapped: String
    switch normalized {
    case "hip hop", "hip-hop", "rap":
      mapped = "Hip-Hop"
    case "rnb", "r&b":
      mapped = "R&B"
    case "alt rock", "alternative rock":
      mapped = "Alternative"
    case "electronica":
      mapped = "Electronic"
    case "j pop", "j-pop":
      mapped = "J-Pop"
    case "k pop", "k-pop":
      mapped = "K-Pop"
    case "heavy metal", "death metal", "black metal", "thrash metal":
      mapped = "Metal"
    default:
      mapped =
        cleaned
        .split(separator: " ")
        .map { $0.prefix(1).uppercased() + $0.dropFirst().lowercased() }
        .joined(separator: " ")
    }

    return mapped
  }

  private func normalizedGenreLabel(from label: String) -> String {
    let parts =
      label
      .split(separator: "/")
      .flatMap { $0.split(separator: ",") }
      .compactMap { normalizeGenreName(String($0)) }

    var seen = Set<String>()
    let unique = parts.filter { seen.insert($0).inserted }
    return unique.joined(separator: " / ")
  }
}

// MARK: - TheAudioDB Models

struct TheAudioDBArtistSearchResponse: Codable {
  let artists: [TheAudioDBArtist]?
}

struct TheAudioDBArtist: Codable {
  let idArtist: String?
  let strArtist: String?
  let strGenre: String?
  let strStyle: String?
  let strBiography: String?
  let strArtistThumb: String?
  let strArtistLogo: String?
  let strArtistCutout: String?
  let strArtistClearart: String?
  let strArtistWideThumb: String?
  let strArtistFanart: String?
  let strArtistFanart2: String?
  let strArtistFanart3: String?
  let strArtistBanner: String?
  let strMusicBrainzID: String?
  let strISNIcode: String?
  let strFacebook: String?
  let strTwitter: String?
  let strWebsite: String?
  let strGender: String?
  let strCountry: String?
  let strCountryCode: String?
  let intBornYear: String?
  let intFormedYear: String?
  let strDisbanded: String?
}
