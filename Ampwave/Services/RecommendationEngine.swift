//
//  RecommendationEngine.swift
//  Ampwave
//
//  Generates recommendations based on local library and listening history.
//  Fixed and improved recommendation algorithm.
//

import Foundation
import Observation
import SwiftData

@MainActor
@Observable
final class RecommendationEngine {
  static let shared = RecommendationEngine()

  var modelContext: ModelContext?
  private let library = SongLibrary.shared
  private let historyTracker = ListeningHistoryTracker.shared

  // Cached recommendations
  private(set) var forYouRecommendations: [Recommendation] = []
  private(set) var similarSongs: [Recommendation] = []
  private(set) var genreRecommendations: [Recommendation] = []
  private(set) var discoveryRecommendations: [Recommendation] = []

  private var lastGenerationTime: Date?
  private let cacheValidityDuration: TimeInterval = 300  // 5 minutes

  private init() {}

  func setModelContext(_ context: ModelContext) {
    self.modelContext = context
  }

  // MARK: - Generate All Recommendations

  func generateAllRecommendations(forceRefresh: Bool = false) async {
    // Check if cache is still valid
    if !forceRefresh,
      let lastTime = lastGenerationTime,
      Date().timeIntervalSince(lastTime) < cacheValidityDuration,
      !forYouRecommendations.isEmpty
    {
      return
    }

    // Ensure library is loaded
    if library.songs.isEmpty {
      await library.loadSongs()
    }

    // Only generate if we have songs
    guard !library.songs.isEmpty else {
      forYouRecommendations = []
      similarSongs = []
      genreRecommendations = []
      discoveryRecommendations = []
      return
    }

    async let forYou = generateForYouRecommendations()
    async let similar = generateSimilarSongs()
    async let genre = generateGenreRecommendations()
    async let discovery = generateDiscoveryRecommendations()

    let results = await (forYou, similar, genre, discovery)

    self.forYouRecommendations = results.0
    self.similarSongs = results.1
    self.genreRecommendations = results.2
    self.discoveryRecommendations = results.3

    lastGenerationTime = Date()
  }

  // MARK: - For You Recommendations

  /// Generates personalized "For You" recommendations
  /// Based on: listening history, liked songs, similar artists/genres
  func generateForYouRecommendations(limit: Int = 20) async -> [Recommendation] {
    let recentlyPlayed = historyTracker.getRecentlyPlayed(limit: 10)
    let mostPlayed = historyTracker.getMostPlayed(limit: 20)
    let likedSongs = await getLikedSongs() ?? []
    let favoriteGenres = extractGenres(from: recentlyPlayed + likedSongs + mostPlayed.map(\.song))
    let favoriteArtists = Set(
      recentlyPlayed.prefix(6).map(\.artist) + mostPlayed.prefix(10).map { $0.song.artist }
    )
    let recentIds = Set(recentlyPlayed.map(\.id))
    let nowPlayingId = PlaybackController.shared.currentItem?.id
    let statsBySongId = statisticsBySongID()

    let scoredCandidates = library.songs.compactMap {
      song -> (song: LibrarySong, score: Double, reason: RecommendationReason)? in
      guard song.id != nowPlayingId else { return nil }

      var score = baseRecommendationScore(for: song, statsBySongId: statsBySongId)
      var reason: RecommendationReason = .discovery

      if recentIds.contains(song.id) {
        score -= 2.8
      }

      let artistMatch = favoriteArtists.contains(song.artist)
      let genreOverlap = favoriteGenres.intersection(extractGenres(from: [song])).count

      if artistMatch {
        score += 2.2
        reason = .fromFavoriteArtist
      }

      if genreOverlap > 0 {
        score += Double(genreOverlap) * 1.2
        if reason == .discovery {
          reason = .basedOnGenres
        }
      }

      let similarity = similarityScore(for: song, references: recentlyPlayed)
      if similarity > 0 {
        score += similarity
        if similarity >= 1.3 {
          reason = .similarToRecent
        }
      }

      let freshnessDays = Date().timeIntervalSince(song.importedDate) / 86_400
      if freshnessDays <= 21 {
        score += max(0.15, 1.3 - freshnessDays / 14)
        if reason == .discovery {
          reason = .recentlyAdded
        }
      }

      if let stats = statsBySongId[song.id], stats.playCount > 12 {
        score -= min(1.4, Double(stats.playCount) / 18)
      }

      return score > 0.2 ? (song, score, reason) : nil
    }

    let selected = diversify(
      scoredCandidates.sorted { $0.score > $1.score },
      limit: limit
    )

    return selected.map {
      Recommendation(
        item: .song($0.song),
        reason: $0.reason,
        confidence: min(max($0.score / 7.5, 0.35), 0.98)
      )
    }
  }

