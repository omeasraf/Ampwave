//
//  RuleField.swift
//  Ampwave
//

import Foundation

enum RuleField: String, Codable, CaseIterable {
  case artist = "artist"
  case album = "album"
  case genre = "genre"
  case year = "year"
  case playCount = "playCount"
  case lastPlayed = "lastPlayed"
  case rating = "rating"
  case duration = "duration"
}
