//
//  LyricLine.swift
//  Ampwave
//

import Foundation

public struct LyricLine: Codable, Hashable {
  public var timestamp: TimeInterval
  public var text: String
  public var translation: String?

  public init(timestamp: TimeInterval, text: String, translation: String? = nil) {
    self.timestamp = timestamp
    self.text = text
    self.translation = translation
  }

  public var formattedTime: String {
    let minutes = Int(timestamp) / 60
    let seconds = Int(timestamp) % 60
    let milliseconds = Int((timestamp - Double(Int(timestamp))) * 100)
    return String(format: "%02d:%02d.%02d", minutes, seconds, milliseconds)
  }
}
