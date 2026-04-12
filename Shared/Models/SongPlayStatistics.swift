//
//  SongPlayStatistics.swift
//  Ampwave
//

import Foundation
import SwiftData

@Model
final class SongPlayStatistics: Identifiable {
  // MARK: - Identity
  @Attribute(.unique) var id: UUID
  var songId: UUID

  // MARK: - Statistics
  var playCount: Int
  var totalPlayTime: TimeInterval
  var lastPlayedAt: Date?
  var firstPlayedAt: Date?
  var skipCount: Int

  // MARK: - User Ratings
  var userRating: Int?  // 1-5 stars
  var isLiked: Bool
  var isDisliked: Bool

  @Transient
  init(songId: UUID) {
    self.id = UUID()
    self.songId = songId
    self.playCount = 0
    self.totalPlayTime = 0
    self.skipCount = 0
    self.isLiked = false
    self.isDisliked = false
  }

  /// Records a play
  func recordPlay(duration: TimeInterval) {
    playCount += 1
    totalPlayTime += duration
    lastPlayedAt = Date()
    if firstPlayedAt == nil {
      firstPlayedAt = Date()
    }
  }

  /// Records a skip
  func recordSkip() {
    skipCount += 1
  }

  /// Toggles like status
  func toggleLike() {
    isLiked.toggle()
    if isLiked {
      isDisliked = false
    }
  }
}
