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

  // MusicBrainz asks clients to serialize requests. Apple Music and the other
  // providers can still run concurrently; only requests to MusicBrainz pass
  // through this reservation timestamp.
  private var lastMusicBrainzRequestTime: Date?
  private let minimumMusicBrainzRequestInterval: TimeInterval = 1.1

  // A throttle response from one concurrent lookup applies to every lookup
  // using that host. Keeping the cooldown here prevents the other workers from
  // immediately consuming all of their own retries against the same provider.
  private var hostBackoffUntil: [String: Date] = [:]
  private(set) var retryableFailureVersion: UInt64 = 0

  // App identifier for MusicBrainz (required)
  private let appIdentifier = "AmpwavePlayer/1.0 (https://github.com/omeasraf/Ampwave)"

  private init() {}

  func setModelContext(_ context: ModelContext) {
    self.modelContext = context
  }

  // MARK: - Internal Request Helper

  func performRequest(url: URL, retries: Int = 4) async -> Data? {
    // Every MusicBrainz / Cover Art / fanart request funnels through here, so
    // this is where Offline Mode is enforced rather than at each caller.
    guard UserPreferences.networkAllowed else {
      print("[DEBUG] MetadataService: Offline Mode on — skipping request")
      return nil
    }
    var attempt = 0
    var backoffDelay: TimeInterval = 0.75

    while attempt < retries {
      guard !Task.isCancelled else { return nil }

      await waitForHostBackoff(url.host)
      guard !Task.isCancelled else { return nil }

      if url.host?.localizedCaseInsensitiveContains("musicbrainz.org") == true {
        await respectMusicBrainzRateLimit()
      }

      var request = URLRequest(url: url)
      request.setValue(appIdentifier, forHTTPHeaderField: "User-Agent")
      request.timeoutInterval = 15.0

      do {
        let (data, response) = try await URLSession.shared.data(for: request)

        if let httpResponse = response as? HTTPURLResponse {
          if (200..<300).contains(httpResponse.statusCode) {
            return data
          } else if httpResponse.statusCode == 429 || (500...599).contains(httpResponse.statusCode) {
            let retryAfter = retryDelay(
              from: httpResponse.value(forHTTPHeaderField: "Retry-After")
            ) ?? backoffDelay
            attempt += 1
            registerBackoff(for: url.host, delay: retryAfter)
            print(
              "[DEBUG] MetadataService: HTTP \(httpResponse.statusCode), retrying in \(String(format: "%.2f", retryAfter))s (\(attempt)/\(retries))"
            )
            backoffDelay = min(max(backoffDelay * 2, retryAfter), 30)
            if attempt >= retries { retryableFailureVersion &+= 1 }
            continue
          } else {
            print(
              "[DEBUG] MetadataService: Server error (HTTP \(httpResponse.statusCode)) for \(url.absoluteString)"
            )
            return nil
          }
        }
        return data
      } catch is CancellationError {
        return nil
      } catch {
        guard !Task.isCancelled else { return nil }
        print("[DEBUG] MetadataService: Network error: \(error.localizedDescription)")
        attempt += 1
        registerBackoff(for: url.host, delay: backoffDelay)
        backoffDelay = min(backoffDelay * 2, 30)
        if attempt >= retries { retryableFailureVersion &+= 1 }
      }
    }
    return nil
  }

  // MARK: - Public API

  /// Value snapshot used by network requests so they never retain a SwiftData
  /// model across suspension points.
  private struct SongLookup {
    let title: String
    let artist: String
    let album: String?
    let duration: TimeInterval
    let songDescription: String?

    init(_ song: LibrarySong) {
      title = song.title
      artist = song.artist
      album = song.album
      duration = song.duration
      songDescription = song.songDescription
    }
  }

  /// Fetches metadata for a song from online sources
  func fetchMetadata(for song: LibrarySong) async -> FetchedMetadata? {
    await fetchMetadata(for: SongLookup(song))
  }

  private func fetchMetadata(for song: SongLookup) async -> FetchedMetadata? {
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
      backstageCredits: musicBrainzCredits(from: recording),
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
    let lookup = SongLookup(song)
    guard let recording = await searchRecording(song: lookup) else { return nil }
    guard let details = await fetchRecordingDetails(mbid: recording.id) else { return nil }
    return extractGenreLabel(genres: details.genres, tags: details.tags)
  }

  private func fetchRecordingDetails(mbid: String) async -> MusicBrainzRecordingDetailResponse? {
    let urlString = "\(musicBrainzDefaultURL)/recording/\(mbid)?inc=genres+tags+artist-credits+releases+release-groups+isrcs+artist-rels+work-rels+work-level-rels&fmt=json"
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

  /// Enriches one song's Backstage credits on demand. MusicKit is consulted
  /// first for the catalog match and associated artists/composers; MusicBrainz
  /// then fills recording and work relationships that MusicKit doesn't expose.
  @discardableResult
  func enrichBackstageCredits(for initialSong: LibrarySong, force: Bool = false) async -> Bool {
    guard UserPreferences.networkAllowed else { return false }
    if initialSong.backstageMetadataCheckAttempted && !force { return true }

    let songID = initialSong.id
    let lookup = SongLookup(initialSong)
    var credits = initialSong.backstageCredits
    var appleMusicID = initialSong.appleMusicId
    var musicBrainzID = initialSong.musicBrainzId
    var providerResponded = false

    if force || !credits.contains(where: { $0.sources.contains(.appleMusic) }) {
      if let apple = await AppleMusicMetadataService.shared.fetchMetadata(
        title: lookup.title,
        artist: lookup.artist,
        duration: lookup.duration
      ) {
        credits = BackstageCredit.merged([credits, apple.backstageCredits])
        appleMusicID = apple.appleMusicId ?? appleMusicID
        providerResponded = true
      }
    }

    var recording: MusicBrainzRecordingDetailResponse?
    if !force, let musicBrainzID {
      recording = await fetchRecordingDetails(mbid: musicBrainzID)
    } else if let match = await searchRecording(song: lookup) {
      musicBrainzID = match.id
      recording = await fetchRecordingDetails(mbid: match.id)
    }

    if let recording {
      credits = BackstageCredit.merged([credits, musicBrainzCredits(from: recording)])
      musicBrainzID = recording.id
      providerResponded = true
    }

    let song = SongLibrary.shared.song(id: songID) ?? initialSong
    guard song.modelContext != nil else { return false }
    song.backstageCredits = credits
    song.appleMusicId = appleMusicID
    song.musicBrainzId = musicBrainzID
    // A completed no-match is still a completed lookup. Do not repeat it on
    // every sheet presentation; the refresh button remains available for a
    // later retry after catalog data changes.
    song.backstageMetadataCheckAttempted = true
    try? modelContext?.save()
    return providerResponded
  }

  private func musicBrainzCredits(
    from recording: MusicBrainzRecordingDetailResponse
  ) -> [BackstageCredit] {
    let primaryArtists = (recording.artistCredit ?? []).map {
      BackstageCredit(
        name: $0.name,
        role: "Artist",
        category: .performance,
        sources: [.musicBrainz],
        musicBrainzArtistID: $0.artist.id
      )
    }

    let recordingCredits = (recording.relations ?? []).compactMap(credit(from:))
    let workCredits = (recording.relations ?? [])
      .compactMap(\.work)
      .flatMap { $0.relations ?? [] }
      .compactMap(credit(from:))

    return BackstageCredit.merged([primaryArtists, recordingCredits, workCredits])
  }

  private func credit(from relation: MusicBrainzRelation) -> BackstageCredit? {
    guard let artist = relation.artist else { return nil }
    let type = relation.type.lowercased()
    let attributes = (relation.attributes ?? [])
      .map(friendlyCreditRole)
      .filter { !$0.isEmpty }

    let category: BackstageCreditCategory
    let role: String
    switch type {
    case "composer", "lyricist", "writer", "librettist", "translator", "arranger", "orchestrator":
      category = .songwriting
      role = friendlyCreditRole(relation.type)
    case "producer", "co-producer", "executive producer", "remixer", "remix", "programming":
      category = .production
      role = friendlyCreditRole(relation.type)
    case "engineer", "mix", "mixing", "mastering", "recording", "sound engineer":
      category = .engineering
      switch type {
      case "mix", "mixing": role = "Mixing Engineer"
      case "mastering": role = "Mastering Engineer"
      case "recording": role = "Recording Engineer"
      default: role = friendlyCreditRole(relation.type)
      }
    case "instrument", "vocal", "performer", "conductor", "concertmaster", "dancer", "spoken vocals", "vocals":
      category = .performance
      role = attributes.isEmpty ? friendlyCreditRole(relation.type) : attributes.joined(separator: ", ")
    default:
      category = .other
      role = attributes.isEmpty ? friendlyCreditRole(relation.type) : attributes.joined(separator: ", ")
    }

    return BackstageCredit(
      name: artist.name,
      role: role,
      category: category,
      sources: [.musicBrainz],
      musicBrainzArtistID: artist.id
    )
  }

  private func friendlyCreditRole(_ value: String) -> String {
    value
      .replacingOccurrences(of: "_", with: " ")
      .split(separator: " ")
      .map { word in
        let lower = word.lowercased()
        if lower == "dj" { return "DJ" }
        return lower.prefix(1).uppercased() + lower.dropFirst()
      }
      .joined(separator: " ")
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

  private struct AlbumLookup {
    let name: String
    let artist: String?
  }

  /// Fetches metadata for an album
  func fetchMetadata(for album: Album) async -> FetchedMetadata? {
    let album = AlbumLookup(name: album.name, artist: album.artist)
    // Apple Music covers albums MusicBrainz misses, so ask it regardless of
    // whether a release match turns up — bailing early used to mean no artwork
    // at all for anything MusicBrainz didn't know.
    let appleProfile = await AppleMusicMetadataService.shared.fetchAlbumProfile(
      album: album.name,
      artist: album.artist
    )

    guard let release = await searchRelease(album: album) else {
      guard let appleProfile else { return nil }
      return FetchedMetadata(
        album: album.name,
        albumAppleMusicId: appleProfile.id,
        artworkURL: appleProfile.artworkURL,
        albumDescription: appleProfile.description
      )
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
      albumAppleMusicId: appleProfile?.id,
      artworkURL: nil,
      albumDescription: appleProfile?.description
    )

    // Prefer Apple Music's cover; fall back to the Cover Art Archive.
    if let appleArtworkURL = appleProfile?.artworkURL {
      metadata.artworkURL = appleArtworkURL
    } else {
      metadata.artworkURL = await fetchArtworkURL(forRelease: release.id)
    }

    return metadata
  }

  /// Fetches metadata for an artist
  func fetchMetadata(for artist: Artist) async -> ArtistMetadata? {
    let artistName = artist.name
    let artistInfo = await searchArtist(name: artistName)
    let theAudioDBInfo = await searchTheAudioDBArtist(name: artistName)
    // Apple Music has artist photos for far more artists than TheAudioDB, so
    // prefer it and fall back to the TheAudioDB thumbnail.
    let appleProfile = await AppleMusicMetadataService.shared.fetchArtistProfile(
      name: artistName
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
    for genre in appleProfile?.genres ?? [] {
      genres.insert(genre)
    }

    return ArtistMetadata(
      name: artistInfo?.name ?? theAudioDBInfo?.strArtist ?? artistName,
      sortName: artistInfo?.sortName,
      disambiguation: artistInfo?.disambiguation,
      country: artistInfo?.country ?? theAudioDBInfo?.strCountry,
      origin: theAudioDBInfo?.strCountry,
      activeYears: calculateActiveYears(tdb: theAudioDBInfo),
      genres: Array(genres).sorted(),
      biography: appleProfile?.biography ?? theAudioDBInfo?.strBiography,
      musicBrainzId: artistInfo?.id ?? theAudioDBInfo?.strMusicBrainzID,
      appleMusicId: appleProfile?.id,
      artworkURL: appleProfile?.artworkURL ?? theAudioDBInfo?.strArtistThumb.flatMap { URL(string: $0) },
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
    let songID = song.id
    guard let metadata = await fetchMetadata(for: song) else { return }

    // The library can be reconciled while the network request is suspended.
    // Apply to the current model, not the instance captured before the await.
    guard let liveSong = SongLibrary.shared.song(id: songID), liveSong.modelContext != nil else {
      return
    }
    await applyMetadata(metadata, to: liveSong)
  }

  /// Refreshes metadata for an album
  @MainActor
  func refreshMetadata(for album: Album) async {
    let albumID = album.id
    guard let metadata = await fetchMetadata(for: album) else { return }
    guard let album = SongLibrary.shared.albums.first(where: { $0.id == albumID }) else { return }
    // Update album with new metadata
    await applyMetadata(metadata, to: album)
  }

  // MARK: - Private Methods

  private func respectMusicBrainzRateLimit() async {
    let now = Date()
    var waitTime: TimeInterval = 0

    if let lastTime = lastMusicBrainzRequestTime {
      let timeSinceLastRequest = now.timeIntervalSince(lastTime)
      if timeSinceLastRequest < minimumMusicBrainzRequestInterval {
        waitTime = minimumMusicBrainzRequestInterval - timeSinceLastRequest
      }
    }

    if waitTime > 0 {
      lastMusicBrainzRequestTime = now.addingTimeInterval(waitTime)
    } else {
      lastMusicBrainzRequestTime = now
    }

    if waitTime > 0 {
      try? await Task.sleep(for: .seconds(waitTime))
    }
  }

  private func waitForHostBackoff(_ host: String?) async {
    guard let host, let deadline = hostBackoffUntil[host] else { return }
    let delay = deadline.timeIntervalSinceNow
    guard delay > 0 else {
      hostBackoffUntil[host] = nil
      return
    }
    try? await Task.sleep(for: .seconds(delay))
    if hostBackoffUntil[host] == deadline { hostBackoffUntil[host] = nil }
  }

  private func registerBackoff(for host: String?, delay: TimeInterval) {
    guard let host else { return }
    let deadline = Date().addingTimeInterval(max(0.25, delay))
    if let existing = hostBackoffUntil[host], existing > deadline { return }
    hostBackoffUntil[host] = deadline
  }

  private func retryDelay(from value: String?) -> TimeInterval? {
    guard let value else { return nil }
    if let seconds = TimeInterval(value.trimmingCharacters(in: .whitespacesAndNewlines)) {
      return max(0.25, seconds)
    }

    // Retry-After may be either delta-seconds or an HTTP date.
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    for format in [
      "EEE',' dd MMM yyyy HH':'mm':'ss z",
      "EEEE',' dd-MMM-yy HH':'mm':'ss z",
      "EEE MMM d HH':'mm':'ss yyyy",
    ] {
      formatter.dateFormat = format
      if let date = formatter.date(from: value) {
        return max(0.25, date.timeIntervalSinceNow)
      }
    }
    return nil
  }

  // MARK: - MusicBrainz Search

  private func searchRecording(song: SongLookup) async -> MusicBrainzRecording? {
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

  private func searchRelease(album: AlbumLookup) async -> MusicBrainzRelease? {
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

  private func searchArtist(name: String) async -> MusicBrainzArtist? {
    let query = "\"\(name)\""

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

  private func searchTheAudioDBArtist(name: String) async -> TheAudioDBArtist? {
    var components = URLComponents(string: "\(theAudioDBURL)/search.php")
    components?.queryItems = [
      URLQueryItem(name: "s", value: name)
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
  func searchArtworkOptions(title: String, artist: String, album: String? = nil) async -> [URL] {
    print("[DEBUG] MetadataService.searchArtworkOptions: Searching for \(title) by \(artist)")

    // MusicKit produces the most consistent covers. Its service deliberately
    // returns nothing unless access was already granted, so denial immediately
    // falls through to the open providers without another permission prompt.
    var artworkURLs = await AppleMusicMetadataService.shared.searchArtworkURLs(
      title: title,
      artist: artist,
      album: album
    )

    // A song title is not normally a MusicBrainz release title. Prefer the
    // embedded album when this request came from SongEditSheet.
    let releaseTitle = album?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
      ? album!
      : title

    // Search exact releases on MusicBrainz, then use Cover Art Archive.
    let query =
      "release:\"\(releaseTitle.replacingOccurrences(of: "\"", with: "\\\""))\" AND artist:\"\(artist.replacingOccurrences(of: "\"", with: "\\\""))\""
    var components = URLComponents(string: "\(musicBrainzDefaultURL)/release")
    components?.queryItems = [
      URLQueryItem(name: "query", value: query),
      URLQueryItem(name: "fmt", value: "json"),
      URLQueryItem(name: "limit", value: "10"),
    ]

    guard let url = components?.url else { return artworkURLs }

    if let data = await performRequest(url: url) {
      do {
        let response = try JSONDecoder().decode(MusicBrainzReleaseSearchResponse.self, from: data)
        if let releases = response.releases {
          // MusicBrainz can return compilations and similarly named releases
          // even for a fielded query. Filter them before fetching any images.
          let targetTitle = normalizedSearchText(releaseTitle)
          let targetArtist = normalizedSearchText(artist)
          let matchingReleases = releases.filter { release in
            let titleScore = stringSimilarityScore(
              normalizedSearchText(release.title), targetTitle
            )
            let artistScore = release.artistCredit?.first.map {
              stringSimilarityScore(normalizedSearchText($0.name), targetArtist)
            } ?? 0
            return titleScore >= 0.85 && artistScore >= 0.8
          }

          for release in matchingReleases {
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

    // Use performRequest for consistent User-Agent and retry logic
    if let data = await performRequest(url: secureURL) {
      // Cache the artwork
      return await cacheArtwork(data, for: nil)
    }
    return nil
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
  private func applyMetadata(_ metadata: FetchedMetadata, to initialSong: LibrarySong) async {
    guard let modelContext = modelContext else { return }

    // Downloading artwork suspends. Decide whether it is needed first, then
    // resolve the live SwiftData model after the download completes.
    let songID = initialSong.id
    let prefs = UserPreferences.getOrCreate(in: modelContext)
    let isUserSelected = initialSong.artworkSource == .user
    let shouldDownloadArtwork = initialSong.albumReference == nil
      && (initialSong.artworkPath == nil || (prefs.preferOnlineArtwork && !isUserSelected))
    let downloadedArtworkPath: String?
    if shouldDownloadArtwork, let artworkURL = metadata.artworkURL {
      downloadedArtworkPath = await downloadArtwork(from: artworkURL)
    } else {
      downloadedArtworkPath = nil
    }

    guard let song = SongLibrary.shared.song(id: songID), song.modelContext != nil else { return }

    var needsSave = false

    // Update song fields only if they're empty or generic (Preserve user edits)
    if let title = metadata.title, !title.isEmpty,
      !song.userEditedFields.contains("title"),
      song.metadataSourceTitle != "embedded",
      (song.titleConfidence < 0.8 || song.title == song.fileName || song.title.contains("Untitled"))
    {
      song.title = title
      song.titleConfidence = (metadata.source == .appleMusic) ? 0.95 : MetadataConfidenceScorer.scoreMusicBrainz(value: title)
      song.metadataSourceTitle = metadata.source.rawValue
      needsSave = true
    }
    if let artist = metadata.artist, !artist.isEmpty,
      !song.userEditedFields.contains("artist"),
      song.metadataSourceArtist != "embedded",
      (song.artistConfidence < 0.8 || song.artist == "Unknown Artist" || song.artist.isEmpty)
    {
      song.artist = artist
      song.artists = ArtistParser.parseArtists(from: artist)
      song.artistConfidence = (metadata.source == .appleMusic) ? 0.95 : MetadataConfidenceScorer.scoreMusicBrainz(value: artist)
      song.metadataSourceArtist = metadata.source.rawValue
      needsSave = true
    }
    if let album = metadata.album, !album.isEmpty,
      !song.userEditedFields.contains("album"),
      song.metadataSourceAlbum != "embedded",
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
    if let appleMusicId = metadata.appleMusicId, song.appleMusicId != appleMusicId {
      song.appleMusicId = appleMusicId
      needsSave = true
    }
    if let musicBrainzId = metadata.musicBrainzId, song.musicBrainzId != musicBrainzId {
      song.musicBrainzId = musicBrainzId
      needsSave = true
    }
    if !metadata.backstageCredits.isEmpty {
      song.backstageCredits = BackstageCredit.merged([
        song.backstageCredits,
        metadata.backstageCredits,
      ])
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
            albumRef.appleMusicId = metadata.albumAppleMusicId
        }
        if let explicit = metadata.isExplicit {
            albumRef.isExplicit = explicit
        }
    }
    
    let artistNames = ArtistParser.parseArtists(from: metadata.albumArtist ?? metadata.artist ?? song.artist)
    if let primaryArtist = artistNames.first {
        let artist = SongLibrary.shared.getArtist(named: primaryArtist)
        if let artist = artist {
            if let bio = metadata.artistBio, !bio.isEmpty {
                artist.biography = bio
                artist.cachedBiography = bio
            }
            if artist.appleMusicId == nil {
                artist.appleMusicId = metadata.artistAppleMusicId
            }
        }
    }

    if let duration = metadata.duration, duration > 0, song.duration <= 0 {
      song.duration = duration
      needsSave = true
    }

    if let artworkPath = downloadedArtworkPath {
      song.artworkPath = artworkPath
      song.isRemoteArtwork = true
      song.artworkSource = .online
      needsSave = true
    }

    if needsSave {
      song.metadataCheckAttempted = true
      try? modelContext.save()
    }
  }

  @MainActor
  private func applyMetadata(_ metadata: FetchedMetadata, to album: Album) async {
    guard let modelContext = modelContext else { return }
    let albumID = album.id

    // Update album fields
    if let artist = metadata.artist, !artist.isEmpty,
      !album.userEditedFields.contains("artist"),
      album.artist == nil || album.artist?.isEmpty == true
    {
      album.artist = artist
    }
    if let year = metadata.year, !album.userEditedFields.contains("year"), album.year == nil {
      album.year = year
    }
    if let description = metadata.albumDescription, !description.isEmpty {
      album.albumDescription = description
    }
    if let albumAppleMusicId = metadata.albumAppleMusicId {
      album.appleMusicId = albumAppleMusicId
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
      let prefs = UserPreferences.getOrCreate(in: modelContext)
      let isUserSelected = album.artworkSource == .user
      if (album.artworkPath == nil || (prefs.preferOnlineArtwork && !isUserSelected)),
        let artworkPath = await downloadArtwork(from: artworkURL)
      {
        guard let album = SongLibrary.shared.albums.first(where: { $0.id == albumID }) else { return }
        album.artworkPath = artworkPath
        album.artworkSource = .online
        for song in album.songs where song.artworkSource != .user {
          if prefs.preferOnlineArtwork || song.embeddedArtworkPath == nil {
            song.artworkPath = artworkPath
            song.artworkSource = .online
            song.isRemoteArtwork = true
          }
        }
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
    for song: SongLookup,
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
    for album: AlbumLookup,
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

  private func scoreRecording(_ recording: MusicBrainzRecording, against song: SongLookup)
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
