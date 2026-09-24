//
//  RemoteLibraryService.swift
//  Ampwave
//
//  Jellyfin and Plex catalog sync, streaming, and managed offline downloads.
//

import CryptoKit
import Foundation
import Observation
import Security
import SwiftData

struct RemoteMusicSource: Codable, Identifiable, Hashable, Sendable {
  let id: String
  let provider: RemoteMusicProvider
  var name: String
  var baseURL: URL
  var username: String?
  var userID: String?
  var serverIdentifier: String?
  var lastSyncedAt: Date?

  init(
    id: String = UUID().uuidString,
    provider: RemoteMusicProvider,
    name: String,
    baseURL: URL,
    username: String? = nil,
    userID: String? = nil,
    serverIdentifier: String? = nil,
    lastSyncedAt: Date? = nil
  ) {
    self.id = id
    self.provider = provider
    self.name = name
    self.baseURL = baseURL
    self.username = username
    self.userID = userID
    self.serverIdentifier = serverIdentifier
    self.lastSyncedAt = lastSyncedAt
  }
}

enum RemoteLibraryError: LocalizedError {
  case invalidURL
  case missingCredentials
  case authenticationFailed
  case sourceUnavailable
  case invalidResponse
  case requestFailed(Int)
  case downloadUnavailable

  var errorDescription: String? {
    switch self {
    case .invalidURL:
      return "Enter a valid Jellyfin or Plex HTTP/HTTPS server URL."
    case .missingCredentials:
      return "The connection is missing its credentials."
    case .authenticationFailed:
      return "The server rejected the supplied credentials."
    case .sourceUnavailable:
      return "The music server is currently unavailable."
    case .invalidResponse:
      return "The music server returned a response Ampwave could not read."
    case .requestFailed(let status):
      return "The music server request failed with status \(status)."
    case .downloadUnavailable:
      return "This server did not provide a downloadable file for the song."
    }
  }
}

private enum RemotePlaybackState: String, Sendable {
  case playing
  case paused
  case stopped
}

private struct RemotePlaybackReport: Sendable {
  let source: RemoteMusicSource
  let token: String
  let itemID: String
  let sessionID: String
  let state: RemotePlaybackState
  let position: TimeInterval
  let duration: TimeInterval
  let isFirstReport: Bool
}

private struct RemotePlaybackSession {
  let songID: UUID
  let source: RemoteMusicSource
  let token: String
  let itemID: String
  let sessionID: String
  var duration: TimeInterval
  var lastPosition: TimeInterval
  var lastReportAt: Date

  func report(
    state: RemotePlaybackState,
    isFirstReport: Bool = false
  ) -> RemotePlaybackReport {
    RemotePlaybackReport(
      source: source,
      token: token,
      itemID: itemID,
      sessionID: sessionID,
      state: state,
      position: lastPosition,
      duration: duration,
      isFirstReport: isFirstReport
    )
  }
}

@MainActor
@Observable
final class RemoteLibraryService {
  static let shared = RemoteLibraryService()

  private(set) var sources: [RemoteMusicSource] = []
  private(set) var availability: [String: Bool] = [:]
  private(set) var syncingSourceIDs: Set<String> = []
  private(set) var downloadingSongIDs: Set<UUID> = []
  private(set) var lastError: String?

  @ObservationIgnored private var modelContext: ModelContext?
  @ObservationIgnored private let library = SongLibrary.shared
  @ObservationIgnored private var availabilityMonitorTask: Task<Void, Never>?
  @ObservationIgnored private var migratedDownloadsToFiles = false
  @ObservationIgnored private var activePlayback: RemotePlaybackSession?
  @ObservationIgnored private var pendingPlaybackReports: [RemotePlaybackReport] = []
  @ObservationIgnored private var playbackReportDrainTask: Task<Void, Never>?

  private static let sourcesKey = "com.ampwave.remoteLibraries.sources.v1"
  private static let deviceIDKey = "com.ampwave.remoteLibraries.deviceID"
  nonisolated private static let keychainService = "com.ome.Ampwave.remote-library"
  private static let syncInterval: TimeInterval = 15 * 60

  private let session: URLSession = {
    let configuration = URLSessionConfiguration.default
    configuration.timeoutIntervalForRequest = 12
    configuration.timeoutIntervalForResource = 60 * 60
    configuration.waitsForConnectivity = false
    configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
    return URLSession(configuration: configuration)
  }()

  private init() {
    if let data = UserDefaults.standard.data(forKey: Self.sourcesKey),
      let decoded = try? JSONDecoder().decode([RemoteMusicSource].self, from: data)
    {
      sources = decoded
    }
    for source in sources { availability[source.id] = false }
  }

  func setModelContext(_ context: ModelContext) {
    modelContext = context
    installSharedBridges()
    startAvailabilityMonitorIfNeeded()
    Task { await migrateDownloadsToFilesDirectoryIfNeeded() }
  }

  private func installSharedBridges() {
    SongLibrary.remoteSourceIsAvailable = { sourceID in
      RemoteLibraryService.shared.availability[sourceID] == true
    }
    SongLibrary.remoteStreamURLResolver = { song in
      RemoteLibraryService.shared.streamURL(for: song)
    }
    LyricsService.remoteLyricsFetcher = { song in
      await RemoteLibraryService.shared.fetchLyrics(for: song)
    }
  }

  private func startAvailabilityMonitorIfNeeded() {
    guard availabilityMonitorTask == nil else { return }
    availabilityMonitorTask = Task { [weak self] in
      while !Task.isCancelled {
        try? await Task.sleep(for: .seconds(60))
        guard !Task.isCancelled, let self else { return }
        await self.refreshAll(syncIfNeeded: false)
      }
    }
  }

  var isConfigured: Bool { !sources.isEmpty }

  func isSourceAvailable(_ sourceID: String) -> Bool {
    availability[sourceID] == true
  }

  func source(for song: LibrarySong) -> RemoteMusicSource? {
    guard let sourceID = song.remoteSourceID else { return nil }
    return sources.first { $0.id == sourceID }
  }

  // MARK: - Server playback reporting

