//
//  WatchSyncService.swift
//  Ampwave
//
//  Service for managing sync status between iOS app and Apple Watch.
//

import Foundation
import SwiftData

#if os(iOS)
  import WatchConnectivity
  import OSLog
#endif

/// Navigation renders these values without observing or faulting SwiftData
/// models. A fresh context stays entirely on the concurrent executor.
nonisolated struct WatchSyncSettingsSnapshot: Sendable {
  struct SongRow: Identifiable, Sendable {
    let id: UUID
    let title: String
    let artist: String
  }

  struct PlaylistRow: Identifiable, Sendable {
    let id: UUID
    let name: String
    let songCount: Int
  }

  let songs: [SongRow]
  let playlists: [PlaylistRow]

  // Required with MainActor defaults and NonisolatedNonsendingByDefault:
  // a plain async method can inherit the UI actor.
  @concurrent
  static func load(in container: ModelContainer) async throws -> Self {
    try Task.checkCancellation()
    let context = ModelContext(container)
    context.autosaveEnabled = false
    let songDescriptor = FetchDescriptor<LibrarySong>(
      predicate: #Predicate { $0.shouldSyncToWatch == true },
      sortBy: [SortDescriptor(\LibrarySong.title)]
    )
    let playlistDescriptor = FetchDescriptor<Playlist>(
      predicate: #Predicate { $0.shouldSyncToWatch == true },
      sortBy: [SortDescriptor(\Playlist.name)]
    )
    let songs = try context.fetch(songDescriptor).map { song in
      try Task.checkCancellation()
      return SongRow(id: song.id, title: song.title, artist: song.artist)
    }
    let playlists = try context.fetch(playlistDescriptor).map { playlist in
      try Task.checkCancellation()
      // Counting membership needs no sorting, UUID map, or per-song getters.
      return PlaylistRow(id: playlist.id, name: playlist.name, songCount: playlist.songs.count)
    }
    return Self(songs: songs, playlists: playlists)
  }
}

/// Invalidate pending queue work immediately, even if WatchConnectivity is
/// blocked. A token from before a reset must stay invalid after the reset ends.
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

/// Service for managing sync status of songs and playlists to Apple Watch
@MainActor
final class WatchSyncService: NSObject {
  // MARK: - Singleton

  static let shared = WatchSyncService()

  // MARK: - Properties

  private var modelContext: ModelContext?
  private var isLibraryResetting = false
  #if os(iOS)
    private lazy var transport = WatchSyncTransport { [weak self] in
      self?.syncEverything()
    }
  #endif

  // MARK: - Initialization

  private override init() {
    super.init()
    #if os(iOS)
      transport.start()
    #endif
  }

  // MARK: - Setup

  /// Sets the model context for database operations
  func setModelContext(_ context: ModelContext) {
    self.modelContext = context
  }

  func prepareForLibraryReset() {
    isLibraryResetting = true
    #if os(iOS)
      transport.setLibraryResetting(true)
    #endif
  }

  func libraryResetDidFinish() {
    isLibraryResetting = false
    #if os(iOS)
      transport.setLibraryResetting(false)
    #endif
  }

  // MARK: - Update Sync Status

