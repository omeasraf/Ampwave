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
#endif

/// Service for managing sync status of songs and playlists to Apple Watch
@MainActor
final class WatchSyncService: NSObject {
  // MARK: - Singleton

  static let shared = WatchSyncService()

  // MARK: - Properties

  private var modelContext: ModelContext?
  private var isLibraryResetting = false
  #if os(iOS)
    private var session: WCSession?
  #endif

  // MARK: - Initialization

  private override init() {
    super.init()
    #if os(iOS)
      if WCSession.isSupported() {
        session = WCSession.default
        session?.delegate = self
        session?.activate()
      }
    #endif
  }

  // MARK: - Setup

  /// Sets the model context for database operations
  func setModelContext(_ context: ModelContext) {
    self.modelContext = context
  }

  func prepareForLibraryReset() {
    isLibraryResetting = true
  }

  func libraryResetDidFinish() {
    isLibraryResetting = false
  }

  // MARK: - Update Sync Status

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
      guard let session,
        session.activationState == .activated,
        session.isPaired,
        session.isWatchAppInstalled,
        !isLibraryResetting
      else { return }

      var status: [String: Any] = [
        "type": "playback_status",
        "isPlaying": isPlaying,
        "currentTime": currentTime,
        "duration": duration,
      ]

      if let song = song {
        status["songId"] = song.id.uuidString
        status["title"] = song.title
        status["artist"] = song.artist
      }

      // Playback position is replaceable state, not a queue of events. Using
      // transferUserInfo here accumulated stale updates and could overwhelm
      // WatchConnectivity after extended playback.
      do {
        try session.updateApplicationContext(status)
      } catch {
        DiagnosticLog.shared.log(
          "watch-sync",
          "Playback context update failed error=\(error.localizedDescription)"
        )
      }
      if session.isReachable {
        session.sendMessage(status, replyHandler: nil, errorHandler: nil)
      }
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
      guard let session = availableSession else { return }

      // Materialize every SwiftData value before handing the payload to
      // WatchConnectivity. Optional.none is not a property-list value and was
      // previously passed as Any for lyrics/album, which can terminate the app.
      let songID = song.id.uuidString
      let artworkPath = song.effectiveArtworkPath

      let metadata: [String: Any] = [
        "type": "song_metadata",
        "id": songID,
        "title": song.title,
        "artist": song.artist,
        "album": song.album ?? "",
        "duration": song.duration,
        "lyrics": song.lyrics ?? "",
        "extension": URL(fileURLWithPath: song.fileName).pathExtension,
      ]
      enqueue(metadata, on: session)

      if let artworkPath,
        let artworkURL = PathManager.resolve(artworkPath)
      {
        let alreadyQueued = session.outstandingFileTransfers.contains {
          ($0.file.metadata?["type"] as? String) == "artwork"
            && ($0.file.metadata?["id"] as? String) == songID
        }
        if !alreadyQueued, FileManager.default.fileExists(atPath: artworkURL.path) {
          session.transferFile(artworkURL, metadata: ["type": "artwork", "id": songID])
        }
      }
    }

    private func removeSongFromWatch(_ song: LibrarySong) {
      guard let session = availableSession else { return }

      enqueue([
        "type": "remove_song",
        "id": song.id.uuidString,
      ], on: session)
    }

    private func sendPlaylistToWatch(_ playlist: Playlist) {
      guard let session = availableSession else { return }

      let metadata: [String: Any] = [
        "type": "playlist_metadata",
        "id": playlist.id.uuidString,
        "name": playlist.name,
        "songIds": playlist.orderedSongs.map { $0.id.uuidString },
      ]
      enqueue(metadata, on: session)
    }

    private func removePlaylistFromWatch(_ playlist: Playlist) {
      guard let session = availableSession else { return }

      enqueue([
        "type": "remove_playlist",
        "id": playlist.id.uuidString,
      ], on: session)
    }

    private func syncEverything() {
      guard !isLibraryResetting, availableSession != nil else { return }
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

    private var availableSession: WCSession? {
      guard !isLibraryResetting,
        let session,
        session.activationState == .activated,
        session.isPaired,
        session.isWatchAppInstalled
      else {
        DiagnosticLog.shared.log(
          "watch-sync",
          "Transfer skipped resetting=\(isLibraryResetting) activated=\(session?.activationState.rawValue ?? -1) paired=\(session?.isPaired ?? false) installed=\(session?.isWatchAppInstalled ?? false)"
        )
        return nil
      }
      return session
    }

    private func enqueue(_ payload: [String: Any], on session: WCSession) {
      let type = payload["type"] as? String
      let id = payload["id"] as? String
      for transfer in session.outstandingUserInfoTransfers {
        let queued = transfer.userInfo
        if queued["type"] as? String == type,
          queued["id"] as? String == id
        {
          transfer.cancel()
        }
      }
      session.transferUserInfo(payload)
    }
  #endif
}

#if os(iOS)
  extension WatchSyncService: WCSessionDelegate {
    func session(
      _ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState,
      error: Error?
    ) {
      if activationState == .activated {
        // WatchConnectivity invokes delegates on its own operation queue.
        // ModelContext is main-actor confined; fetching from that callback
        // concurrently with the UI corrupts SwiftData's registration cache.
        Task { @MainActor [weak self] in
          print("WCSession activated on iOS")
          self?.syncEverything()
        }
      }
    }

    func sessionDidBecomeInactive(_ session: WCSession) {}
    func sessionDidDeactivate(_ session: WCSession) {
      session.activate()
    }

    func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
      guard let command = message["command"] as? String else { return }

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
          if let songIdStr = message["songId"] as? String,
            let songId = UUID(uuidString: songIdStr)
          {
            if let song = SongLibrary.shared.songs.first(where: { $0.id == songId }) {
              playback.play(song)
            }
          }
        case "seek":
          if let time = message["time"] as? Double {
            playback.seek(to: time)
          }
        default:
          break
        }
      }
    }
  }
#endif