  /// Starts native server-side playback tracking for provider-backed songs,
  /// including songs that have been downloaded for offline playback. The
  /// server APIs use these reports to update play history and resume state.
  func playbackStarted(_ song: LibrarySong, position: TimeInterval = 0) {
    guard UserPreferences.networkAllowed,
      let source = source(for: song),
      availability[source.id] == true,
      let token = Self.credential(sourceID: source.id),
      let itemID = song.remoteItemID
    else {
      activePlayback = nil
      return
    }

    let playback = RemotePlaybackSession(
      songID: song.id,
      source: source,
      token: token,
      itemID: itemID,
      sessionID: UUID().uuidString,
      duration: max(song.duration, 0),
      lastPosition: max(position, 0),
      lastReportAt: Date()
    )
    activePlayback = playback
    enqueuePlaybackReport(playback.report(state: .playing, isFirstReport: true))
  }

  /// Called from the player's existing low-frequency clock. Network work is
  /// limited to one report per ten seconds unless pause/resume forces a state
  /// transition, matching the cadence expected by Plex and Jellyfin clients.
  func playbackProgress(
    songID: UUID?,
    position: TimeInterval,
    duration: TimeInterval,
    isPaused: Bool,
    force: Bool = false
  ) {
    guard UserPreferences.networkAllowed,
      var playback = activePlayback,
      playback.songID == songID
    else { return }

    playback.lastPosition = max(position, 0)
    if duration.isFinite, duration > 0 { playback.duration = duration }
    let now = Date()
    let shouldSend = force || now.timeIntervalSince(playback.lastReportAt) >= 10
    if shouldSend { playback.lastReportAt = now }
    activePlayback = playback

    if shouldSend {
      enqueuePlaybackReport(playback.report(state: isPaused ? .paused : .playing))
    }
  }

  func playbackStopped(
    _ song: LibrarySong,
    position: TimeInterval,
    completed: Bool
  ) {
    guard var playback = activePlayback, playback.songID == song.id else { return }
    playback.lastPosition = completed && playback.duration > 0
      ? playback.duration
      : max(position, 0)
    activePlayback = nil
    enqueuePlaybackReport(playback.report(state: .stopped))
  }

  func discardCurrentPlayback(position: TimeInterval) {
    guard var playback = activePlayback else { return }
    playback.lastPosition = max(position, 0)
    activePlayback = nil
    enqueuePlaybackReport(playback.report(state: .stopped))
  }

  private func enqueuePlaybackReport(_ report: RemotePlaybackReport) {
    guard UserPreferences.networkAllowed else { return }
    pendingPlaybackReports.append(report)
    guard playbackReportDrainTask == nil else { return }
    playbackReportDrainTask = Task { [weak self] in
      guard let self else { return }
      while !Task.isCancelled, !self.pendingPlaybackReports.isEmpty {
        let next = self.pendingPlaybackReports.removeFirst()
        do {
          try await self.sendPlaybackReport(next)
        } catch {
          // Playback must never stop because an optional history update failed.
          DiagnosticLog.shared.log(
            "remote-playback",
            "\(next.source.provider.displayName) report failed: \(error.localizedDescription)"
          )
        }
      }
      self.playbackReportDrainTask = nil
    }
  }

  private func sendPlaybackReport(_ report: RemotePlaybackReport) async throws {
    let url: URL
    var request: URLRequest

    switch report.source.provider {
    case .jellyfin:
      let path: String
      switch report.state {
      case .playing where report.isFirstReport: path = "/Sessions/Playing"
      case .playing, .paused: path = "/Sessions/Playing/Progress"
      case .stopped: path = "/Sessions/Playing/Stopped"
      }
      url = makeURL(baseURL: report.source.baseURL, path: path)
      request = URLRequest(url: url)
      request.httpMethod = "POST"
      request.setValue("application/json", forHTTPHeaderField: "Content-Type")
      let ticks = Int64((max(report.position, 0) * 10_000_000).rounded())
      var payload: [String: Any] = [
        "ItemId": report.itemID,
        "PositionTicks": ticks,
        "PlaySessionId": report.sessionID,
      ]
      if report.state != .stopped {
        payload["CanSeek"] = true
        payload["IsPaused"] = report.state == .paused
        payload["PlayMethod"] = "DirectPlay"
      }
      request.httpBody = try JSONSerialization.data(withJSONObject: payload)

    case .plex:
      let query = [
        URLQueryItem(name: "key", value: "/library/metadata/\(report.itemID)"),
        URLQueryItem(name: "ratingKey", value: report.itemID),
        URLQueryItem(name: "state", value: report.state.rawValue),
        URLQueryItem(name: "time", value: String(Int((report.position * 1000).rounded()))),
        URLQueryItem(name: "duration", value: String(Int((report.duration * 1000).rounded()))),
      ]
      url = makeURL(baseURL: report.source.baseURL, path: "/:/timeline", adding: query)
      request = URLRequest(url: url)
      request.httpMethod = "POST"
      request.setValue(report.sessionID, forHTTPHeaderField: "X-Plex-Session-Identifier")
    }

    applyAuthorization(to: &request, source: report.source, token: report.token)
    let (_, response) = try await session.data(for: request)
    try validate(response)
  }

  // MARK: - Connections

  @discardableResult
  func connectJellyfin(
    serverURL: String,
    username: String,
    password: String,
    displayName: String? = nil
  ) async throws -> RemoteMusicSource {
    let baseURL = try normalizedServerURL(serverURL)
    let client = JellyfinClient(
      baseURL: baseURL,
      token: nil,
      userID: nil,
      deviceID: deviceID,
      session: session
    )
    let authentication = try await client.authenticate(username: username, password: password)
    let info = try? await JellyfinClient(
      baseURL: baseURL,
      token: authentication.accessToken,
      userID: authentication.userID,
      deviceID: deviceID,
      session: session
    ).serverInfo()

    var source = RemoteMusicSource(
      provider: .jellyfin,
      name: nonempty(displayName) ?? info?.name ?? "Jellyfin",
      baseURL: baseURL,
      username: username.trimmingCharacters(in: .whitespacesAndNewlines),
      userID: authentication.userID,
      serverIdentifier: info?.id
    )
    try Self.saveCredential(authentication.accessToken, sourceID: source.id)
    source = upsertSource(source)
    availability[source.id] = true
    try await sync(sourceID: source.id)
    source = sources.first(where: { $0.id == source.id }) ?? source
    return source
  }

