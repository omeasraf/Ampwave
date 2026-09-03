import AVFoundation
import CryptoKit
import Foundation
import Observation

#if os(iOS)
  import MediaPlayer
  import UIKit
#endif

struct AnimatedArtworkResult: Codable, Equatable, Sendable {
  let squareURL: URL
  let tallURL: URL?
  let artist: String
  let album: String

  private enum CodingKeys: String, CodingKey {
    case squareURL = "url"
    case tallURL = "url_tall"
    case artist
    case album
  }
}

private struct AnimatedArtworkCacheEntry: Codable {
  let result: AnimatedArtworkResult?
  let fetchedAt: Date
}

/// Opt-in lookup for Apple Music's animated artwork. Nothing is searched at
/// import time: the active album is resolved only after its song starts.
@MainActor
@Observable
final class AnimatedArtworkService {
  static let shared = AnimatedArtworkService()

  private(set) var currentArtwork: AnimatedArtworkResult?
  private(set) var currentSongID: UUID?
  private(set) var isLoading = false
  private(set) var cacheRevision = 0

  private let endpoint = URL(string: "https://artwork.m8tec.top/api/v1/artwork")!
  private let positiveCacheLifetime: TimeInterval = 30 * 24 * 60 * 60
  private let negativeCacheLifetime: TimeInterval = 24 * 60 * 60
  private var cache: [String: AnimatedArtworkCacheEntry] = [:]
  private var lookupTask: Task<Void, Never>?

  @ObservationIgnored
  private let session: URLSession

  private init() {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.timeoutIntervalForRequest = 15
    configuration.timeoutIntervalForResource = 20
    configuration.requestCachePolicy = .returnCacheDataElseLoad
    configuration.urlCache = URLCache(
      memoryCapacity: 2 * 1_024 * 1_024,
      diskCapacity: 8 * 1_024 * 1_024
    )
    session = URLSession(configuration: configuration)
    loadCache()
  }

  func load(for song: LibrarySong) {
    guard UserPreferences.networkAllowed else {
      clearCurrent()
      return
    }
    guard let album = song.album?.trimmingCharacters(in: .whitespacesAndNewlines),
      !album.isEmpty
    else {
      clearCurrent()
      return
    }

    let artist = (song.albumArtist?.isEmpty == false ? song.albumArtist : song.artist)
      ?? song.artist
    let key = cacheKey(artist: artist, album: album)

    lookupTask?.cancel()
    currentSongID = song.id
    currentArtwork = nil

    if let cached = validCacheEntry(for: key) {
      currentArtwork = cached.result
      isLoading = false
      PlaybackController.shared.animatedArtworkDidChange(for: song.id)
      if let result = cached.result {
        #if os(iOS)
            cacheForPlayback(result, songID: song.id)
        #endif
      }
      return
    }

    isLoading = true
    let songID = song.id
    let appleMusicURL = song.appleMusicURL.flatMap(URL.init(string:))
    lookupTask = Task { [weak self] in
      guard let self else { return }
      var result: AnimatedArtworkResult?

      // Metadata enrichment usually gives us the exact catalog URL. Prefer
      // that over fuzzy text matching; the service accepts album and song URLs.
      if let appleMusicURL, Self.isAppleMusicURL(appleMusicURL) {
        result = await self.fetch(path: "url", query: ["url": appleMusicURL.absoluteString])
      }
      if result == nil, !Task.isCancelled {
        result = await self.fetch(
          path: "search",
          query: ["artist": artist, "album": album]
        )
      }

      guard !Task.isCancelled, self.currentSongID == songID else { return }
      self.cache[key] = AnimatedArtworkCacheEntry(result: result, fetchedAt: Date())
      self.saveCache()
      self.currentArtwork = result
      self.isLoading = false
      DiagnosticLog.shared.log(
        "animated-artwork",
        result == nil
          ? "No animation found artist=\(artist) album=\(album)"
          : "Animation loaded artist=\(artist) album=\(album)"
      )
      PlaybackController.shared.animatedArtworkDidChange(for: songID)
      if let result {
        #if os(iOS)
          self.cacheForPlayback(result, songID: songID)
        #endif
      }
    }
  }

  func clearCurrent() {
    lookupTask?.cancel()
    lookupTask = nil
    currentArtwork = nil
    currentSongID = nil
    isLoading = false
  }

  func artwork(for songID: UUID?) -> AnimatedArtworkResult? {
    guard currentSongID == songID else { return nil }
    return currentArtwork
  }

