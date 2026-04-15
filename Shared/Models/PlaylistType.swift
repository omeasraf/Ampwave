//
//  PlaylistType.swift
//  Ampwave
//

import Foundation

enum PlaylistType: String, Codable, CaseIterable {
  case custom = "custom"
  case likedSongs = "likedSongs"
  case recentlyPlayed = "recentlyPlayed"
  case mostPlayed = "mostPlayed"
  case smart = "smart"
}
