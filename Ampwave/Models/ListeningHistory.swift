//
//  ListeningHistory.swift
//  Ampwave
//
//  SwiftData model for tracking listening history and play counts.
//  Used for recommendations and statistics.
//

import Foundation
import SwiftData

@Model
final class ListeningHistory: Identifiable {
  // MARK: - Identity
  @Attribute(.unique) var id: UUID

  // MARK: - Relationships
  var songId: UUID
  var songTitle: String
  var songArtist: String
  var songAlbum: String?

  // MARK: - Play Details
  var playedAt: Date
  var playDuration: TimeInterval  // How long the song was played
  var songDuration: TimeInterval  // Total song duration
  var completionPercentage: Double  // 0.0 to 1.0

  // MARK: - Context
  private var sourceRaw: String = "library"  // Persisted raw value for PlaySource
  @Transient
  var source: PlaySource {  // Where the song was played from
    get { PlaySource(rawValue: sourceRaw) ?? .library }
    set { sourceRaw = newValue.rawValue }
  }
  var playlistId: UUID?  // If played from a playlist

  @Transient
  init(
    song: LibrarySong,
    playDuration: TimeInterval,
    source: PlaySource = PlaySource.library,
    playlistId: UUID? = nil
  ) {
    self.id = UUID()
    self.songId = song.id
    self.songTitle = song.title
    self.songArtist = song.artist
    self.songAlbum = song.album
    self.playedAt = Date()
    self.playDuration = playDuration
    self.songDuration = song.duration
    self.completionPercentage = song.duration > 0 ? min(playDuration / song.duration, 1.0) : 0
    self.sourceRaw = source.rawValue
    self.playlistId = playlistId
  }

  /// Returns true if the song was played for more than 30 seconds or 50% of its duration
  var countsAsPlay: Bool {
    playDuration >= 30 || completionPercentage >= 0.5
  }
}
