//
//  SyncedLyric.swift
//  Ampwave
//
//  Model for time-synced lyrics (LRC format).
//

import Foundation
import SwiftData

@Model
final class SyncedLyric: Identifiable {
  @Attribute(.unique) var id: UUID
  var songId: UUID

  var lines: [LyricLine]
  var source: LyricSource
  var language: String?

  var fetchedAt: Date
  var lastUpdated: Date

  init(songId: UUID, lines: [LyricLine], source: LyricSource = .local, language: String? = nil) {
    self.id = UUID()
    self.songId = songId
    self.lines = lines
    self.source = source
    self.language = language
    self.fetchedAt = Date()
    self.lastUpdated = Date()
  }

  func line(at time: TimeInterval) -> LyricLine? {
    guard let index = lineIndex(at: time) else { return nil }
    return lines[index]
  }

  func lineIndex(at time: TimeInterval) -> Int? {
    guard !lines.isEmpty, time >= lines[0].timestamp else { return nil }

    var lowerBound = 0
    var upperBound = lines.count
    while lowerBound < upperBound {
      let midpoint = lowerBound + (upperBound - lowerBound) / 2
      if lines[midpoint].timestamp <= time {
        lowerBound = midpoint + 1
      } else {
        upperBound = midpoint
      }
    }
    return lowerBound - 1
  }

  func nextLine(after time: TimeInterval) -> LyricLine? {
    let nextIndex = (lineIndex(at: time) ?? -1) + 1
    guard lines.indices.contains(nextIndex) else { return nil }
    return lines[nextIndex]
  }

  var hasLyrics: Bool {
    !lines.isEmpty
  }

  var plainText: String {
    lines.map { $0.text }.joined(separator: "\n")
  }
}