  @discardableResult
  func connectPlex(
    serverURL: String,
    accessToken: String,
    displayName: String? = nil
  ) async throws -> RemoteMusicSource {
    let baseURL = try normalizedServerURL(serverURL)
    let token = accessToken.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !token.isEmpty else { throw RemoteLibraryError.missingCredentials }
    let client = PlexClient(baseURL: baseURL, token: token, deviceID: deviceID, session: session)
    let identity = try await client.identity()

    var source = RemoteMusicSource(
      provider: .plex,
      name: nonempty(displayName) ?? identity.name ?? "Plex",
      baseURL: baseURL,
      serverIdentifier: identity.machineIdentifier
    )
    try Self.saveCredential(token, sourceID: source.id)
    source = upsertSource(source)
    availability[source.id] = true
    try await sync(sourceID: source.id)
    source = sources.first(where: { $0.id == source.id }) ?? source
    return source
  }

  func disconnect(_ source: RemoteMusicSource) async throws {
    try await library.replaceRemoteCatalog(
      sourceID: source.id,
      provider: source.provider,
      tracks: []
    )
    sources.removeAll { $0.id == source.id }
    availability[source.id] = nil
    Self.deleteCredential(sourceID: source.id)
    saveSources()
  }

  // MARK: - Reachability and sync

  func refreshAll(syncIfNeeded: Bool = true) async {
    await migrateDownloadsToFilesDirectoryIfNeeded()
    guard !sources.isEmpty else { return }
    lastError = nil

    for source in sources {
      let reachable = await isReachable(source)
      availability[source.id] = reachable
    }
    await library.refreshRemoteVisibility()

    for source in sources where availability[source.id] == true {
      let isStale = source.lastSyncedAt.map {
        Date().timeIntervalSince($0) >= Self.syncInterval
      } ?? true
      if syncIfNeeded && isStale {
        do { try await sync(sourceID: source.id) }
        catch { lastError = error.localizedDescription }
      }
    }
    await resumeRequestedDownloads()
  }

  func sync(sourceID: String) async throws {
    guard !syncingSourceIDs.contains(sourceID),
      let source = sources.first(where: { $0.id == sourceID })
    else { return }
    guard let token = Self.credential(sourceID: source.id), !token.isEmpty else {
      throw RemoteLibraryError.missingCredentials
    }

    syncingSourceIDs.insert(sourceID)
    defer { syncingSourceIDs.remove(sourceID) }

    let catalog: [RemoteCatalogTrack]
    switch source.provider {
    case .jellyfin:
      guard let userID = source.userID else { throw RemoteLibraryError.missingCredentials }
      catalog = try await JellyfinClient(
        baseURL: source.baseURL,
        token: token,
        userID: userID,
        deviceID: deviceID,
        session: session
      ).tracks()
    case .plex:
      catalog = try await PlexClient(
        baseURL: source.baseURL,
        token: token,
        deviceID: deviceID,
        session: session
      ).tracks()
    }

    availability[sourceID] = true
    let artwork = await cacheArtwork(for: catalog, source: source, token: token)
    let descriptors = catalog.map { track in
      track.descriptor(artworkPath: track.artworkReference.flatMap { artwork[$0] })
    }
    try await library.replaceRemoteCatalog(
      sourceID: source.id,
      provider: source.provider,
      tracks: descriptors
    )

    if let index = sources.firstIndex(where: { $0.id == source.id }) {
      sources[index].lastSyncedAt = Date()
      saveSources()
    }
    await resumeRequestedDownloads(sourceID: sourceID)
  }

  func syncNow(sourceID: String) async {
    lastError = nil
    do {
      try await sync(sourceID: sourceID)
    } catch {
      lastError = error.localizedDescription
      availability[sourceID] = false
      await library.refreshRemoteVisibility()
    }
  }

  private func isReachable(_ source: RemoteMusicSource) async -> Bool {
    guard let token = Self.credential(sourceID: source.id), !token.isEmpty else { return false }
    do {
      switch source.provider {
      case .jellyfin:
        guard let userID = source.userID else { return false }
        try await JellyfinClient(
          baseURL: source.baseURL,
          token: token,
          userID: userID,
          deviceID: deviceID,
          session: session
        ).verifySession()
      case .plex:
        _ = try await PlexClient(
          baseURL: source.baseURL,
          token: token,
          deviceID: deviceID,
          session: session
        ).identity()
      }
      return true
    } catch {
      return false
    }
  }

  // MARK: - Streaming and lyrics

  func streamURL(for song: LibrarySong) -> URL? {
    guard song.isRemote, !song.remoteIsDownloaded,
      let source = source(for: song), availability[source.id] == true,
      let token = Self.credential(sourceID: source.id),
      let path = song.remoteStreamPath
    else { return nil }

    var query: [URLQueryItem] = []
    switch source.provider {
    case .jellyfin:
      query = [
        URLQueryItem(name: "ApiKey", value: token),
        URLQueryItem(name: "UserId", value: source.userID),
        URLQueryItem(name: "DeviceId", value: deviceID),
      ]
    case .plex:
      query = [
        URLQueryItem(name: "X-Plex-Token", value: token),
        URLQueryItem(name: "download", value: "0"),
      ]
    }
    return makeURL(baseURL: source.baseURL, path: path, adding: query)
  }

  private func fetchLyrics(for song: LibrarySong) async -> String? {
    guard song.remoteProvider == .jellyfin, let source = source(for: song),
      availability[source.id] == true,
      let token = Self.credential(sourceID: source.id),
      let userID = source.userID,
      let itemID = song.remoteItemID
    else { return nil }

    return try? await JellyfinClient(
      baseURL: source.baseURL,
      token: token,
      userID: userID,
      deviceID: deviceID,
      session: session
    ).lyrics(itemID: itemID)
  }