  // MARK: - Radio Queue

  /// Builds a radio queue seeded by a single song — up to `limit` similar songs,
  /// excluding the seed itself. Call sites: PlaybackController.playRadio(from:).
  func buildRadioQueue(seed: LibrarySong, limit: Int = 25) -> [LibrarySong] {
    buildRadioQueue(seeds: [seed], limit: limit)
  }

  /// Radio from several seeds at once.
  ///
  /// A genre mix built off a single track degenerates into that one artist's
  /// discography, so callers with a pool of representative songs should pass
  /// all of them and let the scoring blend the result.
  func buildRadioQueue(seeds: [LibrarySong], limit: Int = 25) -> [LibrarySong] {
    guard !seeds.isEmpty else { return [] }
    return findSimilarSongs(to: seeds, exclude: seeds, limit: limit)
  }

  /// Library songs ranked for discovery — newly added, rarely played and
  /// un-skipped tracks first, disliked ones dropped entirely.
  ///
  /// Exposed so the Discovery mix can rank rather than plain-shuffle, which
  /// previously let disliked and heavily-skipped songs straight in.
  func rankedForDiscovery(excluding excludedIds: Set<UUID>, limit: Int) -> [LibrarySong] {
    let stats = statisticsBySongID()

    let candidates =
      library.songs
      .filter { !excludedIds.contains($0.id) && stats[$0.id]?.isDisliked != true }
      .map { song in
        (
          song: song,
          // Jitter keeps successive refreshes from being identical.
          score: discoveryScore(for: song, statsBySongId: stats) + Double.random(in: 0...0.6),
          reason: RecommendationReason.discovery
        )
      }
      .sorted { $0.score > $1.score }

    return diversify(candidates, limit: limit).map(\.song)
  }

  // MARK: - Similar Songs

  /// Finds songs similar to a given set of songs
  func generateSimilarSongs(limit: Int = 20) async -> [Recommendation] {
    let recentlyPlayed = historyTracker.getRecentlyPlayed(limit: 5)

    guard !recentlyPlayed.isEmpty else {
      // Fallback: return random songs from library
      return library.songs.shuffled().prefix(limit).map {
        Recommendation(
          item: .song($0),
          reason: .discovery,
          confidence: 0.5
        )
      }
    }

    let similarSongs = findSimilarSongs(to: recentlyPlayed, exclude: recentlyPlayed, limit: limit)

    return similarSongs.map {
      Recommendation(
        item: .song($0),
        reason: .similarToRecent,
        confidence: calculateSimilarityConfidence($0, to: recentlyPlayed)
      )
    }
  }

