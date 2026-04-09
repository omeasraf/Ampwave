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
}