  func preferredPlaybackURL(for remoteURL: URL) -> URL {
    #if os(iOS)
      return AnimatedArtworkAssetDownloader.shared.cachedAsset(for: remoteURL) ?? remoteURL
    #else
      return remoteURL
    #endif
  }

  func clearCache() {
    clearCurrent()
    cache.removeAll()
    try? FileManager.default.removeItem(at: cacheFileURL)
    #if os(iOS)
      AnimatedArtworkAssetDownloader.shared.clearCache()
    #endif
  }

  #if os(iOS)
    private func cacheForPlayback(_ artwork: AnimatedArtworkResult, songID: UUID) {
      let title = "\(artwork.artist) — \(artwork.album)"
      Task { [weak self] in
        guard let self,
          self.currentSongID == songID,
          PlaybackController.shared.isPlaying
        else { return }

        _ = await AnimatedArtworkAssetDownloader.shared.localAsset(
          for: artwork.squareURL,
          title: title
        )
        guard self.currentSongID == songID else { return }
        self.cacheRevision += 1

        if let tallURL = artwork.tallURL,
          PlaybackController.shared.isPlaying
        {
          _ = await AnimatedArtworkAssetDownloader.shared.localAsset(
            for: tallURL,
            title: title
          )
          guard self.currentSongID == songID else { return }
          self.cacheRevision += 1
        }
      }
    }

    @available(iOS 26.0, *)
    func lockScreenArtwork(
      remoteURL: URL,
      previewImage: UIImage,
      title: String,
      songID: UUID
    ) -> MPMediaItemAnimatedArtwork {
      let artworkID = Self.stableID(for: remoteURL)
      return MPMediaItemAnimatedArtwork(
        artworkID: artworkID,
        previewImageRequestHandler: { requestedSize in
          await MainActor.run {
            Self.aspectFillPreview(previewImage, targetSize: requestedSize)
          }
        },
        videoAssetFileURLRequestHandler: { _ in
          let shouldDownload = await MainActor.run {
            PlaybackController.shared.isPlaying
              && PlaybackController.shared.currentItem?.id == songID
              && ThemeManager.shared.userPreferences?.animatedArtworkEnabled == true
          }
          guard shouldDownload else { return nil }
          return await AnimatedArtworkAssetDownloader.shared.localAsset(
            for: remoteURL,
            title: title
          )
        }
      )
    }
  #endif

  private func fetch(path: String, query: [String: String]) async -> AnimatedArtworkResult? {
    var components = URLComponents(
      url: endpoint.appendingPathComponent(path),
      resolvingAgainstBaseURL: false
    )
    components?.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) }
    guard let url = components?.url else { return nil }

    do {
      var request = URLRequest(url: url)
      request.setValue("application/json", forHTTPHeaderField: "Accept")
      let (data, response) = try await session.data(for: request)
      guard let http = response as? HTTPURLResponse, http.statusCode == 200,
        let result = try? JSONDecoder().decode(AnimatedArtworkResult.self, from: data),
        Self.isTrustedArtworkURL(result.squareURL),
        result.tallURL.map(Self.isTrustedArtworkURL) ?? true
      else { return nil }
      return result
    } catch {
      DiagnosticLog.shared.log("animated-artwork", "Lookup failed error=\(error.localizedDescription)")
      return nil
    }
  }

  private func validCacheEntry(for key: String) -> AnimatedArtworkCacheEntry? {
    guard let entry = cache[key] else { return nil }
    let lifetime = entry.result == nil ? negativeCacheLifetime : positiveCacheLifetime
    guard Date().timeIntervalSince(entry.fetchedAt) < lifetime else {
      cache.removeValue(forKey: key)
      return nil
    }
    return entry
  }

  private func cacheKey(artist: String, album: String) -> String {
    "\(normalize(artist))|\(normalize(album))"
  }

  private func normalize(_ value: String) -> String {
    value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
      .lowercased()
      .components(separatedBy: CharacterSet.alphanumerics.inverted)
      .filter { !$0.isEmpty }
      .joined(separator: " ")
  }

  private var cacheDirectory: URL {
    FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("AnimatedArtwork", isDirectory: true)
  }

  private var cacheFileURL: URL {
    cacheDirectory.appendingPathComponent("lookups.json")
  }

  private func loadCache() {
    guard let data = try? Data(contentsOf: cacheFileURL),
      let decoded = try? JSONDecoder().decode(
        [String: AnimatedArtworkCacheEntry].self,
        from: data
      )
    else { return }
    cache = decoded
  }

  private func saveCache() {
    do {
      try FileManager.default.createDirectory(
        at: cacheDirectory,
        withIntermediateDirectories: true
      )
      let data = try JSONEncoder().encode(cache)
      try data.write(to: cacheFileURL, options: .atomic)
    } catch {
      DiagnosticLog.shared.log("animated-artwork", "Cache save failed error=\(error)")
    }
  }

  private static func isAppleMusicURL(_ url: URL) -> Bool {
    guard let host = url.host?.lowercased() else { return false }
    return host == "music.apple.com" || host.hasSuffix(".music.apple.com")
  }

  private static func isTrustedArtworkURL(_ url: URL) -> Bool {
    guard url.scheme == "https", let host = url.host?.lowercased() else { return false }
    return host == "mvod.itunes.apple.com" && url.pathExtension.lowercased() == "m3u8"
  }

  fileprivate static func stableID(for url: URL) -> String {
    SHA256.hash(data: Data(url.absoluteString.utf8))
      .map { String(format: "%02x", $0) }
      .joined()
  }

  #if os(iOS)
    private static func aspectFillPreview(_ image: UIImage, targetSize: CGSize) -> UIImage {
      guard targetSize.width > 0, targetSize.height > 0 else { return image }
      let scale = max(targetSize.width / image.size.width, targetSize.height / image.size.height)
      let drawnSize = CGSize(width: image.size.width * scale, height: image.size.height * scale)
      let origin = CGPoint(
        x: (targetSize.width - drawnSize.width) / 2,
        y: (targetSize.height - drawnSize.height) / 2
      )
      return UIGraphicsImageRenderer(size: targetSize).image { _ in
        image.draw(in: CGRect(origin: origin, size: drawnSize))
      }
    }
  #endif
}