  /// Finds songs similar to reference songs based on multiple factors
  private func findSimilarSongs(
    to referenceSongs: [LibrarySong], exclude: [LibrarySong], limit: Int
  ) -> [LibrarySong] {
    let excludeIds = Set(exclude.map { $0.id })
    let referenceArtists = Set(referenceSongs.map { $0.artist })
    let referenceGenres = extractGenres(from: referenceSongs)
    let referenceAlbums = Set(referenceSongs.compactMap { $0.album })
    let referenceYears = referenceSongs.compactMap { $0.year }
    let stats = statisticsBySongID()

    var scoredSongs: [(song: LibrarySong, score: Double, reason: RecommendationReason)] = []

    for song in library.songs where !excludeIds.contains(song.id) {
      // A track the user explicitly disliked has no business turning up in a
      // queue they didn't hand-pick.
      if stats[song.id]?.isDisliked == true { continue }

      var score: Double = 0

      // Same artist bonus
      if referenceArtists.contains(song.artist) {
        score += 3.0
      }

      // Same album bonus (for finding other tracks from same album)
      if let album = song.album, referenceAlbums.contains(album) {
        score += 2.0
      }

      // Genre similarity
      let songGenres = extractGenres(from: [song])
      let commonGenres = referenceGenres.intersection(songGenres)
      score += Double(commonGenres.count) * 1.5

      // Closest reference year only. Summing over every reference meant a
      // large seed set could out-weigh artist and genre matches on era alone.
      if let songYear = song.year,
        let closestGap = referenceYears.map({ abs(songYear - $0) }).min(),
        closestGap <= 5
      {
        score += 1.0 - (Double(closestGap) * 0.15)
      }

      // Songs of a similar length are not musically similar; that heuristic
      // was adding noise, so it's gone.

      guard score > 0 else { continue }

      // Taste signals — plays, likes, ratings, skips. Radio previously ran on
      // metadata overlap alone, so how the user actually felt about a track
      // had no bearing on whether it turned up.
      score += baseRecommendationScore(for: song, statsBySongId: stats) * 0.6

      // Without a little jitter, the same seed produces a byte-identical queue
      // every single time, which is what makes the mixes feel static.
      score += Double.random(in: 0...0.9)

      scoredSongs.append((song, score, .similarToRecent))
    }

    // Sort by score, then cap per-artist/album so one prolific artist can't
    // swallow the whole queue.
    scoredSongs.sort { $0.score > $1.score }
    return diversify(scoredSongs, limit: limit).map(\.song)
  }

  // MARK: - Genre Recommendations

  /// Generates recommendations based on favorite genres
  func generateGenreRecommendations(limit: Int = 20) async -> [Recommendation] {
    let mostPlayed = historyTracker.getMostPlayed(limit: 20)

    guard !mostPlayed.isEmpty else {
      // Fallback: group by genre and return samples
      return generateFallbackGenreRecommendations(limit: limit)
    }

    let favoriteGenres = extractTopGenres(from: mostPlayed.map { $0.song }, top: 5)

    guard !favoriteGenres.isEmpty else {
      return generateFallbackGenreRecommendations(limit: limit)
    }

    var recommendations: [Recommendation] = []

    for (genre, count) in favoriteGenres {
      let genreSongs = library.songs.filter { song in
        extractGenres(from: [song]).contains(genre.lowercased())
      }.prefix(limit / favoriteGenres.count + 1)

      recommendations.append(
        contentsOf: genreSongs.map {
          Recommendation(
            item: .song($0),
            reason: .basedOnGenre(genre),
            confidence: min(0.9, 0.5 + Double(count) * 0.05)
          )
        })
    }

    return Array(recommendations.prefix(limit))
  }

  private func generateFallbackGenreRecommendations(limit: Int) -> [Recommendation] {
    // Group all songs by genre and return samples from each
    var genreGroups: [String: [LibrarySong]] = [:]

    for song in library.songs {
      if let genre = song.genre, !genre.isEmpty {
        let normalizedGenre = genre.lowercased()
        genreGroups[normalizedGenre, default: []].append(song)
      }
    }

    var recommendations: [Recommendation] = []
    let genres = Array(genreGroups.keys).sorted()

    for genre in genres {
      if let songs = genreGroups[genre]?.prefix(3) {
        recommendations.append(
          contentsOf: songs.map {
            Recommendation(
              item: .song($0),
              reason: .basedOnGenre(genre.capitalized),
              confidence: 0.6
            )
          })
      }
    }

    return Array(recommendations.shuffled().prefix(limit))
  }

  // MARK: - Discovery Recommendations

  /// Generates discovery recommendations (songs from less-played artists/genres)
  func generateDiscoveryRecommendations(limit: Int = 20) async -> [Recommendation] {
    let mostPlayed = historyTracker.getMostPlayed(limit: 30)
    let playedArtists = Set(mostPlayed.map { $0.song.artist })

    // Find songs from artists not in most played
    let statsBySongId = statisticsBySongID()
    let discoverySongs = library.songs
      .filter { song in
        !playedArtists.contains(song.artist) && (statsBySongId[song.id]?.skipCount ?? 0) < 4
      }
      .sorted {
        discoveryScore(for: $0, statsBySongId: statsBySongId)
          > discoveryScore(for: $1, statsBySongId: statsBySongId)
      }
      .prefix(limit)

    // If we don't have enough, include some from played artists too
    if discoverySongs.count < limit {
      let additionalSongs = library.songs
        .filter { playedArtists.contains($0.artist) }
        .shuffled()
        .prefix(limit - discoverySongs.count)

      return (discoverySongs + additionalSongs).map {
        Recommendation(
          item: .song($0),
          reason: playedArtists.contains($0.artist) ? .similarToRecent : .discovery,
          confidence: playedArtists.contains($0.artist) ? 0.6 : 0.5
        )
      }
    }

    return discoverySongs.map {
      Recommendation(
        item: .song($0),
        reason: .discovery,
        confidence: 0.5
      )
    }
  }

