//
//  SmartPlaylistRules.swift
//  Ampwave
//

import Foundation

struct SmartPlaylistRules: Codable {
  var matchAll: Bool  // true = AND, false = OR
  var rules: [SmartRule]

  // Limit settings
  var limitEnabled: Bool
  var limitCount: Int
  var limitBy: LimitSort
}

struct SmartRule: Codable {
  var field: RuleField
  var operation: RuleOperation
  var value: String
}