  // MARK: - Downloads

  func requestDownload(for song: LibrarySong) {
    guard song.isRemote, !song.remoteIsDownloaded else { return }
    if !song.remoteDownloadRequested {
      library.setRemoteDownloadRequested(true, for: song)
    }
    Task { try? await download(song) }
  }

  func requestDownload(for songs: [LibrarySong]) {
    let remoteSongs = songs.filter { $0.isRemote && !$0.remoteIsDownloaded }
    library.setRemoteDownloadRequested(true, for: remoteSongs)
    Task {
      for song in remoteSongs { try? await download(song) }
    }
  }

  func download(_ song: LibrarySong) async throws {
    guard song.isRemote, !song.remoteIsDownloaded else { return }
    guard !downloadingSongIDs.contains(song.id) else { return }
    guard let source = source(for: song), availability[source.id] == true else {
      throw RemoteLibraryError.sourceUnavailable
    }
    guard let token = Self.credential(sourceID: source.id),
      let path = song.remoteDownloadPath
    else { throw RemoteLibraryError.downloadUnavailable }

    library.setRemoteDownloadRequested(true, for: song)
    downloadingSongIDs.insert(song.id)
    defer { downloadingSongIDs.remove(song.id) }

    var request = URLRequest(url: makeURL(baseURL: source.baseURL, path: path))
    applyAuthorization(to: &request, source: source, token: token)
    if source.provider == .plex {
      request.url = makeURL(
        baseURL: source.baseURL,
        path: path,
        adding: [URLQueryItem(name: "download", value: "1")]
      )
    }

    let (temporaryURL, response) = try await session.download(for: request)
    try validate(response)

    let destination = try downloadDestination(for: song, response: response)
    try FileManager.default.createDirectory(
      at: destination.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    if FileManager.default.fileExists(atPath: destination.path) {
      try FileManager.default.removeItem(at: destination)
    }
    try FileManager.default.moveItem(at: temporaryURL, to: destination)
    let size = (try? destination.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? song.size
    library.markRemoteSongDownloaded(song, at: destination, size: size)
    await library.refreshRemoteVisibility()
    SonicRecommendationService.shared.enqueueAnalysis(for: song)
  }

  func removeDownload(for song: LibrarySong) throws {
    try library.removeRemoteDownload(for: song)
  }

  private func resumeRequestedDownloads(sourceID: String? = nil) async {
    guard let modelContext else { return }
    let allSongs = (try? modelContext.fetch(FetchDescriptor<LibrarySong>())) ?? []
    var repairedMissingDownloads = false
    for song in allSongs where song.isRemote && song.remoteIsDownloaded {
      let localExists = song.filePath
        .flatMap(PathManager.absoluteURL)
        .map { FileManager.default.fileExists(atPath: $0.path) } == true
      guard !localExists else { continue }
      song.filePath = nil
      song.remoteIsDownloaded = false
      song.remoteDownloadRequested = !(song.playlists?.isEmpty ?? true)
      repairedMissingDownloads = true
    }
    if repairedMissingDownloads {
      try? modelContext.save()
      await library.refreshRemoteVisibility()
    }
    let pending = allSongs.filter {
      $0.isRemote && $0.remoteDownloadRequested && !$0.remoteIsDownloaded
        && (sourceID == nil || $0.remoteSourceID == sourceID)
    }
    for song in pending where song.remoteSourceID.map(isSourceAvailable) == true {
      try? await download(song)
    }
  }

  private func downloadDestination(for song: LibrarySong, response: URLResponse) throws -> URL {
    let artist = safePathComponent(song.albumArtist ?? song.artist, fallback: "Unknown Artist")
    let album = safePathComponent(song.album ?? "Unknown Album", fallback: "Unknown Album")
    let directory = PathManager.documentsDirectory
      .appendingPathComponent("Songs", isDirectory: true)
      .appendingPathComponent(artist, isDirectory: true)
      .appendingPathComponent(album, isDirectory: true)

    let responseExtension = response.suggestedFilename.flatMap {
      URL(fileURLWithPath: $0).pathExtension.nilIfEmpty
    }
    let ext = responseExtension
      ?? song.remoteContainer?.split(separator: ",").first.map(String.init)
      ?? "mp3"
    let trackPrefix = song.trackNumber.map { String(format: "%02d - ", $0) } ?? ""
    let title = safePathComponent(song.title, fallback: "Untitled")
    let filename = "\(trackPrefix)\(title).\(ext.lowercased())"
    let preferred = directory.appendingPathComponent(filename)
    if !FileManager.default.fileExists(atPath: preferred.path) { return preferred }
    if let existing = song.filePath.flatMap(PathManager.absoluteURL),
      existing.standardizedFileURL == preferred.standardizedFileURL
    {
      return preferred
    }
    let suffix = String((song.remoteItemID ?? song.id.uuidString).prefix(8))
    return directory.appendingPathComponent(
      "\(trackPrefix)\(title) [\(suffix)].\(ext.lowercased())"
    )
  }

  /// Older builds placed server downloads in the App Group container, which
  /// is intentionally hidden from Files. Move only completed remote downloads
  /// into Documents/Songs so Files shows Ampwave/Artist/Album/Track.
  private func migrateDownloadsToFilesDirectoryIfNeeded() async {
    guard !migratedDownloadsToFiles, let modelContext else { return }
    migratedDownloadsToFiles = true

    let downloaded = ((try? modelContext.fetch(FetchDescriptor<LibrarySong>())) ?? [])
      .filter { $0.isRemote && $0.remoteIsDownloaded }
    guard !downloaded.isEmpty else { return }

    let visibleRoot = PathManager.documentsDirectory
      .appendingPathComponent("Songs", isDirectory: true)
    var changed = false

    for song in downloaded {
      guard let storedPath = song.filePath,
        let source = PathManager.absoluteURL(for: storedPath),
        FileManager.default.fileExists(atPath: source.path)
      else { continue }

      if PathManager.isInside(source, directory: visibleRoot) {
        let relative = PathManager.relativePath(from: source.path)
        if song.filePath != relative {
          song.filePath = relative
          changed = true
        }
        continue
      }

      let artist = safePathComponent(song.albumArtist ?? song.artist, fallback: "Unknown Artist")
      let album = safePathComponent(song.album ?? "Unknown Album", fallback: "Unknown Album")
      let directory = visibleRoot
        .appendingPathComponent(artist, isDirectory: true)
        .appendingPathComponent(album, isDirectory: true)
      do {
        try FileManager.default.createDirectory(
          at: directory, withIntermediateDirectories: true
        )
        var destination = directory.appendingPathComponent(source.lastPathComponent)
        if FileManager.default.fileExists(atPath: destination.path) {
          let stem = destination.deletingPathExtension().lastPathComponent
          let ext = destination.pathExtension
          let suffix = String((song.remoteItemID ?? song.id.uuidString).prefix(8))
          destination = directory.appendingPathComponent("\(stem) [\(suffix)]")
            .appendingPathExtension(ext)
        }
        try FileManager.default.moveItem(at: source, to: destination)
        song.filePath = PathManager.relativePath(from: destination.path)
        changed = true
      } catch {
        DiagnosticLog.shared.log(
          "remote-library",
          "Could not move downloaded track into Files: \(error.localizedDescription)"
        )
      }
    }

    guard changed else { return }
    try? modelContext.save()
    await library.refreshRemoteVisibility()
  }

  // MARK: - Artwork

  private func cacheArtwork(
    for catalog: [RemoteCatalogTrack],
    source: RemoteMusicSource,
    token: String
  ) async -> [String: String] {
    let references = Array(Set(catalog.compactMap(\.artworkReference))).sorted()
    guard !references.isEmpty else { return [:] }

    let directory = library.artworkCacheDirectory
      .appendingPathComponent("Remote", isDirectory: true)
      .appendingPathComponent(source.id, isDirectory: true)
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

    var result: [String: String] = [:]
    for reference in references {
      let digest = SHA256.hash(data: Data(reference.utf8)).map { String(format: "%02x", $0) }.joined()
      let destination = directory.appendingPathComponent("\(digest).jpg")
      if FileManager.default.fileExists(atPath: destination.path) {
        result[reference] = PathManager.relativePath(from: destination.path)
        continue
      }

      var request = URLRequest(url: makeURL(baseURL: source.baseURL, path: reference))
      applyAuthorization(to: &request, source: source, token: token)
      do {
        let (data, response) = try await session.data(for: request)
        try validate(response)
        guard !data.isEmpty else { continue }
        try data.write(to: destination, options: .atomic)
        result[reference] = PathManager.relativePath(from: destination.path)
      } catch {
        continue
      }
    }
    return result
  }

  // MARK: - Helpers

  private var deviceID: String {
    if let existing = UserDefaults.standard.string(forKey: Self.deviceIDKey), !existing.isEmpty {
      return existing
    }
    let created = UUID().uuidString
    UserDefaults.standard.set(created, forKey: Self.deviceIDKey)
    return created
  }

  @discardableResult
  private func upsertSource(_ source: RemoteMusicSource) -> RemoteMusicSource {
    let stored: RemoteMusicSource
    if let index = sources.firstIndex(where: {
      $0.provider == source.provider && $0.baseURL == source.baseURL
    }) {
      let oldID = sources[index].id
      var replacement = source
      replacement = RemoteMusicSource(
        id: oldID,
        provider: source.provider,
        name: source.name,
        baseURL: source.baseURL,
        username: source.username,
        userID: source.userID,
        serverIdentifier: source.serverIdentifier,
        lastSyncedAt: sources[index].lastSyncedAt
      )
      if oldID != source.id, let credential = Self.credential(sourceID: source.id) {
        try? Self.saveCredential(credential, sourceID: oldID)
        Self.deleteCredential(sourceID: source.id)
      }
      sources[index] = replacement
      stored = replacement
    } else {
      sources.append(source)
      stored = source
    }
    saveSources()
    return stored
  }

  private func saveSources() {
    guard let data = try? JSONEncoder().encode(sources) else { return }
    UserDefaults.standard.set(data, forKey: Self.sourcesKey)
  }

  private func normalizedServerURL(_ rawValue: String) throws -> URL {
    let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
    guard var components = URLComponents(string: trimmed),
      let scheme = components.scheme?.lowercased(), ["http", "https"].contains(scheme),
      components.host != nil
    else { throw RemoteLibraryError.invalidURL }
    components.query = nil
    components.fragment = nil
    if components.path.count > 1, components.path.hasSuffix("/") {
      components.path.removeLast()
    }
    guard let url = components.url else { throw RemoteLibraryError.invalidURL }
    return url
  }

  private func nonempty(_ value: String?) -> String? {
    let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    return trimmed.isEmpty ? nil : trimmed
  }

  private func safePathComponent(_ value: String, fallback: String) -> String {
    let cleaned = value
      .replacingOccurrences(of: "[/\\\\:*?\"<>|]", with: "_", options: .regularExpression)
      .trimmingCharacters(in: .whitespacesAndNewlines)
    let usable = cleaned.isEmpty || cleaned == "." || cleaned == ".." ? fallback : cleaned
    return String(usable.prefix(120))
  }

  private func makeURL(
    baseURL: URL,
    path: String,
    adding queryItems: [URLQueryItem] = []
  ) -> URL {
    let pathOnly = path.split(separator: "?", maxSplits: 1).first.map(String.init) ?? path
    let relativePath = pathOnly.hasPrefix("/") ? String(pathOnly.dropFirst()) : pathOnly
    let url = baseURL.appendingPathComponent(relativePath)
    var components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
    if let query = path.split(separator: "?", maxSplits: 1).dropFirst().first {
      components.percentEncodedQuery = String(query)
    }
    var existing = components.queryItems ?? []
    existing.append(contentsOf: queryItems.filter { item in
      !existing.contains(where: { $0.name.caseInsensitiveCompare(item.name) == .orderedSame })
    })
    components.queryItems = existing.isEmpty ? nil : existing
    return components.url!
  }

  private func applyAuthorization(
    to request: inout URLRequest,
    source: RemoteMusicSource,
    token: String
  ) {
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    switch source.provider {
    case .jellyfin:
      request.setValue(
        JellyfinClient.authorizationHeader(deviceID: deviceID, token: token),
        forHTTPHeaderField: "Authorization"
      )
    case .plex:
      request.setValue(token, forHTTPHeaderField: "X-Plex-Token")
      request.setValue(deviceID, forHTTPHeaderField: "X-Plex-Client-Identifier")
      request.setValue("Ampwave", forHTTPHeaderField: "X-Plex-Product")
      request.setValue(Self.appVersion, forHTTPHeaderField: "X-Plex-Version")
    }
  }

  private func validate(_ response: URLResponse) throws {
    guard let response = response as? HTTPURLResponse else {
      throw RemoteLibraryError.invalidResponse
    }
    guard (200..<300).contains(response.statusCode) else {
      if response.statusCode == 401 || response.statusCode == 403 {
        throw RemoteLibraryError.authenticationFailed
      }
      throw RemoteLibraryError.requestFailed(response.statusCode)
    }
  }

  nonisolated fileprivate static var appVersion: String {
    Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1"
  }

  // MARK: Keychain

  nonisolated private static func credential(sourceID: String) -> String? {
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: keychainService,
      kSecAttrAccount as String: sourceID,
      kSecReturnData as String: true,
      kSecMatchLimit as String: kSecMatchLimitOne,
    ]
    var result: CFTypeRef?
    guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
      let data = result as? Data
    else { return nil }
    return String(data: data, encoding: .utf8)
  }

  nonisolated private static func saveCredential(_ credential: String, sourceID: String) throws {
    deleteCredential(sourceID: sourceID)
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: keychainService,
      kSecAttrAccount as String: sourceID,
      kSecValueData as String: Data(credential.utf8),
      kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
    ]
    let status = SecItemAdd(query as CFDictionary, nil)
    guard status == errSecSuccess else {
      throw NSError(
        domain: NSOSStatusErrorDomain,
        code: Int(status),
        userInfo: [NSLocalizedDescriptionKey: "Could not store the server credential securely."]
      )
    }
  }

