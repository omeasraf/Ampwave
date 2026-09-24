// A metadata-only snapshot of the iPhone library for the Watch browser.
// No audio paths, credentials, or media bytes cross devices.
import Foundation

nonisolated struct WatchCatalogSnapshot: Codable, Equatable, Sendable {
  static let currentVersion = 1

  struct Song: Codable, Equatable, Sendable {
    let id: UUID
    let title: String
    let artist: String
    let album: String
    let duration: TimeInterval
  }

  struct Playlist: Codable, Equatable, Sendable {
    let id: UUID
    let name: String
    let songIDs: [UUID]
  }

  let version: Int
  let revision: TimeInterval
  let songs: [Song]
  let playlists: [Playlist]

  init(revision: TimeInterval, songs: [Song], playlists: [Playlist]) {
    version = Self.currentVersion
    self.revision = revision
    self.songs = songs
    self.playlists = playlists
  }
}
