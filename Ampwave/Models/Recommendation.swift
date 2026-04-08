//
//  Recommendation.swift
//  Ampwave
//

import Foundation

struct Recommendation: Identifiable {
    let id = UUID()
    let item: RecommendationItem
    let reason: RecommendationReason
    let confidence: Double // 0.0 to 1.0
    
    init(item: RecommendationItem, reason: RecommendationReason, confidence: Double) {
        self.item = item
        self.reason = reason
        self.confidence = confidence
    }
    
    var itemId: UUID? {
        switch item {
        case .song(let song): return song.id
        case .album(let album): return album.id
        case .artist(let artist): return artist.id
        case .playlist(let playlist): return playlist.id
        }
    }
    
    var itemName: String? {
        switch item {
        case .song(let song): return song.title
        case .album(let album): return album.name
        case .artist(let artist): return artist.name
        case .playlist(let playlist): return playlist.name
        }
    }
}
