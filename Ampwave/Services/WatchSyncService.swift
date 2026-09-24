// Keeps a metadata-only copy of the visible iPhone library on Apple Watch.
// Playback remains on the iPhone; audio files are never transferred.

import Foundation
import SwiftData

#if os(iOS)
  import OSLog
  import WatchConnectivity
#endif

/// A reset invalidates queued work before it can reach WatchConnectivity.
nonisolated final class WatchSyncResetGate: @unchecked Sendable {
  private let lock = NSLock()
  private var generation: UInt64 = 0
  private var isResetting = false

  func setResetting(_ resetting: Bool) {
    lock.withLock {
      isResetting = resetting
      if resetting { generation &+= 1 }
    }
  }

  var token: UInt64? {
    lock.withLock { isResetting ? nil : generation }
  }

  func isCurrent(_ token: UInt64) -> Bool {
    lock.withLock { !isResetting && token == generation }
  }
}

@MainActor
final class WatchSyncService: NSObject {
  static let shared = WatchSyncService()

  private var isLibraryResetting = false
  private var songsReady = false
  private var playlistsReady = false
  private var pendingForce = true
  private var catalogTask: Task<Void, Never>?
  private var lastSentCatalog: WatchCatalogSnapshot?
  private var saveObserver: NSObjectProtocol?
  private var libraryObserver: NSObjectProtocol?

  #if os(iOS)
    private lazy var transport = WatchSyncTransport { [weak self] in
      self?.scheduleCatalogRefresh(force: true)
    }
  #endif

  private override init() {
    super.init()
    #if os(iOS)
      transport.start()
    #endif
  }

  func setModelContext(_ context: ModelContext) {
    guard saveObserver == nil else { return }
    // Metadata updates and playlist edits can be saved by several contexts.
    // Debounce before reading the published, deduplicated library.
    saveObserver = NotificationCenter.default.addObserver(
      forName: ModelContext.didSave, object: nil, queue: nil
    ) { [weak self] _ in
      Task { @MainActor [weak self] in self?.scheduleCatalogRefresh() }
    }
    libraryObserver = NotificationCenter.default.addObserver(
      forName: .songLibraryDidChange, object: SongLibrary.shared, queue: nil
    ) { [weak self] _ in
      Task { @MainActor [weak self] in self?.scheduleCatalogRefresh() }
    }
  }

  func songLibraryDidLoad() {
    songsReady = true
    scheduleCatalogRefresh()
  }

  func playlistLibraryDidLoad() {
    playlistsReady = true
    scheduleCatalogRefresh()
  }

  func prepareForLibraryReset() {
    isLibraryResetting = true
    songsReady = false
    playlistsReady = false
    catalogTask?.cancel()
    catalogTask = nil
    #if os(iOS)
      transport.setLibraryResetting(true)
    #endif
  }

  func libraryResetDidFinish() {
    isLibraryResetting = false
    songsReady = true
    playlistsReady = true
    lastSentCatalog = nil
    #if os(iOS)
      transport.setLibraryResetting(false)
    #endif
    scheduleCatalogRefresh(force: true)
  }

  func updatePlaybackStatus(
    song: LibrarySong?, isPlaying: Bool, currentTime: TimeInterval, duration: TimeInterval
  ) {
    #if os(iOS)
      guard !isLibraryResetting else { return }
      transport.sendPlayback(
        songID: song?.id.uuidString, title: song?.title, artist: song?.artist,
        isPlaying: isPlaying, currentTime: currentTime, duration: duration
      )
    #endif
  }

  private func scheduleCatalogRefresh(force: Bool = false) {
    if force { pendingForce = true }
    guard songsReady, playlistsReady, !isLibraryResetting else { return }
    // A fixed coalescing window avoids starving the Watch while a large
    // metadata import keeps saving every few seconds.
    guard catalogTask == nil else { return }
    catalogTask = Task { [weak self] in
      try? await Task.sleep(for: .seconds(force ? 1 : 3))
      guard !Task.isCancelled else { return }
      self?.sendCatalogIfNeeded()
      self?.catalogTask = nil
    }
  }

  private func sendCatalogIfNeeded() {
    #if os(iOS)
      guard !isLibraryResetting, songsReady, playlistsReady else { return }
      let library = SongLibrary.shared
      let songs = library.songs.filter { library.isVisibleInLibrary($0) }.sorted {
        let order = $0.title.localizedCaseInsensitiveCompare($1.title)
        return order == .orderedSame ? $0.id.uuidString < $1.id.uuidString : order == .orderedAscending
      }
      let visibleIDs = Set(songs.map(\.id))
      let rows = songs.map {
        WatchCatalogSnapshot.Song(
          id: $0.id, title: $0.title, artist: $0.artist,
          album: $0.album ?? "", duration: $0.duration
        )
      }
      let playlists = PlaylistManager.shared.playlists.sorted {
        let order = $0.name.localizedCaseInsensitiveCompare($1.name)
        return order == .orderedSame ? $0.id.uuidString < $1.id.uuidString : order == .orderedAscending
      }.map { playlist in
        WatchCatalogSnapshot.Playlist(
          id: playlist.id,
          name: playlist.name,
          songIDs: library.visibleSongs(from: playlist.orderedSongs).map(\.id)
            .filter { visibleIDs.contains($0) }
        )
      }
      let comparison = WatchCatalogSnapshot(revision: 0, songs: rows, playlists: playlists)
      guard pendingForce || comparison != lastSentCatalog else { return }
      let snapshot = WatchCatalogSnapshot(
        revision: Date().timeIntervalSince1970, songs: rows, playlists: playlists
      )
      do {
        let data = try JSONEncoder().encode(snapshot)
        transport.sendCatalog(data, revision: snapshot.revision)
        lastSentCatalog = comparison
        pendingForce = false
      } catch {
        pendingForce = true
      }
    #endif
  }
}

