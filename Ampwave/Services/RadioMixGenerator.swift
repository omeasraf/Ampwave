//
//  RadioMixGenerator.swift
//  Ampwave
//
//  Generates pre-built radio mixes for the Home screen (Daily Mix, Favorites Mix, Discovery Mix).
//

import Foundation
internal import SwiftUI

// MARK: - Model

struct RadioMix: Identifiable {
  let id: UUID
  let name: String
  let subtitle: String
  let songs: [LibrarySong]
  /// Up to 4 artwork paths for the 2×2 collage thumbnail.
  let artworkPaths: [String?]
  let gradientColors: [Color]

  init(
    name: String,
    subtitle: String,
    songs: [LibrarySong],
    artworkPaths: [String?],
    gradientColors: [Color]
  ) {
    self.id = UUID()
    self.name = name
    self.subtitle = subtitle
    self.songs = songs
    self.artworkPaths = artworkPaths
    self.gradientColors = gradientColors
  }
}

// MARK: - Generator

@MainActor
final class RadioMixGenerator {
  static let shared = RadioMixGenerator()
  private init() {}

  private var history: ListeningHistoryTracker { ListeningHistoryTracker.shared }
  private var library: SongLibrary { SongLibrary.shared }
  private var engine: RecommendationEngine { RecommendationEngine.shared }
  private var playlistManager: PlaylistManager { PlaylistManager.shared }

  // MARK: - Public API

  func generateMixes(limit: Int = 5) -> [RadioMix] {
    var mixes: [RadioMix] = []

    let recentSongs = history.getRecentlyPlayed(limit: 50)
    let mostPlayed = history.getMostPlayed(limit: 30).map(\.song)

    // De-duplicate while preserving order
    var seen = Set<UUID>()
    let historyPool = (recentSongs + mostPlayed).filter { seen.insert($0.id).inserted }

    // ── 1. Genre-based Daily Mixes ──────────────────────────────────────────
    let genreGroups = groupByPrimaryGenre(historyPool)
    let topGenres = genreGroups
      .sorted { $0.value.count > $1.value.count }
      .prefix(3)

    var mixNumber = 1
    for (genre, seeds) in topGenres {
      guard let seed = seeds.randomElement() else { continue }
      let similar = engine.buildRadioQueue(seed: seed, limit: 24)
      let queue = [seed] + similar
      mixes.append(RadioMix(
        name: "Daily Mix \(mixNumber)",
        subtitle: genreSubtitle(genre: genre, songs: seeds),
        songs: queue,
        artworkPaths: fourArtworks(from: queue),
        gradientColors: GenrePalette.gradient(for: genre)
      ))
      mixNumber += 1
    }

    // ── 2. Favorites Mix ────────────────────────────────────────────────────
    if let liked = playlistManager.likedSongsPlaylist, liked.songs.count >= 3 {
      let likedSongs = liked.songs.shuffled()
      let seed = likedSongs[0]
      let extras = engine.buildRadioQueue(seed: seed, limit: 20)
      let queue = Array(Set(likedSongs + extras)
        .sorted { $0.title < $1.title }
        .prefix(25))
      mixes.append(RadioMix(
        name: "Favorites Mix",
        subtitle: "\(liked.songs.count) liked songs & more",
        songs: queue,
        artworkPaths: fourArtworks(from: likedSongs),
        gradientColors: [.pink, .red]
      ))
    }

    // ── 3. Discovery Mix ────────────────────────────────────────────────────
    let recentIds = Set(recentSongs.map(\.id))
    let unheard = library.songs.filter { !recentIds.contains($0.id) }.shuffled()
    if unheard.count >= 5 {
      let queue = Array(unheard.prefix(25))
      mixes.append(RadioMix(
        name: "Discovery Mix",
        subtitle: "Fresh picks from your library",
        songs: queue,
        artworkPaths: fourArtworks(from: queue),
        gradientColors: [.blue, .cyan]
      ))
    }

    return Array(mixes.prefix(limit))
  }

  // MARK: - Helpers

  private func groupByPrimaryGenre(_ songs: [LibrarySong]) -> [String: [LibrarySong]] {
    var groups: [String: [LibrarySong]] = [:]
    for song in songs {
      guard let raw = song.genre, !raw.isEmpty else { continue }
      let primary = raw
        .components(separatedBy: CharacterSet(charactersIn: "/;,"))
        .first?
        .trimmingCharacters(in: .whitespacesAndNewlines) ?? raw
      guard !primary.isEmpty else { continue }
      groups[primary, default: []].append(song)
    }
    return groups
  }

  private func genreSubtitle(genre: String, songs: [LibrarySong]) -> String {
    let artists = Array(
      songs.reduce(into: NSMutableOrderedSet()) { $0.add($1.artist) }
        .array
        .compactMap { $0 as? String }
        .prefix(3)
    )
    return artists.isEmpty ? genre : artists.joined(separator: " • ")
  }

  private func fourArtworks(from songs: [LibrarySong]) -> [String?] {
    // Pick 4 unique artworks for the collage
    var used = Set<String>()
    var paths: [String?] = []
    for song in songs {
      let path = song.effectiveArtworkPath
      let key = path ?? "__nil__\(song.id)"
      if used.insert(key).inserted {
        paths.append(path)
      }
      if paths.count == 4 { break }
    }
    // Pad to 4 if needed
    while paths.count < 4 { paths.append(nil) }
    return paths
  }
}
