//
//  RuleOperation.swift
//  Ampwave
//

import Foundation

enum RuleOperation: String, Codable, CaseIterable {
  case is_ = "is"
  case isNot = "isNot"
  case contains = "contains"
  case doesNotContain = "doesNotContain"
  case greaterThan = "greaterThan"
  case lessThan = "lessThan"
  case inTheLast = "inTheLast"
  case notInTheLast = "notInTheLast"
}

extension RuleOperation {
  var displayName: String {
    switch self {
    case .is_:            return "is"
    case .isNot:          return "is not"
    case .contains:       return "contains"
    case .doesNotContain: return "doesn't contain"
    case .greaterThan:    return "greater than"
    case .lessThan:       return "less than"
    case .inTheLast:      return "in the last"
    case .notInTheLast:   return "not in the last"
    }
  }
}
