//
//  LibrarySortOrder.swift
//  Ampwave
//

import Foundation

enum LibrarySortOrder: String, Codable, CaseIterable {
  case titleAscending = "Title (A-Z)"
  case titleDescending = "Title (Z-A)"
  case artistAscending = "Artist (A-Z)"
  case artistDescending = "Artist (Z-A)"
  case dateAddedDescending = "Last Added"
  case dateAddedAscending = "Oldest Added"
  case yearDescending = "Year (Newest)"
  case yearAscending = "Year (Oldest)"
  case ratingDescending = "Rating (Highest)"
  case ratingAscending = "Rating (Lowest)"
  case random = "Random"

  var icon: String {
    switch self {
    case .titleAscending, .artistAscending, .yearAscending, .dateAddedAscending, .ratingAscending:
      return "arrow.up"
    case .titleDescending, .artistDescending, .yearDescending, .dateAddedDescending, .ratingDescending:
      return "arrow.down"
    case .random:
      return "shuffle"
    }
  }
}
