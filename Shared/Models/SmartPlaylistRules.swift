//
//  SmartPlaylistRules.swift
//  Ampwave
//

import Foundation

struct SmartPlaylistRules: Codable, Equatable {
  var rules: [SmartRule]

  // Limit settings
  var limitEnabled: Bool
  var limitCount: Int
  var limitBy: LimitSort
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