  // MARK: - Album Recommendations

  /// Recommends albums based on listening history
  func generateAlbumRecommendations(limit: Int = 10) async -> [Recommendation] {
    let recentlyPlayed = historyTracker.getRecentlyPlayed(limit: 20)
    let playedAlbums = Set(recentlyPlayed.compactMap { $0.album })

    // Find albums from same artists as recently played
    let recentArtists = Set(recentlyPlayed.map { $0.artist })

    var recommendations: [Recommendation] = []

    for album in library.albums {
      // Skip already played albums
      if playedAlbums.contains(album.name) { continue }

      var confidence: Double = 0

      // Same artist as recently played
      if let artist = album.artist, recentArtists.contains(artist) {
        confidence += 0.7
      }

      // Same genre as recently played
      let albumSongs = album.songs
      let albumGenres = extractGenres(from: albumSongs)
      let recentGenres = extractGenres(from: recentlyPlayed)
      let commonGenres = albumGenres.intersection(recentGenres)
      confidence += Double(commonGenres.count) * 0.15

      if confidence > 0.3 {
        recommendations.append(
          Recommendation(
            item: .album(album),
            reason: .similarToRecent,
            confidence: min(confidence, 0.9)
          ))
      }
    }

    // If we don't have enough, add random albums
    if recommendations.count < limit {
      let existingIds = Set(recommendations.compactMap { $0.itemId })
      let additionalAlbums = library.albums
        .filter { !existingIds.contains($0.id) && !playedAlbums.contains($0.name) }
        .shuffled()
        .prefix(limit - recommendations.count)

      recommendations.append(
        contentsOf: additionalAlbums.map {
          Recommendation(
            item: .album($0),
            reason: .discovery,
            confidence: 0.5
          )
        })
    }

    recommendations.sort { $0.confidence > $1.confidence }
    return Array(recommendations.prefix(limit))
  }

  // MARK: - Artist Recommendations

  /// Recommends artists based on listening history
  func generateArtistRecommendations(limit: Int = 10) async -> [Recommendation] {
    let mostPlayed = historyTracker.getMostPlayed(limit: 30)
    let topArtists = mostPlayed.map { $0.song.artist }

    // Get all artists
    let allArtists = await library.allArtists()

    var recommendations: [Recommendation] = []

    for artist in allArtists {
      // Skip already top artists
      if topArtists.contains(artist.name) { continue }

      var confidence: Double = 0

      // Check genre similarity with top artists
      if let artistGenres = artist.genres {
        for playedSong in mostPlayed.map({ $0.song }) {
          if let songGenre = playedSong.genre {
            for genre in artistGenres {
              if songGenre.lowercased().contains(genre.lowercased()) {
                confidence += 0.15
              }
            }
          }
        }
      }

      // Check if from same era as top artists
      let artistSongs = library.getSongs(byArtist: artist.name)
      let artistYears = artistSongs.compactMap { $0.year }
      let playedYears = mostPlayed.compactMap { $0.song.year }

      for year in artistYears {
        for playedYear in playedYears {
          if abs(year - playedYear) <= 5 {
            confidence += 0.1
          }
        }
      }

      if confidence > 0.2 {
        recommendations.append(
          Recommendation(
            item: .artist(artist),
            reason: .similarArtists,
            confidence: min(confidence, 0.85)
          ))
      }
    }

    // If we don't have enough, add random artists
    if recommendations.count < limit {
      let existingNames = Set(recommendations.compactMap { $0.itemName })
      let additionalArtists =
        allArtists
        .filter { !existingNames.contains($0.name) && !topArtists.contains($0.name) }
        .shuffled()
        .prefix(limit - recommendations.count)

      recommendations.append(
        contentsOf: additionalArtists.map {
          Recommendation(
            item: .artist($0),
            reason: .discovery,
            confidence: 0.5
          )
        })
    }

    recommendations.sort { $0.confidence > $1.confidence }
    return Array(recommendations.prefix(limit))
  }

