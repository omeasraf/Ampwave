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

  /// Unsynced lyric text, kept alongside the synced lines rather than instead
  /// of them. Every representation a provider gives us is stored, so changing
  /// the word-synced preference is a display decision, not a refetch.
  var plainLyrics: String?

  var fetchedAt: Date
  var lastUpdated: Date

  /// When we last *asked* the online providers, as opposed to when the content
  /// last changed. Kept separate from `lastUpdated` so a song whose lyrics
  /// simply don't exist upstream still records the attempt and stops being
  /// re-requested on every play.
  var lastFetchAttemptAt: Date?

  init(
    songId: UUID,
    lines: [LyricLine],
    source: LyricSource = .local,
    language: String? = nil,
    plainLyrics: String? = nil
  ) {
    self.id = UUID()
    self.songId = songId
    self.lines = lines
    self.source = source
    self.language = language
    self.plainLyrics = plainLyrics
    self.fetchedAt = Date()
    self.lastUpdated = Date()
  }

  /// True when at least one line carries per-word timings.
  var hasWordSync: Bool {
    lines.contains { ($0.wordOffsets?.count ?? 0) > 1 }
  }

  /// True when we have timestamped lines to follow along with.
  var hasLineSync: Bool { !lines.isEmpty }

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

  /// Best available unsynced text: the provider's own plain copy when we have
  /// one, otherwise flattened from the synced lines.
  var plainText: String {
    if let plainLyrics, !plainLyrics.isEmpty { return plainLyrics }
    return lines.map { $0.text }.joined(separator: "\n")
  }
}
