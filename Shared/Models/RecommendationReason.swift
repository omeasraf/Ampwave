//
//  RecommendationReason.swift
//  Ampwave
//

import Foundation

enum RecommendationReason {
  case similarToRecent
  case fromFavoriteArtist
  case basedOnGenres
  case basedOnGenre(String)
  case recentlyAdded
  case discovery
  case similarArtists
  case playlistBased
  case trending
  case becauseYouListenedTo(String)
  case heavyRotation
}

extension RecommendationReason {
  var displayText: String {
    switch self {
    case .similarToRecent:
      return "Similar to what you've been listening to"
    case .fromFavoriteArtist:
      return "From your favorite artists"
    case .basedOnGenres:
      return "Based on your favorite genres"
    case .basedOnGenre(let genre):
      return "\(genre.capitalized)"
    case .recentlyAdded:
      return "Recently added to your library"
    case .discovery:
      return "Discover something new"
    case .similarArtists:
      return "Similar artists"
    case .playlistBased:
      return "Based on this playlist"
    case .trending:
      return "Trending in your library"
    case .becauseYouListenedTo(let item):
      return "Because you listened to \(item)"
    case .heavyRotation:
      return "On heavy rotation"
    }
  }
}
