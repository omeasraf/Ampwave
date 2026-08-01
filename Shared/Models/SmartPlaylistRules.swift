//
//  SmartPlaylistRules.swift
//  Ampwave
//

import Foundation

/// How separate field groups combine with each other.
enum RuleMatchMode: String, Codable, Equatable, CaseIterable {
  case all = "all"
  case any = "any"

  var displayName: String {
    switch self {
    case .all: return "All"
    case .any: return "Any"
    }
  }
}

struct SmartPlaylistRules: Codable, Equatable {
  var rules: [SmartRule]

  // Limit settings
  var limitEnabled: Bool
  var limitCount: Int
  var limitBy: LimitSort

  /// Whether every field group must match, or just one of them.
  /// Defaults to `.all`, which is how grouping behaved before this was configurable.
  var matchMode: RuleMatchMode

  init(
    rules: [SmartRule],
    limitEnabled: Bool,
    limitCount: Int,
    limitBy: LimitSort,
    matchMode: RuleMatchMode = .all
  ) {
    self.rules = rules
    self.limitEnabled = limitEnabled
    self.limitCount = limitCount
    self.limitBy = limitBy
    self.matchMode = matchMode
  }

  // Playlists saved before `matchMode` existed decode without it, so it has to
  // be optional on the way in rather than a synthesised requirement.
  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    rules = try container.decodeIfPresent([SmartRule].self, forKey: .rules) ?? []
    limitEnabled = try container.decodeIfPresent(Bool.self, forKey: .limitEnabled) ?? false
    limitCount = try container.decodeIfPresent(Int.self, forKey: .limitCount) ?? 25
    limitBy = try container.decodeIfPresent(LimitSort.self, forKey: .limitBy) ?? .random
    matchMode = try container.decodeIfPresent(RuleMatchMode.self, forKey: .matchMode) ?? .all
  }
}

/// A single condition inside a smart playlist.
/// `connector` is ignored for the first rule; for subsequent rules it specifies
/// how this rule combines with the result so far (AND / OR).
struct SmartRule: Codable, Equatable {
  var connector: RuleConnector  // ignored for rule[0]
  var field: RuleField
  var operation: RuleOperation
  var value: String
}

enum RuleConnector: String, Codable, Equatable, CaseIterable {
  case and = "AND"
  case or = "OR"
}
