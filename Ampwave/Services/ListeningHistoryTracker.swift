//
//  ListeningHistoryTracker.swift
//  Ampwave
//

import Foundation
import SwiftData
import Observation

@MainActor
@Observable
final class ListeningHistoryTracker {
    static let shared = ListeningHistoryTracker()
    
    var modelContext: ModelContext?
    private var currentSong: LibrarySong?
    private var currentPlayStartTime: Date?
    private var currentPlayDuration: TimeInterval = 0
    private var currentSourceRaw: String?
    private var currentPlaylistId: UUID?
    
    private init() {}
    
    func setModelContext(_ context: ModelContext) {
        self.modelContext = context
    }
    
    /// Called when a song starts playing
    func songStarted(_ song: LibrarySong, source: PlaySource = PlaySource.library, playlistId: UUID? = nil) {
        // If there was a previous song playing, record it
        if let previousSong = currentSong, let startTime = currentPlayStartTime {
            let playDuration = Date().timeIntervalSince(startTime)
            // Record the previous song with its known source if available; fall back to provided source
            let usedSource = PlaySource(rawValue: currentSourceRaw ?? source.rawValue) ?? .library
            recordPlay(song: previousSong, duration: playDuration, source: usedSource, playlistId: currentPlaylistId ?? playlistId)
        }
        
        currentSong = song
        currentPlayStartTime = Date()
        currentPlayDuration = 0
        currentSourceRaw = source.rawValue
        currentPlaylistId = playlistId
    }
    
    /// Called when a song is paused
    func songPaused() {
        if let startTime = currentPlayStartTime {
            currentPlayDuration += Date().timeIntervalSince(startTime)
            currentPlayStartTime = nil
        }
    }
    
    /// Called when a song is resumed
    func songResumed() {
        currentPlayStartTime = Date()
    }
    
    /// Called when a song ends or is skipped
    func songEnded(skipped: Bool = false) {
        guard let song = currentSong else { return }
        
        if let startTime = currentPlayStartTime {
            currentPlayDuration += Date().timeIntervalSince(startTime)
        }
        
        if skipped {
            recordSkip(song: song)
        } else {
            let usedSource = PlaySource(rawValue: currentSourceRaw ?? PlaySource.library.rawValue) ?? .library
            recordPlay(song: song, duration: currentPlayDuration, source: usedSource, playlistId: currentPlaylistId)
        }
        
        currentSong = nil
        currentPlayStartTime = nil
        currentPlayDuration = 0
        currentSourceRaw = nil
        currentPlaylistId = nil
    }
    
    /// Records a play in the database
    private func recordPlay(song: LibrarySong, duration: TimeInterval, source: PlaySource, playlistId: UUID? = nil) {
        guard let modelContext = modelContext else { return }
        
        // Create history entry
        let history = ListeningHistory(
            song: song,
            playDuration: duration,
            source: source,
            playlistId: playlistId
        )
        modelContext.insert(history)
        
        // Update or create statistics
        updateStatistics(for: song, duration: duration)
        
        // Save
        try? modelContext.save()
    }
    
    /// Records a skip
    private func recordSkip(song: LibrarySong) {
        guard let modelContext = modelContext else { return }
        
        let stats = getOrCreateStatistics(for: song)
        stats.recordSkip()
        
        try? modelContext.save()
    }
    
    /// Gets or creates statistics for a song
    private func getOrCreateStatistics(for song: LibrarySong) -> SongPlayStatistics {
        guard let modelContext = modelContext else {
            return SongPlayStatistics(songId: song.id)
        }
        
        // Use a simpler fetch without predicate macro
        let descriptor = FetchDescriptor<SongPlayStatistics>()
        
        if let allStats = try? modelContext.fetch(descriptor),
           let existing = allStats.first(where: { $0.songId == song.id }) {
            return existing
        }
        
        let newStats = SongPlayStatistics(songId: song.id)
        modelContext.insert(newStats)
        return newStats
    }
    
    /// Updates statistics for a song
    private func updateStatistics(for song: LibrarySong, duration: TimeInterval) {
        let stats = getOrCreateStatistics(for: song)
        stats.recordPlay(duration: duration)
    }
    
    // MARK: - Query Methods
    
    /// Gets play statistics for a song
    func getStatistics(for song: LibrarySong) -> SongPlayStatistics? {
        guard let modelContext = modelContext else { return nil }
        
        let descriptor = FetchDescriptor<SongPlayStatistics>()
        
        guard let allStats = try? modelContext.fetch(descriptor) else { return nil }
        return allStats.first(where: { $0.songId == song.id })
    }
    
    /// Gets recently played songs (unique, ordered by most recent)
    func getRecentlyPlayed(limit: Int = 20) -> [LibrarySong] {
        guard let modelContext = modelContext else { return [] }
        
        let descriptor = FetchDescriptor<ListeningHistory>(
            sortBy: [SortDescriptor(\.playedAt, order: .reverse)]
        )
        
        guard let history = try? modelContext.fetch(descriptor) else { return [] }
        
        // Get unique song IDs in order of most recent play
        var seenIds = Set<UUID>()
        var uniqueHistory: [ListeningHistory] = []
        
        for entry in history {
            if !seenIds.contains(entry.songId) {
                seenIds.insert(entry.songId)
                uniqueHistory.append(entry)
                if uniqueHistory.count >= limit {
                    break
                }
            }
        }
        
        // Map to songs
        let library = SongLibrary.shared
        return uniqueHistory.compactMap { entry in
            library.songs.first { $0.id == entry.songId }
        }
    }
    
    /// Gets most played songs
    func getMostPlayed(limit: Int = 20) -> [(song: LibrarySong, count: Int)] {
        guard let modelContext = modelContext else { return [] }
        
        let descriptor = FetchDescriptor<SongPlayStatistics>(
            sortBy: [SortDescriptor(\.playCount, order: .reverse)]
        )
        
        guard let stats = try? modelContext.fetch(descriptor) else { return [] }
        
        let library = SongLibrary.shared
        return stats.prefix(limit).compactMap { stat in
            guard let song = library.songs.first(where: { $0.id == stat.songId }) else { return nil }
            return (song: song, count: stat.playCount)
        }
    }
    
    /// Gets listening history for a specific time period
    func getHistory(from startDate: Date, to endDate: Date) -> [ListeningHistory] {
        guard let modelContext = modelContext else { return [] }
        
        // Fetch all and filter in memory to avoid predicate macro issues
        let descriptor = FetchDescriptor<ListeningHistory>(
            sortBy: [SortDescriptor(\.playedAt, order: .reverse)]
        )
        
        guard let allHistory = try? modelContext.fetch(descriptor) else { return [] }
        return allHistory.filter { $0.playedAt >= startDate && $0.playedAt <= endDate }
    }
    
    /// Gets total listening time
    func getTotalListeningTime() -> TimeInterval {
        guard let modelContext = modelContext else { return 0 }
        
        let descriptor = FetchDescriptor<SongPlayStatistics>()
        guard let stats = try? modelContext.fetch(descriptor) else { return 0 }
        
        return stats.reduce(0) { $0 + $1.totalPlayTime }
    }
    
    /// Gets listening time for a specific period
    func getListeningTime(from startDate: Date, to endDate: Date) -> TimeInterval {
        let history = getHistory(from: startDate, to: endDate)
        return history.reduce(0) { $0 + $1.playDuration }
    }
}
