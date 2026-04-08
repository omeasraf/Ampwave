//
//  PlaylistSortOrder.swift
//  Ampwave
//

import Foundation

enum PlaylistSortOrder: String, Codable, CaseIterable {
    case manual = "manual"
    case title = "title"
    case artist = "artist"
    case album = "album"
    case recentlyAdded = "recentlyAdded"
    case recentlyPlayed = "recentlyPlayed"
}
