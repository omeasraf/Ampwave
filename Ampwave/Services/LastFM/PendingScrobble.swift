//
//  PendingScrobble.swift
//  Ampwave
//
//  A play waiting to be submitted to Last.fm.
//
//  Scrobbles are queued rather than fired directly so a play is never lost to
//  a dropped connection, a rate limit, or the app being killed mid-request.
//  Last.fm accepts backdated scrobbles, so replaying the queue later is fine.
//

import Foundation
import SwiftData

@Model
final class PendingScrobble {
  @Attribute(.unique) var id: UUID
  var artist: String
  var track: String
  var album: String?
  var albumArtist: String?
  var durationSeconds: Int?
  var trackNumber: Int?
  /// Unix time the track started playing.
  var timestamp: Int
  var queuedAt: Date
  /// Bumped on each failed submission so a permanently-rejected scrobble
  /// eventually stops being retried instead of blocking the queue.
  var failureCount: Int

  init(
    artist: String,
    track: String,
    album: String? = nil,
    albumArtist: String? = nil,
    durationSeconds: Int? = nil,
    trackNumber: Int? = nil,
    timestamp: Int
  ) {
    self.id = UUID()
    self.artist = artist
    self.track = track
    self.album = album
    self.albumArtist = albumArtist
    self.durationSeconds = durationSeconds
    self.trackNumber = trackNumber
    self.timestamp = timestamp
    self.queuedAt = Date()
    self.failureCount = 0
  }
}