  nonisolated private static func deleteCredential(sourceID: String) {
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: keychainService,
      kSecAttrAccount as String: sourceID,
    ]
    SecItemDelete(query as CFDictionary)
  }
}

private struct RemoteCatalogTrack: Sendable {
  let itemID: String
  let title: String
  let artist: String
  let artists: [String]
  let album: String?
  let albumArtist: String?
  let genre: String?
  let description: String?
  let duration: TimeInterval
  let trackNumber: Int?
  let discNumber: Int?
  let year: Int?
  let size: Int
  let container: String?
  let bitRate: Int?
  let sampleRate: Double?
  let bitDepth: Int?
  let channels: Int?
  let streamPath: String
  let downloadPath: String
  let artworkReference: String?
  let fileName: String

  func descriptor(artworkPath: String?) -> RemoteTrackDescriptor {
    RemoteTrackDescriptor(
      itemID: itemID,
      title: title,
      artist: artist,
      artists: artists,
      album: album,
      albumArtist: albumArtist,
      genre: genre,
      description: description,
      duration: duration,
      trackNumber: trackNumber,
      discNumber: discNumber,
      year: year,
      size: size,
      container: container,
      bitRate: bitRate,
      sampleRate: sampleRate,
      bitDepth: bitDepth,
      channels: channels,
      streamPath: streamPath,
      downloadPath: downloadPath,
      artworkPath: artworkPath,
      fileName: fileName
    )
  }
}

