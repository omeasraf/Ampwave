//
//  AmpwaveCapsule.swift
//  Ampwave
//
//  A personal, portable mixtape assembled from songs in the local library.
//

import Foundation
import SwiftData

@Model
final class AmpwaveCapsule: Identifiable, Hashable {
  @Attribute(.unique) var id: UUID
  var title: String
  var capsuleDescription: String?
  var personalMessage: String?
  var creatorName: String?
  var createdDate: Date
  var lastModifiedDate: Date
  var sourcePlaylistID: UUID?
  var songIDs: [UUID]
  var playExactlyAsCreated: Bool

  init(
    id: UUID = UUID(),
    title: String,
    description: String? = nil,
    personalMessage: String? = nil,
    creatorName: String? = nil,
    createdDate: Date = .now,
    sourcePlaylistID: UUID? = nil,
    songIDs: [UUID],
    playExactlyAsCreated: Bool = true
  ) {
    self.id = id
    self.title = title
    self.capsuleDescription = description
    self.personalMessage = personalMessage
    self.creatorName = creatorName
    self.createdDate = createdDate
    self.lastModifiedDate = createdDate
    self.sourcePlaylistID = sourcePlaylistID
    self.songIDs = songIDs
    self.playExactlyAsCreated = playExactlyAsCreated
  }

  var songCount: Int { songIDs.count }

  @MainActor
  func resolvedSongs(in library: SongLibrary) -> [LibrarySong] {
    let songsByID = Dictionary(uniqueKeysWithValues: library.songs.map { ($0.id, $0) })
    return songIDs.compactMap { songsByID[$0] }
  }

  @MainActor
  func totalDuration(in library: SongLibrary) -> TimeInterval {
    resolvedSongs(in: library).reduce(0) { $0 + $1.duration }
  }

  static func == (lhs: AmpwaveCapsule, rhs: AmpwaveCapsule) -> Bool {
    lhs.id == rhs.id
  }

  func hash(into hasher: inout Hasher) {
    hasher.combine(id)
  }
}
