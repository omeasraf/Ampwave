//
//  PlaybackState.swift
//  Ampwave
//
//  Persistent playback state for app restarts.
//

import Foundation
import SwiftData

@Model
final class PlaybackState: Identifiable {
  @Attribute(.unique) var id: UUID

  var lastSongId: UUID?
  var lastTime: TimeInterval
  var lastQueueIds: [UUID]
  var lastQueueIndex: Int
  var lastSourceRaw: String?
  var lastPlaylistId: UUID?

  init(
    lastSongId: UUID? = nil,
    lastTime: TimeInterval = 0,
    lastQueueIds: [UUID] = [],
    lastQueueIndex: Int = 0,
    lastSourceRaw: String? = nil,
    lastPlaylistId: UUID? = nil
  ) {
    self.id = UUID()
    self.lastSongId = lastSongId
    self.lastTime = lastTime
    self.lastQueueIds = lastQueueIds
    self.lastQueueIndex = lastQueueIndex
    self.lastSourceRaw = lastSourceRaw
    self.lastPlaylistId = lastPlaylistId
  }

  static func getOrCreate(in modelContext: ModelContext) -> PlaybackState {
    do {
      var descriptor = FetchDescriptor<PlaybackState>()
      descriptor.fetchLimit = 1
      if let existing = try modelContext.fetch(descriptor).first {
        return existing
      }
    } catch {}

    let newState = PlaybackState()
    modelContext.insert(newState)
    try? modelContext.save()
    return newState
  }
}
