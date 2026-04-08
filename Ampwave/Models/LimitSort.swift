//
//  LimitSort.swift
//  Ampwave
//

import Foundation

enum LimitSort: String, Codable, CaseIterable {
    case random = "random"
    case recentlyAdded = "recentlyAdded"
    case recentlyPlayed = "recentlyPlayed"
    case mostPlayed = "mostPlayed"
    case alphabetical = "alphabetical"
}
