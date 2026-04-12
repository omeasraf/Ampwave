//
//  WatchSyncService.swift
//  Ampwave
//
//  Service for managing sync status between iOS app and Apple Watch.
//

import Foundation
import SwiftData
import WatchConnectivity

import Foundation
import SwiftData
import WatchConnectivity

/// Service for managing sync status of songs and playlists to Apple Watch
final class WatchSyncService: NSObject, WCSessionDelegate {
    // MARK: - Singleton
    
    static let shared = WatchSyncService()
    
    // MARK: - Properties
    
    private var modelContext: ModelContext?
    private var session: WCSession?
    
    // MARK: - Initialization
    
    private override init() {
        super.init()
        if WCSession.isSupported() {
            session = WCSession.default
            session?.delegate = self
            session?.activate()
        }
    }
    
    // MARK: - Setup
    
    /// Sets the model context for database operations
    func setModelContext(_ context: ModelContext) {
        self.modelContext = context
    }
    
    // MARK: - WCSessionDelegate
    func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        if activationState == .activated {
            print("WCSession activated on iOS")
            syncEverything()
        }
    }
    
    private func syncEverything() {
        guard let songs = getSongsToSync(), let playlists = getPlaylistsToSync() else { return }
        
        for playlist in playlists {
            sendPlaylistToWatch(playlist)
        }
        
        for song in songs {
            sendSongToWatch(song)
        }
    }


    func sessionDidBecomeInactive(_ session: WCSession) {}
    func sessionDidDeactivate(_ session: WCSession) {
        session.activate()
    }

    func session(_ session: WCSession, didReceiveMessage message: [String : Any]) {
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
                   let songId = UUID(uuidString: songIdStr) {
                    // Find song in library and play
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

    // MARK: - Update Sync Status

    /// Updates the sync status for a song
    // MARK: - Playback Sync

    func updatePlaybackStatus(song: LibrarySong?, isPlaying: Bool, currentTime: TimeInterval, duration: TimeInterval) {
        guard let session = session, session.activationState == .activated else { return }

        var status: [String: Any] = [
            "type": "playback_status",
            "isPlaying": isPlaying,
            "currentTime": currentTime,
            "duration": duration
        ]

        if let song = song {
            status["songId"] = song.id.uuidString
            status["title"] = song.title
            status["artist"] = song.artist
        }

        session.transferUserInfo(status)
    }

    // MARK: - Private Sync Logic

    ///   - song: The song to update
    ///   - shouldSync: Whether the song should sync to the watch
    func updateSyncStatus(for song: LibrarySong, shouldSync: Bool) {
        song.shouldSyncToWatch = shouldSync
        saveChanges()
        
        if shouldSync {
            sendSongToWatch(song)
        } else {
            removeSongFromWatch(song)
        }
    }
    
    /// Updates the sync status for a playlist
    /// - Parameters:
    ///   - playlist: The playlist to update
    ///   - shouldSync: Whether the playlist should sync to the watch
    func updateSyncStatus(for playlist: Playlist, shouldSync: Bool) {
        playlist.shouldSyncToWatch = shouldSync
        saveChanges()
        
        if shouldSync {
            sendPlaylistToWatch(playlist)
            // Also sync all songs in the playlist
            for song in playlist.songs {
                if !song.shouldSyncToWatch {
                    updateSyncStatus(for: song, shouldSync: true)
                }
            }
        } else {
            removePlaylistFromWatch(playlist)
        }
    }
    
    /// Toggles the sync status for a song
    /// - Parameter song: The song to toggle
    func toggleSyncStatus(for song: LibrarySong) {
        updateSyncStatus(for: song, shouldSync: !song.shouldSyncToWatch)
    }
    
    /// Toggles the sync status for a playlist
    /// - Parameter playlist: The playlist to toggle
    func toggleSyncStatus(for playlist: Playlist) {
        updateSyncStatus(for: playlist, shouldSync: !playlist.shouldSyncToWatch)
    }
    
    // MARK: - Batch Operations
    
    /// Syncs all songs in a playlist to the watch
    /// - Parameters:
    ///   - playlist: The playlist whose songs should be synced
    ///   - shouldSync: Whether the songs should sync to the watch
    func updateSyncStatus(forSongsIn playlist: Playlist, shouldSync: Bool) {
        for song in playlist.songs {
            updateSyncStatus(for: song, shouldSync: shouldSync)
        }
    }
    
    /// Gets all songs marked for sync
    func getSongsToSync() -> [LibrarySong]? {
        guard let context = modelContext else { return nil }
        
        let descriptor = FetchDescriptor<LibrarySong>(
            predicate: #Predicate { $0.shouldSyncToWatch == true }
        )
        
        return try? context.fetch(descriptor)
    }
    
    /// Gets all playlists marked for sync
    func getPlaylistsToSync() -> [Playlist]? {
        guard let context = modelContext else { return nil }
        
        let descriptor = FetchDescriptor<Playlist>(
            predicate: #Predicate { $0.shouldSyncToWatch == true }
        )
        
        return try? context.fetch(descriptor)
    }
    
    // MARK: - Private Sync Logic
    
    private func sendSongToWatch(_ song: LibrarySong) {
        guard let session = session, session.activationState == .activated else { return }
        
        // Only Send Metadata
        let metadata: [String: Any] = [
            "type": "song_metadata",
            "id": song.id.uuidString,
            "title": song.title,
            "artist": song.artist,
            "album": song.album,
            "duration": song.duration,
            "lyrics": song.lyrics,
        ]
        session.transferUserInfo(metadata)
        
        // Transfer Artwork
        if let artworkPath = song.artworkPath, let artworkURL = PathManager.resolve(artworkPath) {
            if FileManager.default.fileExists(atPath: artworkURL.path) {
                session.transferFile(artworkURL, metadata: ["type": "artwork", "id": song.id.uuidString])
            }
        }
    }
    
    private func removeSongFromWatch(_ song: LibrarySong) {
        guard let session = session, session.activationState == .activated else { return }
        
        session.transferUserInfo([
            "type": "remove_song",
            "id": song.id.uuidString
        ])
    }
    
    private func sendPlaylistToWatch(_ playlist: Playlist) {
        guard let session = session, session.activationState == .activated else { return }
        
        let metadata: [String: Any] = [
            "type": "playlist_metadata",
            "id": playlist.id.uuidString,
            "name": playlist.name,
            "songIds": playlist.songs.map { $0.id.uuidString }
        ]
        session.transferUserInfo(metadata)
    }
    
    private func removePlaylistFromWatch(_ playlist: Playlist) {
        guard let session = session, session.activationState == .activated else { return }
        
        session.transferUserInfo([
            "type": "remove_playlist",
            "id": playlist.id.uuidString
        ])
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
    
    private func notifyWatchAboutSyncChange() {
        // Obsolete: replaced by granular updates in updateSyncStatus
    }
}