#if os(iOS)
  /// WCSession belongs to one utility queue so its potentially blocking state
  /// getters never interrupt scrolling or the initial launch animation.
  nonisolated private final class WatchSyncTransport: NSObject, WCSessionDelegate,
    @unchecked Sendable
  {
    private let queue = DispatchQueue(label: "com.ampwave.watch-sync", qos: .utility)
    private let didNeedCatalog: @MainActor @Sendable () -> Void
    private let logger = Logger(subsystem: "com.ome.Ampwave", category: "watch-sync")
    private let resetGate = WatchSyncResetGate()
    private var session: WCSession?

    init(didNeedCatalog: @escaping @MainActor @Sendable () -> Void) {
      self.didNeedCatalog = didNeedCatalog
      super.init()
    }

    func start() {
      queue.async { [self] in
        guard WCSession.isSupported() else { return }
        let session = WCSession.default
        self.session = session
        session.delegate = self
        session.activate()
      }
    }

    func setLibraryResetting(_ resetting: Bool) {
      resetGate.setResetting(resetting)
    }

    func sendCatalog(_ data: Data, revision: TimeInterval) {
      guard let token = resetGate.token else { return }
      queue.async { [self] in
        guard resetGate.isCurrent(token), let session = availableSession else { return }
        let url = FileManager.default.temporaryDirectory
          .appendingPathComponent("watch-catalog-\(UUID().uuidString).json")
        do {
          try data.write(to: url, options: .atomic)
          guard resetGate.isCurrent(token) else {
            try? FileManager.default.removeItem(at: url)
            return
          }
          for transfer in session.outstandingFileTransfers
          where transfer.file.metadata?["type"] as? String == "catalog" {
            transfer.cancel()
          }
          session.transferFile(url, metadata: ["type": "catalog", "revision": revision])
        } catch {
          logger.error("Watch catalog transfer failed: \(error.localizedDescription)")
          try? FileManager.default.removeItem(at: url)
        }
      }
    }

    func sendPlayback(
      songID: String?, title: String?, artist: String?, isPlaying: Bool,
      currentTime: Double, duration: Double
    ) {
      guard let token = resetGate.token else { return }
      queue.async { [self] in
        guard resetGate.isCurrent(token), let session = availableSession else { return }
        var payload: [String: Any] = [
          "type": "playback_status", "isPlaying": isPlaying,
          "currentTime": currentTime, "duration": duration,
        ]
        if let songID { payload["songId"] = songID }
        if let title { payload["title"] = title }
        if let artist { payload["artist"] = artist }
        do {
          try session.updateApplicationContext(payload)
        } catch {
          logger.error("Watch playback context failed: \(error.localizedDescription)")
        }
        if session.isReachable, resetGate.isCurrent(token) {
          session.sendMessage(payload, replyHandler: nil, errorHandler: nil)
        }
      }
    }

    private var availableSession: WCSession? {
      dispatchPrecondition(condition: .onQueue(queue))
      guard resetGate.token != nil, let session,
        session.activationState == .activated, session.isPaired, session.isWatchAppInstalled
      else { return nil }
      return session
    }

    func session(
      _ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState,
      error: Error?
    ) {
      if activationState == .activated { Task { @MainActor in didNeedCatalog() } }
    }

    func sessionWatchStateDidChange(_ session: WCSession) {
      Task { @MainActor in didNeedCatalog() }
    }

    func sessionDidBecomeInactive(_ session: WCSession) {}

    func sessionDidDeactivate(_ session: WCSession) {
      queue.async { self.session?.activate() }
    }

    func session(_ session: WCSession, didFinish fileTransfer: WCSessionFileTransfer,
                 error: Error?) {
      guard fileTransfer.file.metadata?["type"] as? String == "catalog" else { return }
      try? FileManager.default.removeItem(at: fileTransfer.file.fileURL)
      if let error {
        logger.error("Watch catalog delivery failed: \(error.localizedDescription)")
        Task { @MainActor in didNeedCatalog() }
      }
    }

    func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
      guard let command = message["command"] as? String else { return }
      if command == "request_catalog" {
        Task { @MainActor in didNeedCatalog() }
        return
      }
      let songID = (message["songId"] as? String).flatMap(UUID.init(uuidString:))
      let seekTime = message["time"] as? Double
      Task { @MainActor in
        let playback = PlaybackController.shared
        switch command {
        case "play": playback.play()
        case "pause": playback.pause()
        case "toggle": playback.playPause()
        case "next": playback.playNext()
        case "previous": playback.playPrevious()
        case "play_song":
          if let songID, let song = SongLibrary.shared.song(id: songID) {
            playback.play(song)
          }
        case "seek":
          if let seekTime { playback.seek(to: seekTime) }
        default: break
        }
      }
    }
  }
#endif