  // MARK: - Playlist Recommendations

  /// Generates smart playlist recommendations
  func generatePlaylistRecommendations(for playlist: Playlist, limit: Int = 20) -> [Recommendation]
  {
    let playlistSongs = playlist.orderedSongs

    guard !playlistSongs.isEmpty else {
      return []
    }

    let similarSongs = findSimilarSongs(to: playlistSongs, exclude: playlistSongs, limit: limit)

    return similarSongs.map {
      Recommendation(
        item: .song($0),
        reason: .playlistBased,
        confidence: 0.75
      )
    }
  }

  // MARK: - Helper Methods

  private func getLikedSongs() async -> [LibrarySong]? {
    guard let modelContext = modelContext else { return nil }

    let descriptor = FetchDescriptor<SongPlayStatistics>(
      predicate: #Predicate { $0.isLiked == true }
    )

    guard let stats = try? modelContext.fetch(descriptor) else { return nil }
    let likedSongIds = Set(stats.map { $0.songId })

    return library.songs.filter { likedSongIds.contains($0.id) }
  }

  private func statisticsBySongID() -> [UUID: SongPlayStatistics] {
    guard let modelContext else { return [:] }
    let descriptor = FetchDescriptor<SongPlayStatistics>()
    let stats = (try? modelContext.fetch(descriptor)) ?? []
    return Dictionary(uniqueKeysWithValues: stats.map { ($0.songId, $0) })
  }

  private func extractGenres(from songs: [LibrarySong]) -> Set<String> {
    var genres: Set<String> = []
    for song in songs {
      if let genre = song.genre {
        // Split by common separators and normalize
        let parts = genre.split(separator: "/")
          .flatMap { $0.split(separator: ",") }
          .flatMap { $0.split(separator: ";") }

        for part in parts {
          let normalized = part.trimmingCharacters(in: .whitespaces).lowercased()
          if !normalized.isEmpty {
            genres.insert(normalized)
          }
        }
      }
    }
    return genres
  }

  private func extractTopGenres(from songs: [LibrarySong], top: Int) -> [(String, Int)] {
    var genreCounts: [String: Int] = [:]

    for song in songs {
      for genre in extractGenres(from: [song]) {
        genreCounts[genre, default: 0] += 1
      }
    }

    return genreCounts.sorted { $0.value > $1.value }
      .prefix(top)
      .map { ($0.key, $0.value) }
  }

  private func findSongsByGenres(_ genres: Set<String>, exclude: [LibrarySong], limit: Int)
    -> [LibrarySong]
  {
    let excludeIds = Set(exclude.map { $0.id })

    return library.songs.filter { song in
      guard !excludeIds.contains(song.id) else { return false }
      let songGenres = extractGenres(from: [song])
      return !songGenres.intersection(genres).isEmpty
    }.prefix(limit).map { $0 }
  }

  private func getRecentlyAddedSongs(exclude: [LibrarySong], limit: Int) -> [LibrarySong] {
    let excludeIds = Set(exclude.map { $0.id })

    return library.songs
      .filter { !excludeIds.contains($0.id) }
      .sorted { $0.importedDate > $1.importedDate }
      .prefix(limit)
      .map { $0 }
  }

  private func calculateSimilarityConfidence(_ song: LibrarySong, to referenceSongs: [LibrarySong])
    -> Double
  {
    var confidence: Double = 0.5

    let songArtists = song.artists.isEmpty ? [song.artist] : song.artists

    for refSong in referenceSongs {
      let refArtists = refSong.artists.isEmpty ? [refSong.artist] : refSong.artists

      // Check if any artist matches
      let hasArtistMatch = songArtists.contains { songArt in
        refArtists.contains { $0.lowercased() == songArt.lowercased() }
      }
      if hasArtistMatch {
        confidence += 0.2
      }

      if song.album == refSong.album {
        confidence += 0.15
      }
      if song.genre == refSong.genre {
        confidence += 0.1
      }
    }

    return min(confidence, 0.95)
  }

