//
//  RecommendationItem.swift
//  Ampwave
//

import Foundation

enum RecommendationItem {
  case song(LibrarySong)
  case album(Album)
  case artist(Artist)
  case playlist(Playlist)
}