// MARK: - Jellyfin

private struct JellyfinClient: Sendable {
  struct Authentication: Sendable {
    let accessToken: String
    let userID: String
  }

  struct ServerInfo: Sendable {
    let id: String?
    let name: String?
  }

  let baseURL: URL
  let token: String?
  let userID: String?
  let deviceID: String
  let session: URLSession

  static func authorizationHeader(deviceID: String, token: String? = nil) -> String {
    var fields = [
      "Client=\"Ampwave\"",
      "Device=\"Apple Device\"",
      "DeviceId=\"\(deviceID)\"",
      "Version=\"\(RemoteLibraryService.appVersion)\"",
    ]
    if let token { fields.append("Token=\"\(token)\"") }
    return "MediaBrowser " + fields.joined(separator: ", ")
  }

  func authenticate(username: String, password: String) async throws -> Authentication {
    struct Body: Encodable { let Username: String; let Pw: String }
    struct Response: Decodable {
      let AccessToken: String
      let User: User
      struct User: Decodable { let Id: String }
    }

    var request = request(path: "/Users/AuthenticateByName", authenticated: false)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.httpBody = try JSONEncoder().encode(Body(Username: username, Pw: password))
    let response: Response = try await decode(request)
    return Authentication(accessToken: response.AccessToken, userID: response.User.Id)
  }

  func serverInfo() async throws -> ServerInfo {
    struct Response: Decodable { let Id: String?; let ServerName: String? }
    let response: Response = try await decode(request(path: "/System/Info/Public"))
    return ServerInfo(id: response.Id, name: response.ServerName)
  }

  func verifySession() async throws {
    guard let userID else { throw RemoteLibraryError.missingCredentials }
    let request = request(path: "/Users/\(userID)")
    let (_, response) = try await session.data(for: request)
    try validate(response)
  }

