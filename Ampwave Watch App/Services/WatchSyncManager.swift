//
//  WatchSyncManager.swift
//  Ampwave Watch App
//

import Foundation
import WatchConnectivity
import SwiftData
import Observation

@MainActor
@Observable
final class WatchSyncManager: NSObject, WCSessionDelegate {
    static let shared = WatchSyncManager()
    
    var modelContext: ModelContext?
    private var session: WCSession?
    
    private override init() {
        super.init()
        if WCSession.isSupported() {
            session = WCSession.default
            session?.delegate = self
            session?.activate()
        }
    }
    
    func setModelContext(_ context: ModelContext) {
        self.modelContext = context
    }
    
    // MARK: - WCSessionDelegate
    
    func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
    }
    
    func session(_ session: WCSession, didReceiveUserInfo userInfo: [String : Any] = [:]) {
        guard let type = userInfo["type"] as? String else { return }
        
        Task { @MainActor in
            switch type {
            case "song_metadata":
                handleSongMetadata(userInfo)
            case "playlist_metadata":
                handlePlaylistMetadata(userInfo)
            case "playback_status":
                handlePlaybackStatus(userInfo)
            case "remove_song":
                handleRemoveSong(userInfo)
            case "remove_playlist":
                handleRemovePlaylist(userInfo)
            default:
                break
            }
        }
    }
    
    func session(_ session: WCSession, didReceive file: WCSessionFile) {
        guard let metadata = file.metadata,
              let idStr = metadata["id"] as? String,
              let id = UUID(uuidString: idStr),
              let type = metadata["type"] as? String else { return }
        
        Task { @MainActor in
            if type == "artwork" {
                handleArtworkFile(file.fileURL, songId: id)
            }
        }
    }
    
    // MARK: - Handlers
    
    private func handlePlaybackStatus(_ data: [String: Any]) {
        guard let isPlaying = data["isPlaying"] as? Bool,
              let currentTime = data["currentTime"] as? Double,
              let duration = data["duration"] as? Double else { return }
        
        let songIdStr = data["songId"] as? String
        let title = data["title"] as? String ?? ""
        let artist = data["artist"] as? String ?? ""
        
        WatchPlaybackManager.shared.updateRemoteStatus(
            isPlaying: isPlaying,
            currentTime: currentTime,
            duration: duration,
            songId: songIdStr != nil ? UUID(uuidString: songIdStr!) : nil,
            title: title,
            artist: artist
        )
    }
    
    private func handleSongMetadata(_ data: [String: Any]) {
        guard let idStr = data["id"] as? String,
              let id = UUID(uuidString: idStr),
              let title = data["title"] as? String,
              let artist = data["artist"] as? String,
              let context = modelContext else { return }
        
        let album = data["album"] as? String ?? ""
        let duration = data["duration"] as? Double ?? 0
        let lyrics = data["lyrics"] as? String ?? ""
        let ext = data["extension"] as? String ?? "m4a"
        let fileName = idStr + "." + ext
        
        // Fetch existing or create new
        let descriptor = FetchDescriptor<LibrarySong>(predicate: #Predicate { $0.id == id })
        if let existing = try? context.fetch(descriptor).first {
            existing.title = title
            existing.artist = artist
            existing.album = album
            existing.duration = duration
            existing.lyrics = lyrics
            existing.fileName = fileName
        } else {
            let newSong = LibrarySong(
                title: title,
                artist: artist,
                fileName: fileName,
                fileHash: "",
                size: 0,
                duration: duration,
                lyrics: lyrics,
                album: album
            )
            newSong.id = id
            context.insert(newSong)
        }
        try? context.save()
    }
    
    private func handleArtworkFile(_ url: URL, songId: UUID) {
        guard let context = modelContext else { return }
        
        let destination = getDocumentsDirectory().appendingPathComponent("\(songId.uuidString)_artwork.jpg")
        try? FileManager.default.removeItem(at: destination)
        try? FileManager.default.copyItem(at: url, to: destination)
        
        let descriptor = FetchDescriptor<LibrarySong>(predicate: #Predicate { $0.id == songId })
        if let existing = try? context.fetch(descriptor).first {
            existing.artworkPath = "\(songId.uuidString)_artwork.jpg"
        }
        try? context.save()
    }
    
    private func handlePlaylistMetadata(_ data: [String: Any]) {
        guard let idStr = data["id"] as? String,
              let id = UUID(uuidString: idStr),
              let name = data["name"] as? String,
              let songIdStrs = data["songIds"] as? [String],
              let context = modelContext else { return }
        
        let songIds = songIdStrs.compactMap { UUID(uuidString: $0) }
        
        let descriptor = FetchDescriptor<Playlist>(predicate: #Predicate { $0.id == id })
        let playlist: Playlist
        
        if let existing = try? context.fetch(descriptor).first {
            existing.name = name
            playlist = existing
        } else {
            playlist = Playlist(name: name)
            playlist.id = id
            context.insert(playlist)
        }
        
        // Update songs in playlist
        playlist.songs.removeAll()
        for songId in songIds {
            let songDescriptor = FetchDescriptor<LibrarySong>(predicate: #Predicate { $0.id == songId })
            if let song = try? context.fetch(songDescriptor).first {
                playlist.songs.append(song)
            } else {
                // Create a stub song if it doesn't exist yet
                let stub = LibrarySong(
                    title: "Loading...",
                    artist: "",
                    fileName: songId.uuidString + ".m4a",
                    fileHash: "",
                    size: 0
                )
                stub.id = songId
                context.insert(stub)
                playlist.songs.append(stub)
            }
        }
        
        try? context.save()
    }
    
    private func handleRemoveSong(_ data: [String: Any]) {
        guard let idStr = data["id"] as? String,
              let id = UUID(uuidString: idStr),
              let context = modelContext else { return }
        
        let descriptor = FetchDescriptor<LibrarySong>(predicate: #Predicate { $0.id == id })
        if let existing = try? context.fetch(descriptor).first {
            context.delete(existing)
        }
        try? context.save()
    }
    
    private func handleRemovePlaylist(_ data: [String: Any]) {
        guard let idStr = data["id"] as? String,
              let id = UUID(uuidString: idStr),
              let context = modelContext else { return }
        
        let descriptor = FetchDescriptor<Playlist>(predicate: #Predicate { $0.id == id })
        if let existing = try? context.fetch(descriptor).first {
            context.delete(existing)
        }
        try? context.save()
    }
    
    private func getDocumentsDirectory() -> URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }
}
