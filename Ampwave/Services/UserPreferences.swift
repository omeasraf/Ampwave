//
//  UserPreferences.swift
//  Ampwave
//
//  User preferences and app settings.
//

import Foundation
import SwiftData

@Model
final class UserPreferences: Identifiable {
    @Attribute(.unique) var id: UUID
    
    var crossfadeEnabled: Bool
    var crossfadeDuration: Double
    var gaplessPlayback: Bool
    var normalizeVolume: Bool
    var defaultShuffleModeRaw: String
    var defaultRepeatModeRaw: String
    
    var showNowPlayingOnLaunch: Bool
    var expandPlayerAutomatically: Bool
    var showLyricsByDefault: Bool
    var artworkQualityRaw: String
    
    var autoFetchMetadata: Bool
    var autoFetchLyrics: Bool
    var preferOnlineArtwork: Bool
    var organizeByAlbum: Bool
    
    var isOfflineMode: Bool
    var lastSyncDate: Date?
    
    var showPlaybackNotifications: Bool
    var showLyricsNotifications: Bool
    
    var enableRecommendations: Bool
    var recommendationSourcesRaw: [String]
    
    var defaultShuffleMode: ShuffleMode {
        get { ShuffleMode(rawValue: defaultShuffleModeRaw) ?? .off }
        set { defaultShuffleModeRaw = newValue.rawValue }
    }
    
    var defaultRepeatMode: RepeatMode {
        get { RepeatMode(rawValue: defaultRepeatModeRaw) ?? .off }
        set { defaultRepeatModeRaw = newValue.rawValue }
    }
    
    var artworkQuality: ArtworkQuality {
        get { ArtworkQuality(rawValue: artworkQualityRaw) ?? .high }
        set { artworkQualityRaw = newValue.rawValue }
    }
    
    var recommendationSources: [RecommendationSource] {
        get { recommendationSourcesRaw.compactMap { RecommendationSource(rawValue: $0) } }
        set { recommendationSourcesRaw = newValue.map { $0.rawValue } }
    }
    
    init() {
        self.id = UUID()
        self.crossfadeEnabled = false
        self.crossfadeDuration = 2.0
        self.gaplessPlayback = true
        self.normalizeVolume = false
        self.defaultShuffleModeRaw = ShuffleMode.off.rawValue
        self.defaultRepeatModeRaw = RepeatMode.off.rawValue
        self.showNowPlayingOnLaunch = false
        self.expandPlayerAutomatically = false
        self.showLyricsByDefault = false
        self.artworkQualityRaw = ArtworkQuality.high.rawValue
        self.autoFetchMetadata = true
        self.autoFetchLyrics = true
        self.preferOnlineArtwork = true
        self.organizeByAlbum = true
        self.isOfflineMode = false
        self.showPlaybackNotifications = true
        self.showLyricsNotifications = false
        self.enableRecommendations = true
        self.recommendationSourcesRaw = [RecommendationSource.listeningHistory.rawValue, RecommendationSource.genres.rawValue, RecommendationSource.similarArtists.rawValue]
    }
    
    static func getOrCreate(in modelContext: ModelContext) -> UserPreferences {
        do {
            var descriptor = FetchDescriptor<UserPreferences>()
            descriptor.fetchLimit = 1
            if let existing = try modelContext.fetch(descriptor).first {
                return existing
            }
        } catch { }
        
        let newPreferences = UserPreferences()
        modelContext.insert(newPreferences)
        try? modelContext.save()
        return newPreferences
    }
}