  func tracks() async throws -> [RemoteCatalogTrack] {
    struct Response: Decodable {
      let Items: [Item]
      let TotalRecordCount: Int?
    }
    struct Item: Decodable {
      let Id: String
      let Name: String
      let Album: String?
      let AlbumArtist: String?
      let Artists: [String]?
      let ArtistItems: [ArtistItem]?
      let RunTimeTicks: Int64?
      let IndexNumber: Int?
      let ParentIndexNumber: Int?
      let ProductionYear: Int?
      let Genres: [String]?
      let Overview: String?
      let Path: String?
      let AlbumId: String?
      let ImageTags: [String: String]?
      let AlbumPrimaryImageTag: String?
      let MediaSources: [MediaSource]?
    }
    struct ArtistItem: Decodable { let Name: String? }
    struct MediaSource: Decodable {
      let Container: String?
      let Size: Int64?
      let Bitrate: Int?
      let MediaStreams: [MediaStream]?
    }
    struct MediaStream: Decodable {
      let type: String?
      let SampleRate: Int?
      let BitDepth: Int?
      let Channels: Int?
      let BitRate: Int?

      private enum CodingKeys: String, CodingKey {
        case type = "Type"
        case SampleRate, BitDepth, Channels, BitRate
      }
    }

    guard let userID else { throw RemoteLibraryError.missingCredentials }
    var result: [RemoteCatalogTrack] = []
    var startIndex = 0
    let pageSize = 500

    while true {
      let fields = [
        "Overview", "Genres", "MediaSources", "MediaStreams", "Path", "AlbumId",
        "AlbumPrimaryImageTag", "ProductionYear",
      ].joined(separator: ",")
      let query = [
        URLQueryItem(name: "Recursive", value: "true"),
        URLQueryItem(name: "IncludeItemTypes", value: "Audio"),
        URLQueryItem(name: "Fields", value: fields),
        URLQueryItem(name: "EnableImages", value: "true"),
        URLQueryItem(name: "ImageTypeLimit", value: "1"),
        URLQueryItem(name: "StartIndex", value: String(startIndex)),
        URLQueryItem(name: "Limit", value: String(pageSize)),
        URLQueryItem(name: "SortBy", value: "SortName"),
      ]
      let page: Response = try await decode(
        request(path: "/Users/\(userID)/Items", query: query)
      )

      result.append(contentsOf: page.Items.map { item in
        let source = item.MediaSources?.first
        let audio = source?.MediaStreams?.first {
          $0.type?.caseInsensitiveCompare("Audio") == .orderedSame
        }
        let container = source?.Container?.split(separator: ",").first.map(String.init)
        let fileName = item.Path.map { URL(fileURLWithPath: $0).lastPathComponent }
          .flatMap { $0.isEmpty ? nil : $0 }
          ?? "\(item.Name).\(container ?? "mp3")"
        let artworkItemID = item.AlbumId ?? item.Id
        let hasArtwork = item.AlbumPrimaryImageTag != nil || item.ImageTags?["Primary"] != nil
        let artwork = hasArtwork
          ? "/Items/\(artworkItemID)/Images/Primary?maxWidth=1200&quality=90"
          : nil
        let rawArtists = (item.Artists ?? []).filter {
          !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        let linkedArtists = item.ArtistItems?.compactMap(\.Name).filter {
          !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        } ?? []
        let fallbackArtist = item.AlbumArtist ?? "Unknown Artist"
        let artists = ArtistParser.normalizedArtists(
          linkedArtists.isEmpty ? rawArtists : linkedArtists, fallback: fallbackArtist
        )
        let displayArtist = rawArtists.isEmpty
          ? (linkedArtists.isEmpty ? fallbackArtist : linkedArtists.joined(separator: "; "))
          : rawArtists.joined(separator: "; ")
        return RemoteCatalogTrack(
          itemID: item.Id,
          title: item.Name,
          artist: displayArtist,
          artists: artists,
          album: item.Album,
          albumArtist: item.AlbumArtist,
          genre: item.Genres?.joined(separator: ", "),
          description: item.Overview,
          duration: Double(item.RunTimeTicks ?? 0) / 10_000_000,
          trackNumber: item.IndexNumber,
          discNumber: item.ParentIndexNumber,
          year: item.ProductionYear,
          size: Int(clamping: source?.Size ?? 0),
          container: container,
          bitRate: (audio?.BitRate ?? source?.Bitrate).map { $0 / 1000 },
          sampleRate: audio?.SampleRate.map(Double.init),
          bitDepth: audio?.BitDepth,
          channels: audio?.Channels,
          streamPath: "/Audio/\(item.Id)/stream?static=true",
          downloadPath: "/Items/\(item.Id)/Download",
          artworkReference: artwork,
          fileName: fileName
        )
      })

      startIndex += page.Items.count
      let total = page.TotalRecordCount ?? startIndex
      if page.Items.isEmpty || startIndex >= total { break }
    }
    return result
  }

  func lyrics(itemID: String) async throws -> String? {
    struct Response: Decodable {
      let Lyrics: [Line]?
      let Tracks: [Track]?
      struct Track: Decodable { let Lyrics: [Line]? }
      struct Line: Decodable {
        let Text: String?
        let Start: Int64?
      }
    }

    do {
      let response: Response = try await decode(request(path: "/Audio/\(itemID)/Lyrics"))
      let lines = response.Lyrics ?? response.Tracks?.first?.Lyrics ?? []
      guard !lines.isEmpty else { return nil }
      return lines.compactMap { line in
        guard let text = line.Text, !text.isEmpty else { return nil }
        guard let ticks = line.Start else { return text }
        let seconds = Double(ticks) / 10_000_000
        let minutes = Int(seconds / 60)
        let remainder = seconds - Double(minutes * 60)
        return String(format: "[%02d:%05.2f] %@", minutes, remainder, text)
      }.joined(separator: "\n")
    } catch RemoteLibraryError.requestFailed(404) {
      return nil
    }
  }

  private func request(
    path: String,
    query: [URLQueryItem] = [],
    authenticated: Bool = true
  ) -> URLRequest {
    var components = URLComponents(
      url: baseURL.appendingPathComponent(path.hasPrefix("/") ? String(path.dropFirst()) : path),
      resolvingAgainstBaseURL: false
    )!
    components.queryItems = query.isEmpty ? nil : query
    var request = URLRequest(url: components.url!)
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    request.setValue(
      Self.authorizationHeader(deviceID: deviceID, token: authenticated ? token : nil),
      forHTTPHeaderField: "Authorization"
    )
    return request
  }

  private func decode<T: Decodable>(_ request: URLRequest) async throws -> T {
    let (data, response) = try await session.data(for: request)
    try validate(response)
    do { return try JSONDecoder().decode(T.self, from: data) }
    catch { throw RemoteLibraryError.invalidResponse }
  }

  private func validate(_ response: URLResponse) throws {
    guard let response = response as? HTTPURLResponse else {
      throw RemoteLibraryError.invalidResponse
    }
    guard (200..<300).contains(response.statusCode) else {
      if response.statusCode == 401 || response.statusCode == 403 {
        throw RemoteLibraryError.authenticationFailed
      }
      throw RemoteLibraryError.requestFailed(response.statusCode)
    }
  }
}

// MARK: - Plex

private struct PlexClient: Sendable {
  struct Identity: Sendable {
    let machineIdentifier: String?
    let name: String?
  }

