//
//  SiriPlaybackRouter.swift
//  Ampwave
//
//  Siri-first playback routing that prefers Apple Music catalog playback
//  and falls back to the local Ampwave library.
//

import Foundation
import MusicKit

@available(iOS 17.0, macOS 14.0, *)
enum SiriPlaybackRouterError: LocalizedError {
  case authorizationDenied
  case noPlayableMatch
  case musicSubscriptionUnavailable

  var errorDescription: String? {
    switch self {
    case .authorizationDenied:
      return "Ampwave needs Apple Music permission before Siri can search and play songs."
    case .noPlayableMatch:
      return "Ampwave couldn't find a playable match for that request."
    case .musicSubscriptionUnavailable:
      return "Ampwave found a catalog match, but Apple Music playback isn't available on this account."
    }
  }
}

@available(iOS 17.0, macOS 14.0, *)
@MainActor
final class SiriPlaybackRouter {
  static let shared = SiriPlaybackRouter()

  struct PlaybackResolution {
    let source: Source
    let matchedTitle: String
    let matchedArtist: String
    let confidence: Double

    enum Source: String {
      case appleMusic
      case localLibrary
    }
  }

  private let library = SongLibrary.shared
  private let musicPlayer = ApplicationMusicPlayer.shared

  private init() {}

  func playSong(songTitle: String, artistName: String? = nil) async throws -> PlaybackResolution {
    let title = songTitle.trimmingCharacters(in: .whitespacesAndNewlines)
    let artist = artistName?.trimmingCharacters(in: .whitespacesAndNewlines)

    guard !title.isEmpty else {
      throw SiriPlaybackRouterError.noPlayableMatch
    }

    if let catalogResult = try await resolveAppleMusicSong(songTitle: title, artistName: artist) {
      return try await playAppleMusic(catalogResult)
    }

    if let localResult = resolveLocalLibrarySong(songTitle: title, artistName: artist) {
      PlaybackController.shared.play(localResult.song, from: .search)
      return PlaybackResolution(
        source: .localLibrary,
        matchedTitle: localResult.song.title,
        matchedArtist: localResult.song.artist,
        confidence: localResult.confidence
      )
    }

    throw SiriPlaybackRouterError.noPlayableMatch
  }

  private func resolveAppleMusicSong(songTitle: String, artistName: String?) async throws
    -> AppleMusicSearchService.Match?
  {
    let status = MusicAuthorization.currentStatus
    let resolvedStatus = status == .notDetermined ? await MusicAuthorization.request() : status

    guard resolvedStatus == .authorized else {
      throw SiriPlaybackRouterError.authorizationDenied
    }

    return try await AppleMusicSearchService.shared.bestSongMatch(
      songTitle: songTitle,
      artistName: artistName
    )
  }

  private func playAppleMusic(_ match: AppleMusicSearchService.Match) async throws -> PlaybackResolution {
    let subscription = try await MusicSubscription.current
    guard subscription.canPlayCatalogContent else {
      throw SiriPlaybackRouterError.musicSubscriptionUnavailable
    }

    PlaybackController.shared.prepareForExternalPlayback()

    musicPlayer.queue = ApplicationMusicPlayer.Queue(
      for: [match.song],
      startingAt: match.song
    )
    try await musicPlayer.play()

    return PlaybackResolution(
      source: .appleMusic,
      matchedTitle: match.song.title,
      matchedArtist: match.song.artistName,
      confidence: match.confidence
    )
  }

  private func resolveLocalLibrarySong(songTitle: String, artistName: String?) -> (
    song: LibrarySong, confidence: Double
  )? {
    let normalizedTargetTitle = Self.normalize(songTitle)
    let normalizedTargetArtist = Self.normalize(artistName)

    let scoredSongs = library.songs.map { song -> (song: LibrarySong, confidence: Double) in
      let normalizedSongTitle = Self.normalize(song.title)
      let normalizedSongArtist = Self.normalize(song.artist)
      let titleScore = Self.stringScore(
        query: normalizedTargetTitle,
        candidate: normalizedSongTitle
      )
      let artistScore =
        normalizedTargetArtist.isEmpty
        ? 1.0
        : Self.stringScore(query: normalizedTargetArtist, candidate: normalizedSongArtist)
      let confidence = (titleScore * 0.50) + (artistScore * 0.30) + 0.20
      return (song: song, confidence: confidence)
    }

    return scoredSongs
      .filter { $0.confidence >= 0.75 }
      .max { lhs, rhs in lhs.confidence < rhs.confidence }
  }

  private static func normalize(_ value: String?) -> String {
    guard let value else { return "" }
    return
      value
      .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
      .lowercased()
      .replacingOccurrences(of: "[^a-z0-9 ]", with: " ", options: .regularExpression)
      .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
      .trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private static func stringScore(query: String, candidate: String) -> Double {
    guard !query.isEmpty, !candidate.isEmpty else { return 0 }
    if query == candidate { return 1.0 }
    if candidate.contains(query) || query.contains(candidate) { return 0.92 }

    let queryTokens = Set(query.split(separator: " ").map(String.init))
    let candidateTokens = Set(candidate.split(separator: " ").map(String.init))
    let sharedCount = queryTokens.intersection(candidateTokens).count
    let denominator = max(queryTokens.count, candidateTokens.count, 1)
    return Double(sharedCount) / Double(denominator)
  }
}
