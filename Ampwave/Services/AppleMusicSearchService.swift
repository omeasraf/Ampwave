//
//  AppleMusicSearchService.swift
//  Ampwave
//
//  Resolves Apple Music catalog songs for Siri playback.
//

import Foundation
import MusicKit

@available(iOS 17.0, macOS 14.0, *)
actor AppleMusicSearchService {
  static let shared = AppleMusicSearchService()

  struct Match: Sendable {
    let song: Song
    let confidence: Double
  }

  private init() {}

  func bestSongMatch(
    songTitle: String,
    artistName: String? = nil,
    albumTitle: String? = nil,
    duration: TimeInterval? = nil
  ) async throws -> Match? {
    let trimmedSong = songTitle.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmedSong.isEmpty else { return nil }

    let termParts = [trimmedSong, artistName, albumTitle]
      .compactMap { value -> String? in
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
      }

    var request = MusicCatalogSearchRequest(
      term: termParts.joined(separator: " "),
      types: [Song.self]
    )
    request.limit = 10

    let response = try await request.response()
    let normalizedTargetTitle = Self.normalize(trimmedSong)
    let normalizedTargetArtist = Self.normalize(artistName)
    let normalizedTargetAlbum = Self.normalize(albumTitle)

    let scoredSongs = response.songs.compactMap { song -> Match? in
      let confidence = Self.score(
        candidate: song,
        title: normalizedTargetTitle,
        artist: normalizedTargetArtist,
        album: normalizedTargetAlbum,
        duration: duration
      )

      guard confidence >= 0.75 else { return nil }
      return Match(song: song, confidence: confidence)
    }

    return scoredSongs.max { lhs, rhs in
      lhs.confidence < rhs.confidence
    }
  }

  private static func score(
    candidate: Song,
    title: String,
    artist: String?,
    album: String?,
    duration: TimeInterval?
  ) -> Double {
    let titleScore = stringScore(query: title, candidate: normalize(candidate.title))
    let artistScore =
      artist.map { stringScore(query: $0, candidate: normalize(candidate.artistName)) } ?? 1.0
    let albumScore =
      album.map { stringScore(query: $0, candidate: normalize(candidate.albumTitle)) } ?? 1.0
    let durationScore =
      duration.map { scoreDuration(expected: $0, actual: candidate.duration) } ?? 1.0

    return (titleScore * 0.50)
      + (artistScore * 0.30)
      + (durationScore * 0.10)
      + (albumScore * 0.10)
  }

  private static func stringScore(query: String, candidate: String) -> Double {
    guard !query.isEmpty, !candidate.isEmpty else { return 0 }
    if query == candidate { return 1.0 }
    if candidate.contains(query) || query.contains(candidate) { return 0.92 }

    let queryTokens = Set(query.split(separator: " ").map(String.init))
    let candidateTokens = Set(candidate.split(separator: " ").map(String.init))
    let sharedCount = queryTokens.intersection(candidateTokens).count
    let denominator = max(queryTokens.count, candidateTokens.count, 1)
    let tokenOverlap = Double(sharedCount) / Double(denominator)

    let distance = levenshteinDistance(query, candidate)
    let scale = max(query.count, candidate.count, 1)
    let editSimilarity = 1.0 - (Double(distance) / Double(scale))

    return max(tokenOverlap, editSimilarity)
  }

  private static func scoreDuration(expected: TimeInterval, actual: TimeInterval?) -> Double {
    guard let actual, expected > 0, actual > 0 else { return 0 }
    let delta = abs(expected - actual)
    if delta <= 2 { return 1.0 }
    if delta <= 5 { return 0.9 }
    if delta <= 10 { return 0.75 }
    if delta <= 20 { return 0.45 }
    return 0
  }

  private static func normalize(_ value: String?) -> String {
    guard let value else { return "" }
    let normalized =
      value
      .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
      .lowercased()
      .replacingOccurrences(of: "[^a-z0-9 ]", with: " ", options: .regularExpression)
      .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
      .trimmingCharacters(in: .whitespacesAndNewlines)
    return normalized
  }

  private static func levenshteinDistance(_ lhs: String, _ rhs: String) -> Int {
    let lhsScalars = Array(lhs)
    let rhsScalars = Array(rhs)

    if lhsScalars.isEmpty { return rhsScalars.count }
    if rhsScalars.isEmpty { return lhsScalars.count }

    var previous = Array(0...rhsScalars.count)

    for (lhsIndex, lhsCharacter) in lhsScalars.enumerated() {
      var current = [lhsIndex + 1]

      for (rhsIndex, rhsCharacter) in rhsScalars.enumerated() {
        let insertion = current[rhsIndex] + 1
        let deletion = previous[rhsIndex + 1] + 1
        let substitution = previous[rhsIndex] + (lhsCharacter == rhsCharacter ? 0 : 1)
        current.append(min(insertion, deletion, substitution))
      }

      previous = current
    }

    return previous.last ?? 0
  }
}
