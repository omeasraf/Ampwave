//
//  RuleField.swift
//  Ampwave
//

import Foundation

enum RuleField: String, Codable, CaseIterable {
  case title = "title"
  case artist = "artist"
  case album = "album"
  case genre = "genre"
  case year = "year"
  case playCount = "playCount"
  case skipCount = "skipCount"
  case lastPlayed = "lastPlayed"
  case dateAdded = "dateAdded"
  case rating = "rating"
  case duration = "duration"
  case liked = "liked"
}

extension RuleField {
  /// What kind of value this field compares, which decides both the operators
  /// offered in the UI and how the evaluator interprets `SmartRule.value`.
  enum ValueKind {
    case text
    case number
    case duration
    case days
    case boolean
  }

  var valueKind: ValueKind {
    switch self {
    case .title, .artist, .album, .genre: return .text
    case .year, .playCount, .skipCount, .rating: return .number
    case .duration: return .duration
    case .lastPlayed, .dateAdded: return .days
    case .liked: return .boolean
    }
  }

  var displayName: String {
    switch self {
    case .title:      return "Title"
    case .artist:     return "Artist"
    case .album:      return "Album"
    case .genre:      return "Genre"
    case .year:       return "Year"
    case .playCount:  return "Play Count"
    case .skipCount:  return "Skip Count"
    case .lastPlayed: return "Last Played"
    case .dateAdded:  return "Date Added"
    case .rating:     return "Rating"
    case .duration:   return "Duration"
    case .liked:      return "Loved"
    }
  }

  /// Operators that make sense for this field, most useful first.
  var validOperations: [RuleOperation] {
    switch valueKind {
    case .text:     return [.contains, .doesNotContain, .is_, .isNot]
    case .number,
         .duration: return [.greaterThan, .lessThan, .is_, .isNot]
    case .days:     return [.inTheLast, .notInTheLast, .greaterThan, .lessThan, .is_, .isNot]
    case .boolean:  return [.is_]
    }
  }

  var defaultOperation: RuleOperation {
    validOperations[0]
  }
}
