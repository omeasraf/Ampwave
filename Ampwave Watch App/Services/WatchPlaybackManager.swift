//
//  WatchPlaybackManager.swift
//  Ampwave Watch App
//

import Foundation
import Observation
import WatchConnectivity

struct RemotePlaybackStatus {
    var isPlaying: Bool = false
    var currentTime: TimeInterval = 0
    var duration: TimeInterval = 0
    var songId: UUID?
    var title: String = ""
    var artist: String = ""
}

@Observable
final class WatchPlaybackManager: NSObject {
    static let shared = WatchPlaybackManager()
    
    // Remote playback state
    var remoteStatus = RemotePlaybackStatus()
    
    private override init() {
        super.init()
    }
    
    func play(_ song: LibrarySong) {
        sendRemoteCommand("play_song", params: ["songId": song.id.uuidString])
    }
    
    func togglePlayback() {
        sendRemoteCommand("toggle")
    }
    
    func nextTrack() {
        sendRemoteCommand("next")
    }
    
    func previousTrack() {
        sendRemoteCommand("previous")
    }
    
    func seek(to time: TimeInterval) {
        sendRemoteCommand("seek", params: ["time": time])
    }
    
    // MARK: - Remote Updates
    
    func updateRemoteStatus(isPlaying: Bool, currentTime: TimeInterval, duration: TimeInterval, songId: UUID?, title: String, artist: String) {
        remoteStatus.isPlaying = isPlaying
        remoteStatus.currentTime = currentTime
        remoteStatus.duration = duration
        remoteStatus.songId = songId
        remoteStatus.title = title
        remoteStatus.artist = artist
    }
    
    private func sendRemoteCommand(_ command: String, params: [String: Any] = [:]) {
        guard WCSession.default.isReachable else { return }
        
        var message = params
        message["command"] = command
        WCSession.default.sendMessage(message, replyHandler: nil, errorHandler: nil)
    }
}
