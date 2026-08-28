//
//  HomeSection.swift
//  Ampwave
//

import Foundation

/// The configurable shelves shown on Home. The raw values are persisted in
/// UserDefaults so changing the Home layout never requires a SwiftData migration.
enum HomeSection: String, CaseIterable, Identifiable {
  case recentlyPlayed
  case forYou
  case radioMixes
  case genrePicks
  case topSongs
  case recentlyAdded
  case quickAccess
  case rediscover

  static let orderKey = "com.ampwave.home.sectionOrder.v1"
  static let hiddenKey = "com.ampwave.home.hiddenSections.v1"
  static let greetingKey = "com.ampwave.home.showGreeting.v1"

  static let defaultOrder: [HomeSection] = [
    .recentlyPlayed,
    .forYou,
    .radioMixes,
    .genrePicks,
    .topSongs,
    .recentlyAdded,
    .quickAccess,
    .rediscover,
  ]

  static var defaultOrderRaw: String {
    encode(defaultOrder)
  }

  var id: String { rawValue }

  var title: String {
    switch self {
    case .recentlyPlayed: return "Recently Played"
    case .forYou: return "Made for You"
    case .radioMixes: return "Radio Mixes"
    case .genrePicks: return "Genre Picks"
    case .topSongs: return "Your Top Songs"
    case .recentlyAdded: return "Recently Added"
    case .quickAccess: return "Quick Access"
    case .rediscover: return "Rediscover"
    }
  }

  var systemImage: String {
    switch self {
    case .recentlyPlayed: return "clock.arrow.circlepath"
    case .forYou: return "sparkles"
    case .radioMixes: return "dot.radiowaves.left.and.right"
    case .genrePicks: return "square.grid.2x2"
    case .topSongs: return "chart.bar.fill"
    case .recentlyAdded: return "plus.rectangle.on.folder"
    case .quickAccess: return "bolt.fill"
    case .rediscover: return "arrow.counterclockwise"
    }
  }

  static func decode(_ raw: String) -> [HomeSection] {
    let saved = raw.split(separator: ",").compactMap { HomeSection(rawValue: String($0)) }
    var result: [HomeSection] = []

    // Preserve the saved order, discard duplicates, and append sections added
    // by a future app update so existing users do not silently lose them.
    for section in saved + defaultOrder where !result.contains(section) {
      result.append(section)
    }
    return result
  }

  static func encode(_ sections: [HomeSection]) -> String {
    sections.map(\.rawValue).joined(separator: ",")
  }

  static func hiddenSet(from raw: String) -> Set<HomeSection> {
    Set(raw.split(separator: ",").compactMap { HomeSection(rawValue: String($0)) })
  }
}