#if os(iOS)
  /// Downloads the small HLS animation with an ordinary foreground URL session.
  /// Using AVAssetDownloadURLSession makes iOS surface every artwork as a
  /// user-visible media download, which is inappropriate for an automatic cache.
  @MainActor
  private final class AnimatedArtworkAssetDownloader {
    static let shared = AnimatedArtworkAssetDownloader()

    private var downloads: [String: Task<URL?, Never>] = [:]
    private let storedLocationsKey = "com.ampwave.animatedArtworkAssetLocations"

    private var cacheDirectory: URL {
      // Documents is the app's Files-visible root. The shared app-group
      // container is intentionally hidden from Files, which made successfully
      // cached animations look as if they had never been downloaded.
      PathManager.documentsDirectory
        .appendingPathComponent("artworks", isDirectory: true)
        .appendingPathComponent("animated", isDirectory: true)
    }

    private var legacyCacheDirectory: URL {
      PathManager.baseDirectory
        .appendingPathComponent("artworks", isDirectory: true)
        .appendingPathComponent("animated", isDirectory: true)
    }

    func localAsset(for remoteURL: URL, title: String) async -> URL? {
      if let cached = cachedAsset(for: remoteURL) {
        return cached
      }

      let key = remoteURL.absoluteString
      if let download = downloads[key] {
        return await download.value
      }

      let download = Task<URL?, Never> { [weak self] in
        guard let self else { return nil }
        return await self.downloadHLSAsset(from: remoteURL, title: title)
      }
      downloads[key] = download
      let result = await download.value
      downloads.removeValue(forKey: key)
      return result
    }

    func clearCache() {
      for url in storedLocations.values {
        try? FileManager.default.removeItem(at: url)
      }
      try? FileManager.default.removeItem(at: cacheDirectory)
      if legacyCacheDirectory.standardizedFileURL != cacheDirectory.standardizedFileURL {
        try? FileManager.default.removeItem(at: legacyCacheDirectory)
      }
      UserDefaults.standard.removeObject(forKey: storedLocationsKey)
    }

    func cachedAsset(for remoteURL: URL) -> URL? {
      let key = AnimatedArtworkService.stableID(for: remoteURL)
      let silentCacheDirectory = cacheDirectory
        .appendingPathComponent("\(key).hls", isDirectory: true)
      let silentCache = silentCacheDirectory.appendingPathComponent("animation.mp4")
      if FileManager.default.fileExists(atPath: silentCache.path) { return silentCache }

      // A previous beta wrote a local m3u8 file here. AVFoundation doesn't
      // support that representation outside its managed .movpkg container.
      let brokenPlaylist = silentCacheDirectory.appendingPathComponent("index.m3u8")
      if FileManager.default.fileExists(atPath: brokenPlaylist.path) {
        try? FileManager.default.removeItem(at: silentCacheDirectory)
      }

      // Retain compatibility with animations downloaded by earlier builds.
      let expected = cacheDirectory.appendingPathComponent("\(key).movpkg", isDirectory: true)
      if FileManager.default.fileExists(atPath: expected.path) { return expected }
      if let cached = storedLocations[key], FileManager.default.fileExists(atPath: cached.path) {
        return migrateToVisibleCacheIfNeeded(assetAt: cached, key: key) ?? cached
      }

      // Move caches created by builds that wrote into the private app-group
      // container. The migration is lazy so launch never walks a potentially
      // large artwork directory.
      if legacyCacheDirectory.standardizedFileURL != cacheDirectory.standardizedFileURL {
        let legacyHLS = legacyCacheDirectory
          .appendingPathComponent("\(key).hls", isDirectory: true)
          .appendingPathComponent("animation.mp4")
        if FileManager.default.fileExists(atPath: legacyHLS.path),
          let migrated = migrateToVisibleCacheIfNeeded(assetAt: legacyHLS, key: key)
        {
          return migrated
        }

        let legacyMovpkg = legacyCacheDirectory
          .appendingPathComponent("\(key).movpkg", isDirectory: true)
        if FileManager.default.fileExists(atPath: legacyMovpkg.path),
          let migrated = migrateToVisibleCacheIfNeeded(assetAt: legacyMovpkg, key: key)
        {
          return migrated
        }
      }
      return nil
    }

    private func migrateToVisibleCacheIfNeeded(assetAt source: URL, key: String) -> URL? {
      guard !Self.isInside(source, directory: cacheDirectory) else { return source }

      let isPackage = source.pathExtension.lowercased() == "movpkg"
      let sourceContainer = isPackage ? source : source.deletingLastPathComponent()
      let destinationContainer = cacheDirectory.appendingPathComponent(
        "\(key).\(isPackage ? "movpkg" : "hls")",
        isDirectory: true
      )
      let destination = isPackage
        ? destinationContainer
        : destinationContainer.appendingPathComponent("animation.mp4")

      do {
        try FileManager.default.createDirectory(
          at: cacheDirectory,
          withIntermediateDirectories: true
        )
        try? FileManager.default.removeItem(at: destinationContainer)
        try FileManager.default.copyItem(at: sourceContainer, to: destinationContainer)
        guard FileManager.default.fileExists(atPath: destination.path) else { return nil }

        var stored = storedLocations
        stored[key] = destination
        storedLocations = stored
        DiagnosticLog.shared.log(
          "animated-artwork",
          "Migrated animation to Files-visible cache path=artworks/animated/\(destinationContainer.lastPathComponent)"
        )
        return destination
      } catch {
        DiagnosticLog.shared.log(
          "animated-artwork",
          "Could not migrate animation cache error=\(error.localizedDescription)"
        )
        return nil
      }
    }

    private static func isInside(_ url: URL, directory: URL) -> Bool {
      let path = url.standardizedFileURL.pathComponents
      let directoryPath = directory.standardizedFileURL.pathComponents
      return path.count >= directoryPath.count && path.starts(with: directoryPath)
    }

    private func downloadHLSAsset(from remoteURL: URL, title: String) async -> URL? {
      let key = AnimatedArtworkService.stableID(for: remoteURL)
      let destination = cacheDirectory.appendingPathComponent("\(key).hls", isDirectory: true)
      let temporary = cacheDirectory.appendingPathComponent(
        ".\(key)-\(UUID().uuidString).partial",
        isDirectory: true
      )

      do {
        let master = try await text(at: remoteURL)
        let mediaURL = selectMediaPlaylist(from: master, baseURL: remoteURL) ?? remoteURL
        let mediaPlaylist = mediaURL == remoteURL ? master : try await text(at: mediaURL)
        let references = resourceReferences(in: mediaPlaylist)
        var seenReferences = Set<String>()
        let uniqueReferences = references.filter { seenReferences.insert($0).inserted }
        guard uniqueReferences.count == 1,
          let reference = uniqueReferences.first,
          let resourceURL = URL(string: reference, relativeTo: mediaURL)?.absoluteURL,
          resourceURL.pathExtension.lowercased() == "mp4"
        else {
          throw URLError(.cannotDecodeContentData)
        }

        try FileManager.default.createDirectory(
          at: temporary,
          withIntermediateDirectories: true
        )
        let mediaData = try await data(at: resourceURL)
        try mediaData.write(
          to: temporary.appendingPathComponent("animation.mp4"),
          options: .atomic
        )
        try FileManager.default.createDirectory(
          at: cacheDirectory,
          withIntermediateDirectories: true
        )
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.moveItem(at: temporary, to: destination)

        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var directoryURL = cacheDirectory
        try? directoryURL.setResourceValues(values)

        let result = destination.appendingPathComponent("animation.mp4")
        let tracks = try await AVURLAsset(url: result).load(.tracks)
        guard tracks.contains(where: { $0.mediaType == .video }) else {
          throw URLError(.cannotDecodeContentData)
        }
        var stored = storedLocations
        stored[key] = result
        storedLocations = stored
        DiagnosticLog.shared.log(
          "animated-artwork",
          "Silently cached animation title=\(title) path=artworks/animated/\(destination.lastPathComponent)"
        )
        return result
      } catch {
        try? FileManager.default.removeItem(at: temporary)
        try? FileManager.default.removeItem(at: destination)
        DiagnosticLog.shared.log(
          "animated-artwork",
          "Could not cache animation title=\(title) error=\(error.localizedDescription)"
        )
        return nil
      }
    }

    private func text(at url: URL) async throws -> String {
      let data = try await data(at: url)
      guard let value = String(data: data, encoding: .utf8) else {
        throw URLError(.cannotDecodeContentData)
      }
      return value
    }

    private func data(at url: URL) async throws -> Data {
      var request = URLRequest(url: url)
      request.timeoutInterval = 60
      let (data, response) = try await URLSession.shared.data(for: request)
      guard let response = response as? HTTPURLResponse,
        (200..<300).contains(response.statusCode)
      else { throw URLError(.badServerResponse) }
      return data
    }

    private func selectMediaPlaylist(from master: String, baseURL: URL) -> URL? {
      let lines = master.components(separatedBy: .newlines)
      var candidates: [(url: URL, width: Int, isAVC: Bool)] = []
      for index in lines.indices where lines[index].hasPrefix("#EXT-X-STREAM-INF:") {
        guard index + 1 < lines.count else { continue }
        let reference = lines[index + 1].trimmingCharacters(in: .whitespacesAndNewlines)
        guard !reference.isEmpty, !reference.hasPrefix("#"),
          let url = URL(string: reference, relativeTo: baseURL)?.absoluteURL
        else { continue }
        let metadata = lines[index]
        let width = firstCapture(in: metadata, pattern: #"RESOLUTION=(\d+)x"#)
          .flatMap(Int.init) ?? 0
        candidates.append((url, width, metadata.contains("avc1")))
      }

      // 768p AVC is plenty for the player while keeping these repeating videos
      // much smaller than Apple's 1080p and 4K variants.
      return candidates.min { lhs, rhs in
        let lhsRank = (lhs.isAVC ? 0 : 1, abs(lhs.width - 768))
        let rhsRank = (rhs.isAVC ? 0 : 1, abs(rhs.width - 768))
        return lhsRank < rhsRank
      }?.url
    }

    private func resourceReferences(in playlist: String) -> [String] {
      var references: [String] = []
      for line in playlist.components(separatedBy: .newlines) {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty, !trimmed.hasPrefix("#") {
          references.append(trimmed)
        }
        var searchStart = trimmed.startIndex
        while let uriRange = trimmed.range(of: "URI=\"", range: searchStart..<trimmed.endIndex) {
          let valueStart = uriRange.upperBound
          guard let quote = trimmed[valueStart...].firstIndex(of: "\"") else { break }
          references.append(String(trimmed[valueStart..<quote]))
          searchStart = trimmed.index(after: quote)
        }
      }
      return references
    }

    private func firstCapture(in value: String, pattern: String) -> String? {
      guard let expression = try? NSRegularExpression(pattern: pattern),
        let match = expression.firstMatch(
          in: value,
          range: NSRange(value.startIndex..., in: value)
        ),
        match.numberOfRanges > 1,
        let range = Range(match.range(at: 1), in: value)
      else { return nil }
      return String(value[range])
    }

    private var storedLocations: [String: URL] {
      get {
        guard let data = UserDefaults.standard.data(forKey: storedLocationsKey),
          let paths = try? JSONDecoder().decode([String: String].self, from: data)
        else { return [:] }
        return paths.mapValues(URL.init(fileURLWithPath:))
      }
      set {
        let paths = newValue.mapValues(\.path)
        UserDefaults.standard.set(try? JSONEncoder().encode(paths), forKey: storedLocationsKey)
      }
    }
  }
#endif
