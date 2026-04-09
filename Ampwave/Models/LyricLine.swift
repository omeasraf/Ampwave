//
//  LyricLine.swift
//  Ampwave
//

import Foundation

struct LyricLine: Codable, Hashable {
  var timestamp: TimeInterval
  var text: String
  var translation: String?

  init(timestamp: TimeInterval, text: String, translation: String? = nil) {
    self.timestamp = timestamp
    self.text = text
    self.translation = translation
  }

  var formattedTime: String {
    let minutes = Int(timestamp) / 60
    let seconds = Int(timestamp) % 60
    let milliseconds = Int((timestamp - Double(Int(timestamp))) * 100)
    return String(format: "%02d:%02d.%02d", minutes, seconds, milliseconds)
  }
}
