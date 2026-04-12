//
//  PlaySource.swift
//  Ampwave
//

import Foundation

enum PlaySource: String, Codable, Sendable, CaseIterable {
  case library
  case album
  case playlist
  case search
  case recommendation
  case radio
}