  private func removeDuplicates(from recommendations: [Recommendation]) -> [Recommendation] {
    var seenIds = Set<UUID>()
    return recommendations.filter { recommendation in
      guard let id = recommendation.itemId else { return true }
      if seenIds.contains(id) {
        return false
      }
      seenIds.insert(id)
      return true
    }
  }

  private func baseRecommendationScore(
    for song: LibrarySong,
    statsBySongId: [UUID: SongPlayStatistics]
  ) -> Double {
    var score = 0.5

    if let stats = statsBySongId[song.id] {
      score += min(Double(stats.playCount) * 0.08, 1.4)
      if stats.isLiked { score += 2.0 }
      if stats.isDisliked { score -= 2.5 }
      if let rating = stats.userRating {
        score += Double(rating - 3) * 0.65
      }
      score -= min(Double(stats.skipCount) * 0.35, 1.75)

      if let lastPlayedAt = stats.lastPlayedAt {
        let daysAgo = Date().timeIntervalSince(lastPlayedAt) / 86_400
        if daysAgo > 2 && daysAgo < 45 {
          score += min(daysAgo / 12, 1.2)
        }
      }
    } else {
      score += 0.8
    }

    return score
  }

  private func similarityScore(for song: LibrarySong, references: [LibrarySong]) -> Double {
    guard !references.isEmpty else { return 0 }

    var score = 0.0
    let songGenres = extractGenres(from: [song])

    for reference in references {
      if song.artist.caseInsensitiveCompare(reference.artist) == .orderedSame {
        score += 1.0
      }

      if song.album == reference.album, song.album != nil {
        score += 0.7
      }

      let overlap = songGenres.intersection(extractGenres(from: [reference])).count
      score += Double(overlap) * 0.45

      if let year = song.year, let referenceYear = reference.year {
        let distance = abs(year - referenceYear)
        if distance <= 4 {
          score += 0.35
        }
      }
    }

    return min(score, 2.2)
  }

  private func discoveryScore(
    for song: LibrarySong,
    statsBySongId: [UUID: SongPlayStatistics]
  ) -> Double {
    var score = 1.0
    let ageInDays = Date().timeIntervalSince(song.importedDate) / 86_400
    score += max(0, 1.2 - ageInDays / 30)
    if let stats = statsBySongId[song.id] {
      score -= Double(stats.playCount) * 0.04
      score -= Double(stats.skipCount) * 0.3
      if stats.isLiked { score += 0.6 }
      if let rating = stats.userRating {
        score += Double(rating - 3) * 0.18
      }
    }
    if song.effectiveArtworkPath != nil { score += 0.2 }
    if song.genre != nil { score += 0.15 }
    return score
  }

  private func diversify(
    _ candidates: [(song: LibrarySong, score: Double, reason: RecommendationReason)],
    limit: Int
  ) -> [(song: LibrarySong, score: Double, reason: RecommendationReason)] {
    var selected: [(song: LibrarySong, score: Double, reason: RecommendationReason)] = []
    var artistCounts: [String: Int] = [:]
    var albumCounts: [String: Int] = [:]
    var seenSongIDs = Set<UUID>()

    for candidate in candidates {
      guard !seenSongIDs.contains(candidate.song.id) else { continue }
      let artistCount = artistCounts[candidate.song.artist, default: 0]
      let albumKey = "\(candidate.song.artist)|\(candidate.song.album ?? "")"
      let albumCount = albumCounts[albumKey, default: 0]

      if artistCount >= 2 || albumCount >= 2 {
        continue
      }

      selected.append(candidate)
      seenSongIDs.insert(candidate.song.id)
      artistCounts[candidate.song.artist, default: 0] += 1
      albumCounts[albumKey, default: 0] += 1

      if selected.count == limit {
        return selected
      }
    }

    if selected.count < limit {
      for candidate in candidates where !seenSongIDs.contains(candidate.song.id) {
        selected.append(candidate)
        seenSongIDs.insert(candidate.song.id)
        if selected.count == limit {
          break
        }
      }
    }

    return selected
  }
}
