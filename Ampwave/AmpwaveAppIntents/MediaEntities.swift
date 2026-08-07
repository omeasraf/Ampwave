//
//  MediaEntities.swift
//  Ampwave
//
//  AppEntity wrappers for library content.
//
//  These exist so Siri can hear a title and resolve it. App Shortcut phrases
//  can only interpolate an AppEntity or AppEnum parameter — a `String`
//  parameter cannot appear in a phrase. That limitation is why the shortcuts
//  used to be phrased generically ("Play a song on Ampwave") and why anything
//  natural like "Play Landslide on Ampwave" matched nothing and fell through to
//  Siri's built-in media handling, which doesn't know about this app.
//

import AppIntents
import Foundation

// MARK: - Song

@available(iOS 17.0, macOS 14.0, *)
struct SongEntity: AppEntity, Identifiable {
  let id: UUID
  let title: String
  let artist: String

  static var typeDisplayRepresentation: TypeDisplayRepresentation = "Song"
  static var defaultQuery = SongEntityQuery()

  var displayRepresentation: DisplayRepresentation {
    DisplayRepresentation(title: "\(title)", subtitle: "\(artist)")
  }

  @MainActor
  init(_ song: LibrarySong) {
    self.id = song.id
    self.title = song.title
    self.artist = song.artist
  }
}

@available(iOS 17.0, macOS 14.0, *)
struct SongEntityQuery: EntityStringQuery {
  @MainActor
  func entities(for identifiers: [UUID]) async throws -> [SongEntity] {
    identifiers.compactMap { SongLibrary.shared.song(id: $0) }.map(SongEntity.init)
  }

  /// Resolves what the user actually said. Matching is deliberately loose —
  /// speech recognition rarely reproduces punctuation or bracketed suffixes.
  @MainActor
  func entities(matching string: String) async throws -> [SongEntity] {
    let needle = MediaMatch.normalize(string)
    guard !needle.isEmpty else { return [] }

    let scored = SongLibrary.shared.songs.compactMap { song -> (LibrarySong, Int)? in
      guard let score = MediaMatch.score(needle: needle, candidate: song.title) else { return nil }
      return (song, score)
    }

    return
      scored
      .sorted { $0.1 > $1.1 }
      .prefix(12)
      .map { SongEntity($0.0) }
  }

  @MainActor
  func suggestedEntities() async throws -> [SongEntity] {
    SongLibrary.shared.songs.prefix(20).map(SongEntity.init)
  }
}

// MARK: - Artist

@available(iOS 17.0, macOS 14.0, *)
struct ArtistEntity: AppEntity, Identifiable {
  let id: String
  let name: String

  static var typeDisplayRepresentation: TypeDisplayRepresentation = "Artist"
  static var defaultQuery = ArtistEntityQuery()

  var displayRepresentation: DisplayRepresentation {
    DisplayRepresentation(title: "\(name)")
  }
}

@available(iOS 17.0, macOS 14.0, *)
struct ArtistEntityQuery: EntityStringQuery {
  @MainActor
  func entities(for identifiers: [String]) async throws -> [ArtistEntity] {
    let known = Set(SongLibrary.shared.artists.map(\.name))
    return identifiers.filter { known.contains($0) }.map { ArtistEntity(id: $0, name: $0) }
  }

  @MainActor
  func entities(matching string: String) async throws -> [ArtistEntity] {
    let needle = MediaMatch.normalize(string)
    guard !needle.isEmpty else { return [] }

    return
      SongLibrary.shared.artists
      .compactMap { artist -> (String, Int)? in
        guard let score = MediaMatch.score(needle: needle, candidate: artist.name) else {
          return nil
        }
        return (artist.name, score)
      }
      .sorted { $0.1 > $1.1 }
      .prefix(12)
      .map { ArtistEntity(id: $0.0, name: $0.0) }
  }

  @MainActor
  func suggestedEntities() async throws -> [ArtistEntity] {
    SongLibrary.shared.artists.prefix(20).map { ArtistEntity(id: $0.name, name: $0.name) }
  }
}

// MARK: - Playlist

@available(iOS 17.0, macOS 14.0, *)
struct PlaylistEntity: AppEntity, Identifiable {
  let id: UUID
  let name: String

  static var typeDisplayRepresentation: TypeDisplayRepresentation = "Playlist"
  static var defaultQuery = PlaylistEntityQuery()

  var displayRepresentation: DisplayRepresentation {
    DisplayRepresentation(title: "\(name)")
  }
}

@available(iOS 17.0, macOS 14.0, *)
struct PlaylistEntityQuery: EntityStringQuery {
  @MainActor
  func entities(for identifiers: [UUID]) async throws -> [PlaylistEntity] {
    PlaylistManager.shared.playlists
      .filter { identifiers.contains($0.id) }
      .map { PlaylistEntity(id: $0.id, name: $0.name) }
  }

  @MainActor
  func entities(matching string: String) async throws -> [PlaylistEntity] {
    let needle = MediaMatch.normalize(string)
    guard !needle.isEmpty else { return [] }

    return
      PlaylistManager.shared.playlists
      .compactMap { playlist -> (Playlist, Int)? in
        guard let score = MediaMatch.score(needle: needle, candidate: playlist.name) else {
          return nil
        }
        return (playlist, score)
      }
      .sorted { $0.1 > $1.1 }
      .prefix(12)
      .map { PlaylistEntity(id: $0.0.id, name: $0.0.name) }
  }

  @MainActor
  func suggestedEntities() async throws -> [PlaylistEntity] {
    PlaylistManager.shared.playlists.map { PlaylistEntity(id: $0.id, name: $0.name) }
  }
}

// MARK: - Matching

enum MediaMatch {
  /// Lowercases, drops punctuation and bracketed suffixes like "(Remastered)",
  /// and collapses whitespace, so dictated text lines up with stored titles.
  static func normalize(_ text: String) -> String {
    let withoutBrackets = text.replacingOccurrences(
      of: #"\([^)]*\)|\[[^\]]*\]"#,
      with: " ",
      options: .regularExpression
    )
    let scalars = withoutBrackets.lowercased().unicodeScalars.map {
      CharacterSet.alphanumerics.contains($0) ? Character($0) : " "
    }
    return String(scalars).split(separator: " ").joined(separator: " ")
  }

  /// Higher is a better match; `nil` means no match at all.
  static func score(needle: String, candidate: String) -> Int? {
    let hay = normalize(candidate)
    guard !hay.isEmpty else { return nil }

    if hay == needle { return 100 }
    if hay.hasPrefix(needle) { return 80 }
    if hay.contains(needle) { return 60 }
    if needle.contains(hay) { return 50 }

    // Fall back to word overlap, which rescues partially-heard titles.
    let needleWords = Set(needle.split(separator: " "))
    let hayWords = Set(hay.split(separator: " "))
    let shared = needleWords.intersection(hayWords).count
    guard shared > 0 else { return nil }
    return 10 * shared
  }
}