  let baseURL: URL
  let token: String
  let deviceID: String
  let session: URLSession

  func identity() async throws -> Identity {
    struct Response: Decodable {
      let MediaContainer: Container
      struct Container: Decodable {
        let machineIdentifier: String?
        let friendlyName: String?
      }
    }
    let response: Response = try await decode(request(path: "/identity"))
    return Identity(
      machineIdentifier: response.MediaContainer.machineIdentifier,
      name: response.MediaContainer.friendlyName
    )
  }

  func tracks() async throws -> [RemoteCatalogTrack] {
    struct SectionsResponse: Decodable {
      let MediaContainer: Container
      struct Container: Decodable { let Directory: [Section]? }
      struct Section: Decodable { let key: String; let type: String; let title: String? }
    }
    struct TracksResponse: Decodable {
      let MediaContainer: Container
      struct Container: Decodable {
        let Metadata: [Track]?
        let totalSize: Int?
        let size: Int?
      }
      struct Track: Decodable {
        let ratingKey: String
        let title: String
        let parentTitle: String?
        let grandparentTitle: String?
        let summary: String?
        let duration: Int?
        let index: Int?
        let parentIndex: Int?
        let year: Int?
        let thumb: String?
        let parentThumb: String?
        let grandparentThumb: String?
        let Genre: [Tag]?
        let Media: [Media]?
      }
      struct Tag: Decodable { let tag: String }
      struct Media: Decodable {
        let container: String?
        let bitrate: Int?
        let audioChannels: Int?
        let Part: [Part]?
      }
      struct Part: Decodable {
        let key: String
        let file: String?
        let size: Int?
      }
    }

    let sections: SectionsResponse = try await decode(request(path: "/library/sections"))
    let musicSections = (sections.MediaContainer.Directory ?? []).filter { $0.type == "artist" }
    var result: [RemoteCatalogTrack] = []

    for section in musicSections {
      var start = 0
      let pageSize = 500
      while true {
        let query = [
          URLQueryItem(name: "type", value: "10"),
          URLQueryItem(name: "X-Plex-Container-Start", value: String(start)),
          URLQueryItem(name: "X-Plex-Container-Size", value: String(pageSize)),
        ]
        let response: TracksResponse = try await decode(
          request(path: "/library/sections/\(section.key)/all", query: query)
        )
        let tracks = response.MediaContainer.Metadata ?? []
        result.append(contentsOf: tracks.compactMap { track in
          guard let media = track.Media?.first, let part = media.Part?.first else { return nil }
          // originalTitle is a title field, not a performer credit. Plex's
          // artist parent is the only artist name available in this response.
          let artist = track.grandparentTitle ?? "Unknown Artist"
          let fileName = part.file.map { URL(fileURLWithPath: $0).lastPathComponent }
            .flatMap { $0.isEmpty ? nil : $0 }
            ?? "\(track.title).\(media.container ?? "mp3")"
          return RemoteCatalogTrack(
            itemID: track.ratingKey,
            title: track.title,
            artist: artist,
            artists: ArtistParser.parseArtists(from: artist),
            album: track.parentTitle,
            albumArtist: track.grandparentTitle,
            genre: track.Genre?.map(\.tag).joined(separator: ", "),
            description: track.summary,
            duration: Double(track.duration ?? 0) / 1000,
            trackNumber: track.index,
            discNumber: track.parentIndex,
            year: track.year,
            size: part.size ?? 0,
            container: media.container,
            bitRate: media.bitrate,
            sampleRate: nil,
            bitDepth: nil,
            channels: media.audioChannels,
            streamPath: part.key,
            downloadPath: part.key,
            artworkReference: track.thumb ?? track.parentThumb ?? track.grandparentThumb,
            fileName: fileName
          )
        })

        start += tracks.count
        let total = response.MediaContainer.totalSize ?? start
        if tracks.isEmpty || start >= total { break }
      }
    }
    return result
  }

  private func request(path: String, query: [URLQueryItem] = []) -> URLRequest {
    var components = URLComponents(
      url: baseURL.appendingPathComponent(path.hasPrefix("/") ? String(path.dropFirst()) : path),
      resolvingAgainstBaseURL: false
    )!
    components.queryItems = query.isEmpty ? nil : query
    var request = URLRequest(url: components.url!)
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    request.setValue(token, forHTTPHeaderField: "X-Plex-Token")
    request.setValue(deviceID, forHTTPHeaderField: "X-Plex-Client-Identifier")
    request.setValue("Ampwave", forHTTPHeaderField: "X-Plex-Product")
    request.setValue(RemoteLibraryService.appVersion, forHTTPHeaderField: "X-Plex-Version")
    return request
  }

  private func decode<T: Decodable>(_ request: URLRequest) async throws -> T {
    let (data, response) = try await session.data(for: request)
    guard let response = response as? HTTPURLResponse else {
      throw RemoteLibraryError.invalidResponse
    }
    guard (200..<300).contains(response.statusCode) else {
      if response.statusCode == 401 || response.statusCode == 403 {
        throw RemoteLibraryError.authenticationFailed
      }
      throw RemoteLibraryError.requestFailed(response.statusCode)
    }
    do { return try JSONDecoder().decode(T.self, from: data) }
    catch { throw RemoteLibraryError.invalidResponse }
  }
}

private extension String {
  var nilIfEmpty: String? { isEmpty ? nil : self }
}
