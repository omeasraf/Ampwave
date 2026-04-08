//
//  RecommendationSource.swift
//  Ampwave
//

import Foundation

enum RecommendationSource: String, Codable, CaseIterable {
    case listeningHistory = "listeningHistory"
    case genres = "genres"
    case similarArtists = "similarArtists"
    case recentlyAdded = "recentlyAdded"
}
