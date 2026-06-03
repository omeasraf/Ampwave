//
//  RadioMixGenerator.swift
//  Ampwave
//
//  Generates pre-built radio mixes for the Home screen (Daily Mix, Favorites Mix, Discovery Mix).
//

import Foundation
import SwiftData
internal import SwiftUI

// MARK: - Generator

@MainActor
final class RadioMixGenerator {
  static let shared = RadioMixGenerator()
  private init() {}

  var modelContext: ModelContext?
  private var history: ListeningHistoryTracker { ListeningHistoryTracker.shared }
  private var library: SongLibrary { SongLibrary.shared }
  private var engine: RecommendationEngine { RecommendationEngine.shared }
  private var playlistManager: PlaylistManager { PlaylistManager.shared }

  private let refreshThreshold: TimeInterval = 3 * 60 * 60 // 3 hours

  func setModelContext(_ context: ModelContext) {
    self.modelContext = context
  }

  // MARK: - Public API

  func fetchOrCreateMixes() -> [RadioStation] {
    guard let context = modelContext else { return [] }
    
    let descriptor = FetchDescriptor<RadioStation>()
    let existing = (try? context.fetch(descriptor)) ?? []
    
    // If we have existing stations, check if they need refresh
    if !existing.isEmpty {
      let now = Date()
      let needsRefresh = existing.contains { station in
        now.timeIntervalSince(station.lastUpdated) > refreshThreshold
      }
      
      if !needsRefresh {
        return existing.sorted { $0.name < $1.name }
      }
    }
    
    // Regenerate if empty or needs refresh
    return generateMixes(existing: existing)
  }

  private func generateMixes(existing: [RadioStation]) -> [RadioStation] {
    guard let context = modelContext else { return [] }
    
    // Clear existing if we are regenerating everything
    // Alternatively, we could update them in place, but clearing is simpler for this refactor.
    for station in existing {
      context.delete(station)
    }
    
    var stations: [RadioStation] = []
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
      let station = RadioStation(
        name: "Daily Mix \(mixNumber)",
        subtitle: genreSubtitle(genre: genre, songs: seeds),
        seedType: "dailyMix",
        seedValue: genre,
        songs: queue,
        artworkPaths: fourArtworks(from: queue),
        colors: GenrePalette.gradient(for: genre)
      )
      context.insert(station)
      stations.append(station)
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
      let station = RadioStation(
        name: "Favorites Mix",
        subtitle: "\(liked.songs.count) liked songs & more",
        seedType: "favorites",
        songs: queue,
        artworkPaths: fourArtworks(from: likedSongs),
        colors: [.pink, .red]
      )
      context.insert(station)
      stations.append(station)
    }

    // ── 3. Discovery Mix ────────────────────────────────────────────────────
    let recentIds = Set(recentSongs.map(\.id))
    let unheard = library.songs.filter { !recentIds.contains($0.id) }.shuffled()
    if unheard.count >= 5 {
      let queue = Array(unheard.prefix(25))
      let station = RadioStation(
        name: "Discovery Mix",
        subtitle: "Fresh picks from your library",
        seedType: "discovery",
        songs: queue,
        artworkPaths: fourArtworks(from: queue),
        colors: [.blue, .cyan]
      )
      context.insert(station)
      stations.append(station)
    }

    return stations
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

  private func fourArtworks(from songs: [LibrarySong]) -> [String] {
    // Pick 4 unique artworks for the collage
    var used = Set<String>()
    var paths: [String] = []
    for song in songs {
      if let path = song.effectiveArtworkPath {
        if used.insert(path).inserted {
          paths.append(path)
        }
      }
      if paths.count == 4 { break }
    }
    return paths
  }
}