  /// Resolve the current model only when the user acts, so a displayed row can
  /// safely outlive deletion/reset. Save in the caller's context before sending
  /// the removal, and let the UI display save errors.
  func removeSongFromSync(id: UUID, in context: ModelContext) throws {
    guard !isLibraryResetting else { return }
    var descriptor = FetchDescriptor<LibrarySong>(predicate: #Predicate { $0.id == id })
    descriptor.fetchLimit = 1
    guard let song = try context.fetch(descriptor).first else { return }
    song.shouldSyncToWatch = false
    try context.save()
    #if os(iOS)
      removeSongFromWatch(song)
    #endif
  }

  func removePlaylistFromSync(id: UUID, in context: ModelContext) throws {
    guard !isLibraryResetting else { return }
    var descriptor = FetchDescriptor<Playlist>(predicate: #Predicate { $0.id == id })
    descriptor.fetchLimit = 1
    guard let playlist = try context.fetch(descriptor).first else { return }
    playlist.shouldSyncToWatch = false
    try context.save()
    #if os(iOS)
      removePlaylistFromWatch(playlist)
    #endif
  }

  /// Updates the sync status for a song
  func updateSyncStatus(for song: LibrarySong, shouldSync: Bool) {
    guard !isLibraryResetting else { return }
    song.shouldSyncToWatch = shouldSync
    saveChanges()

    #if os(iOS)
      if shouldSync {
        sendSongToWatch(song)
      } else {
        removeSongFromWatch(song)
      }
    #endif
  }

  /// Updates the sync status for a playlist
  func updateSyncStatus(for playlist: Playlist, shouldSync: Bool) {
    guard !isLibraryResetting else { return }
    playlist.shouldSyncToWatch = shouldSync
    saveChanges()

    #if os(iOS)
      if shouldSync {
        sendPlaylistToWatch(playlist)
        // Also sync all songs in the playlist
        for song in playlist.orderedSongs {
          if !song.shouldSyncToWatch {
            updateSyncStatus(for: song, shouldSync: true)
          }
        }
      } else {
        removePlaylistFromWatch(playlist)
      }
    #endif
  }

  /// Toggles the sync status for a song
  func toggleSyncStatus(for song: LibrarySong) {
    updateSyncStatus(for: song, shouldSync: !song.shouldSyncToWatch)
  }

  /// Toggles the sync status for a playlist
  func toggleSyncStatus(for playlist: Playlist) {
    updateSyncStatus(for: playlist, shouldSync: !playlist.shouldSyncToWatch)
  }

  // MARK: - Playback Sync

  func updatePlaybackStatus(
    song: LibrarySong?, isPlaying: Bool, currentTime: TimeInterval, duration: TimeInterval
  ) {
    #if os(iOS)
      guard !isLibraryResetting else { return }
      // Only copy model values here. Even WCSession's state getters can wait
      // for its daemon, so all session access belongs to the transport queue.
      transport.send(
        .playback(
          songID: song?.id.uuidString, title: song?.title, artist: song?.artist,
          isPlaying: isPlaying, currentTime: currentTime, duration: duration
        ))
    #endif
  }

  // MARK: - Private Helpers

  private func saveChanges() {
    guard let context = modelContext else { return }

    do {
      try context.save()
    } catch {
      print("Failed to save sync status: \(error)")
    }
  }

  #if os(iOS)
    private func sendSongToWatch(_ song: LibrarySong) {
      // Materialize every SwiftData value before handing the payload to
      // WatchConnectivity. Optional.none is not a property-list value and was
      // previously passed as Any for lyrics/album, which can terminate the app.
      let songID = song.id.uuidString
      let artworkPath = song.effectiveArtworkPath

      transport.send(
        .song(
          id: songID, title: song.title, artist: song.artist, album: song.album ?? "",
          duration: song.duration, lyrics: song.lyrics ?? "",
          fileExtension: URL(fileURLWithPath: song.fileName).pathExtension
        ), artworkPath: artworkPath)
    }

    private func removeSongFromWatch(_ song: LibrarySong) {
      transport.send(.removeSong(id: song.id.uuidString))
    }

    private func sendPlaylistToWatch(_ playlist: Playlist) {
      transport.send(
        .playlist(
          id: playlist.id.uuidString, name: playlist.name,
          songIDs: playlist.orderedSongs.map { $0.id.uuidString }
        ))
    }

    private func removePlaylistFromWatch(_ playlist: Playlist) {
      transport.send(.removePlaylist(id: playlist.id.uuidString))
    }

    private func syncEverything() {
      guard !isLibraryResetting else { return }
      guard let songs = getSongsToSync(), let playlists = getPlaylistsToSync() else { return }

      for playlist in playlists {
        sendPlaylistToWatch(playlist)
      }

      for song in songs {
        sendSongToWatch(song)
      }
    }

    private func getSongsToSync() -> [LibrarySong]? {
      guard let context = modelContext else { return nil }
      let descriptor = FetchDescriptor<LibrarySong>(
        predicate: #Predicate { $0.shouldSyncToWatch == true })
      return try? context.fetch(descriptor)
    }

    private func getPlaylistsToSync() -> [Playlist]? {
      guard let context = modelContext else { return nil }
      let descriptor = FetchDescriptor<Playlist>(
        predicate: #Predicate { $0.shouldSyncToWatch == true })
      return try? context.fetch(descriptor)
    }

  #endif
}

#if os(iOS)
  /// Value-only messages keep SwiftData models and non-Sendable dictionaries
  /// from crossing executors. Dictionaries are built on the transport queue.
  nonisolated private enum WatchSyncMessage: Sendable {
    case song(
      id: String, title: String, artist: String, album: String,
      duration: Double, lyrics: String, fileExtension: String)
    case playlist(id: String, name: String, songIDs: [String])
    case removeSong(id: String)
    case removePlaylist(id: String)
    case playback(
      songID: String?, title: String?, artist: String?,
      isPlaying: Bool, currentTime: Double, duration: Double)

    var userInfo: [String: Any] {
      switch self {
      case .song(
        let id, let title, let artist, let album, let duration, let lyrics, let fileExtension):
        return [
          "type": "song_metadata", "id": id, "title": title, "artist": artist,
          "album": album, "duration": duration, "lyrics": lyrics, "extension": fileExtension,
        ]
      case .playlist(let id, let name, let songIDs):
        return ["type": "playlist_metadata", "id": id, "name": name, "songIds": songIDs]
      case .removeSong(let id):
        return ["type": "remove_song", "id": id]
      case .removePlaylist(let id):
        return ["type": "remove_playlist", "id": id]
      case .playback(
        let songID, let title, let artist, let isPlaying, let currentTime, let duration):
        var info: [String: Any] = [
          "type": "playback_status", "isPlaying": isPlaying,
          "currentTime": currentTime, "duration": duration,
        ]
        if let songID { info["songId"] = songID }
        if let title { info["title"] = title }
        if let artist { info["artist"] = artist }
        return info
      }
    }
  }

  /// WCSession is confined to `queue`; the reset gate has its own short lock.
  /// Delegates arrive on WCSession's queue and must enqueue work, never wait
  /// synchronously for either this queue or the main actor.
  nonisolated private final class WatchSyncTransport: NSObject, WCSessionDelegate,
    @unchecked Sendable
  {
    private let queue = DispatchQueue(label: "com.ampwave.watch-sync", qos: .utility)
    private let didActivate: @MainActor @Sendable () -> Void
    private let logger = Logger(subsystem: "com.ome.Ampwave", category: "watch-sync")
    private var session: WCSession?
    private let resetGate = WatchSyncResetGate()

    init(didActivate: @escaping @MainActor @Sendable () -> Void) {
      self.didActivate = didActivate
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

    func send(_ message: WatchSyncMessage, artworkPath: String? = nil) {
      guard let token = resetGate.token else { return }
      queue.async { [self] in
        guard resetGate.isCurrent(token), let session = availableSession,
          resetGate.isCurrent(token)
        else { return }
        let payload = message.userInfo
        if case .playback = message {
          // Position is replaceable state, not a growing queue of events.
          do {
            try session.updateApplicationContext(payload)
          } catch {
            logger.error("Playback context update failed: \(error.localizedDescription)")
          }
          if session.isReachable, resetGate.isCurrent(token) {
            session.sendMessage(payload, replyHandler: nil, errorHandler: nil)
          }
          return
        }

        let type = payload["type"] as? String
        let id = payload["id"] as? String
        for transfer in session.outstandingUserInfoTransfers {
          let queued = transfer.userInfo
          if queued["type"] as? String == type, queued["id"] as? String == id {
            transfer.cancel()
          }
        }
        guard resetGate.isCurrent(token) else { return }
        session.transferUserInfo(payload)

        if let artworkPath, let id, let artworkURL = PathManager.resolve(artworkPath) {
          let alreadyQueued = session.outstandingFileTransfers.contains {
            ($0.file.metadata?["type"] as? String) == "artwork"
              && ($0.file.metadata?["id"] as? String) == id
          }
          if !alreadyQueued, FileManager.default.fileExists(atPath: artworkURL.path),
            resetGate.isCurrent(token)
          {
            session.transferFile(artworkURL, metadata: ["type": "artwork", "id": id])
          }
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
      if activationState == .activated {
        queue.async { [self] in
          guard availableSession != nil else { return }
          Task { @MainActor in didActivate() }
        }
      }
    }

    func sessionDidBecomeInactive(_ session: WCSession) {}
    func sessionDidDeactivate(_ session: WCSession) {
      queue.async { self.session?.activate() }
    }

    func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
      guard let command = message["command"] as? String else { return }
      let songID = (message["songId"] as? String).flatMap(UUID.init(uuidString:))
      let seekTime = message["time"] as? Double

      Task { @MainActor in
        let playback = PlaybackController.shared
        switch command {
        case "play":
          playback.play()
        case "pause":
          playback.pause()
        case "toggle":
          playback.playPause()
        case "next":
          playback.playNext()
        case "previous":
          playback.playPrevious()
        case "play_song":
          if let songID {
            if let song = SongLibrary.shared.songs.first(where: { $0.id == songID }) {
              playback.play(song)
            }
          }
        case "seek":
          if let seekTime {
            playback.seek(to: seekTime)
          }
        default:
          break
        }
      }
    }
  }
#endif
