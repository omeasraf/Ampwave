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
    
    // A library reset or song cleanup can nullify every relationship while
    // leaving the station row itself behind. Such a station still renders a
    // Home card but opens to an empty list, so treat it as stale immediately.
    let activeExisting = existing.filter { !$0.orderedSongs.isEmpty }
    if !activeExisting.isEmpty {
      let now = Date()
      let needsRefresh = activeExisting.contains { station in
        now.timeIntervalSince(station.lastUpdated) > refreshThreshold
      }
      
      if !needsRefresh {
        return activeExisting.sorted { $0.name < $1.name }
      }
    }
    
    // Regenerate if empty or needs refresh
    return generateMixes(existing: existing)
  }

  private func generateMixes(existing: [RadioStation]) -> [RadioStation] {
    guard let context = modelContext else { return [] }
    
    var stations: [RadioStation] = []
    var reusedStationIDs = Set<UUID>()

    // RadioStationView can remain open while Home refreshes in the background.
    // Replacing rows detached the model still owned by that destination and
    // crashed the next SwiftUI render. Keep stable rows and update their
    // content instead.
    func updatedStation(
      name: String,
      subtitle: String,
      seedType: String,
      seedValue: String? = nil,
      songs: [LibrarySong],
      artworkPaths: [String],
      colors: [Color]
    ) -> RadioStation {
      let reusable = existing.first {
        !reusedStationIDs.contains($0.id)
          && $0.seedType == seedType
          && (seedType != "dailyMix" || $0.name == name)
      }

      if let reusable {
        reusable.name = name
        reusable.subtitle = subtitle
        reusable.seedType = seedType
        reusable.seedValue = seedValue
        reusable.songs = songs
        reusable.songOrder = songs.map(\.id)
        reusable.artworkPaths = artworkPaths
        reusable.colorHexes = colors.map { $0.toHexString() }
        reusable.lastUpdated = Date()
        reusedStationIDs.insert(reusable.id)
        return reusable
      }

      let station = RadioStation(
        name: name,
        subtitle: subtitle,
        seedType: seedType,
        seedValue: seedValue,
        songs: songs,
        artworkPaths: artworkPaths,
        colors: colors
      )
      context.insert(station)
      reusedStationIDs.insert(station.id)
      return station
    }

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
      guard !seeds.isEmpty else { continue }
      // Seed from several tracks in the genre rather than one. A single seed
      // made "Daily Mix" collapse into that seed artist's discography.
      let seedPool = Array(seeds.shuffled().prefix(5))
      let similar = engine.buildRadioQueue(seeds: seedPool, limit: 24)
      let queue = ([seedPool[0]] + similar).shuffledPreservingFirst()
      let station = updatedStation(
        name: "Daily Mix \(mixNumber)",
        subtitle: genreSubtitle(genre: genre, songs: seeds),
        seedType: "dailyMix",
        seedValue: genre,
        songs: queue,
        artworkPaths: fourArtworks(from: queue),
        colors: GenrePalette.gradient(for: genre)
      )
      stations.append(station)
      mixNumber += 1
    }

    // ── 2. Favorites Mix ────────────────────────────────────────────────────
    if let liked = playlistManager.likedSongsPlaylist, liked.songs.count >= 3 {
      let likedSongs = liked.songs.shuffled()
      let extras = engine.buildRadioQueue(seeds: Array(likedSongs.prefix(5)), limit: 20)
      // Interleaved and shuffled, not alphabetised — sorting by title turned
      // this into an A-to-Z list rather than a mix.
      var seenIds = Set<UUID>()
      let queue = Array(
        (likedSongs + extras)
          .filter { seenIds.insert($0.id).inserted }
          .shuffled()
          .prefix(25)
      )
      let station = updatedStation(
        name: "Favorites Mix",
        subtitle: "\(liked.songs.count) liked songs & more",
        seedType: "favorites",
        songs: queue,
        artworkPaths: fourArtworks(from: likedSongs),
        colors: [.pink, .red]
      )
      stations.append(station)
    }

    // ── 3. Discovery Mix ────────────────────────────────────────────────────
    let recentIds = Set(recentSongs.map(\.id))
    // Ranked by the discovery score (favours newly added, unplayed, un-skipped
    // tracks) instead of a plain shuffle, and never surfaces disliked songs.
    let unheard = engine.rankedForDiscovery(
      excluding: recentIds,
      limit: 25
    )
    if unheard.count >= 5 {
      let queue = unheard
      let station = updatedStation(
        name: "Discovery Mix",
        subtitle: "Fresh picks from your library",
        seedType: "discovery",
        songs: queue,
        artworkPaths: fourArtworks(from: queue),
        colors: [.blue, .cyan]
      )
      stations.append(station)
    }

    // Keep unused rows attached so an already-open destination remains safe.
    // Empty stations are excluded by fetchOrCreateMixes on future loads.
    for station in existing where !reusedStationIDs.contains(station.id) {
      station.songs = []
      station.songOrder = []
      station.artworkPaths = []
      station.lastUpdated = Date()
    }

    do {
      try context.save()
    } catch {
      print("[DEBUG] RadioMixGenerator: Failed to save generated stations: \(error)")
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

extension Array {
  /// Shuffles everything after the first element, so a mix still opens on its
  /// seed track but doesn't play out in ranked order.
  fileprivate func shuffledPreservingFirst() -> [Element] {
    guard count > 2 else { return self }
    return [self[0]] + self.dropFirst().shuffled()
  }
}
