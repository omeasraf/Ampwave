// Receives metadata-only library snapshots. The Watch stores browse data,
// never the iPhone's audio files or remote-library credentials.

import Foundation
import Observation
import SwiftData
import WatchConnectivity

@MainActor
@Observable
final class WatchSyncManager: NSObject, WCSessionDelegate {
  static let shared = WatchSyncManager()

  var modelContext: ModelContext?
  private var session: WCSession?
  private let lastRevisionKey = "com.ampwave.watchCatalog.lastRevision.v1"

  private override init() {
    super.init()
    if WCSession.isSupported() {
      session = WCSession.default
      session?.delegate = self
      session?.activate()
    }
  }

  func setModelContext(_ context: ModelContext) {
    modelContext = context
  }

  func requestCatalog() {
    guard let session, session.activationState == .activated, session.isReachable else { return }
    session.sendMessage(["command": "request_catalog"], replyHandler: nil, errorHandler: nil)
  }

  func session(
    _ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState,
    error: Error?
  ) {
    if activationState == .activated { requestCatalog() }
  }

  func sessionReachabilityDidChange(_ session: WCSession) {
    if session.isReachable { requestCatalog() }
  }

  func session(_ session: WCSession, didReceiveApplicationContext context: [String: Any]) {
    receivePlayback(context)
  }

  func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
    receivePlayback(message)
  }

  func session(_ session: WCSession, didReceive file: WCSessionFile) {
    guard file.metadata?["type"] as? String == "catalog" else { return }
    // WatchConnectivity deletes its temporary file as soon as this delegate
    // callback returns. Consume the small JSON snapshot before hopping actors.
    guard let data = try? Data(contentsOf: file.fileURL) else { return }
    Task { @MainActor in applyCatalog(data) }
  }

  private func receivePlayback(_ data: [String: Any]) {
    guard data["type"] as? String == "playback_status",
      let isPlaying = data["isPlaying"] as? Bool,
      let currentTime = data["currentTime"] as? Double,
      let duration = data["duration"] as? Double
    else { return }
    let songID = (data["songId"] as? String).flatMap(UUID.init(uuidString:))
    let title = data["title"] as? String ?? ""
    let artist = data["artist"] as? String ?? ""
    Task { @MainActor in
      WatchPlaybackManager.shared.updateRemoteStatus(
        isPlaying: isPlaying, currentTime: currentTime, duration: duration,
        songId: songID, title: title, artist: artist
      )
    }
  }

  private func applyCatalog(_ data: Data) {
    guard let context = modelContext,
      let snapshot = try? JSONDecoder().decode(WatchCatalogSnapshot.self, from: data),
      snapshot.version == WatchCatalogSnapshot.currentVersion,
      snapshot.revision > UserDefaults.standard.double(forKey: lastRevisionKey)
    else { return }

    do {
      var changed = false
      let existingSongs = try context.fetch(FetchDescriptor<LibrarySong>())
      let songsByID = Dictionary(existingSongs.map { ($0.id, $0) },
                                 uniquingKeysWith: { first, _ in first })
      var currentSongs: [UUID: LibrarySong] = [:]
      for row in snapshot.songs {
        let song: LibrarySong
        if let existing = songsByID[row.id] {
          song = existing
        } else {
          song = LibrarySong(
            title: row.title, artist: row.artist, fileName: row.id.uuidString + ".watch",
            fileHash: "", size: 0
          )
          song.id = row.id
          context.insert(song)
          changed = true
        }
        if song.title != row.title { song.title = row.title; changed = true }
        if song.artist != row.artist { song.artist = row.artist; changed = true }
        if song.album != row.album { song.album = row.album; changed = true }
        if song.duration != row.duration { song.duration = row.duration; changed = true }
        currentSongs[row.id] = song
      }

      let existingPlaylists = try context.fetch(FetchDescriptor<Playlist>())
      let playlistsByID = Dictionary(existingPlaylists.map { ($0.id, $0) },
                                     uniquingKeysWith: { first, _ in first })
      let incomingPlaylistIDs = Set(snapshot.playlists.map(\.id))
      for row in snapshot.playlists {
        let playlist: Playlist
        if let existing = playlistsByID[row.id] {
          playlist = existing
        } else {
          playlist = Playlist(name: row.name)
          playlist.id = row.id
          context.insert(playlist)
          changed = true
        }
        if playlist.name != row.name { playlist.name = row.name; changed = true }
        let order = row.songIDs.filter { currentSongs[$0] != nil }
        if playlist.songOrder != order || playlist.songs.count != order.count {
          playlist.songOrder = order
          playlist.songs = order.compactMap { currentSongs[$0] }
          changed = true
        }
      }

      for playlist in existingPlaylists where !incomingPlaylistIDs.contains(playlist.id) {
        context.delete(playlist)
        changed = true
      }
      let incomingSongIDs = Set(snapshot.songs.map(\.id))
      for song in existingSongs where !incomingSongIDs.contains(song.id) {
        context.delete(song)
        changed = true
      }
      if changed { try context.save() }
      UserDefaults.standard.set(snapshot.revision, forKey: lastRevisionKey)
    } catch {
      print("Watch catalog update failed: \(error)")
    }
  }
}
