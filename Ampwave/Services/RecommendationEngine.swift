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
    var recommendations: [Recommendation] = []

    // Get recently played songs (mix of familiar and new)
    let recentlyPlayed = historyTracker.getRecentlyPlayed(limit: 10)

    // Get most played songs (top 20)
    let mostPlayed = historyTracker.getMostPlayed(limit: 20)

    // 1. Find songs similar to recently played
    if !recentlyPlayed.isEmpty {
      let similarToRecent = findSimilarSongs(to: recentlyPlayed, exclude: recentlyPlayed, limit: 5)
      recommendations.append(
        contentsOf: similarToRecent.map {
          Recommendation(
            item: .song($0),
            reason: .similarToRecent,
            confidence: 0.85
          )
        })
    }

    // 2. Heavy rotation: Songs played many times
    if !mostPlayed.isEmpty {
      let heavyRotation = mostPlayed.prefix(10).map { $0.song }
      recommendations.append(
        contentsOf: heavyRotation.map {
          Recommendation(
            item: .song($0),
            reason: .heavyRotation,
            confidence: 0.9
          )
        })

      // Also find more from these artists
      let topArtists = Set(mostPlayed.prefix(5).map { $0.song.artist })
      let fromFavoriteArtists = library.songs.filter { song in
        topArtists.contains(song.artist) && !recentlyPlayed.contains(where: { $0.id == song.id })
      }.prefix(5)
      recommendations.append(
        contentsOf: fromFavoriteArtists.map {
          Recommendation(
            item: .song($0),
            reason: .fromFavoriteArtist,
            confidence: 0.8
          )
        })
    }

    // 3. Find songs from same genres as liked songs
    if let likedSongs = await getLikedSongs(), !likedSongs.isEmpty {
      let likedGenres = extractGenres(from: likedSongs)
      if !likedGenres.isEmpty {
        let genreMatches = findSongsByGenres(likedGenres, exclude: recentlyPlayed, limit: 5)
        recommendations.append(
          contentsOf: genreMatches.map {
            Recommendation(
              item: .song($0),
              reason: .basedOnGenres,
              confidence: 0.7
            )
          })
      }
    }

    // 4. Add some recently added songs
    let recentlyAdded = getRecentlyAddedSongs(exclude: recentlyPlayed, limit: 3)
    recommendations.append(
      contentsOf: recentlyAdded.map {
        Recommendation(
          item: .song($0),
          reason: .recentlyAdded,
          confidence: 0.6
        )
      })

    // 5. Add some random songs from library for variety (if we don't have enough)
    if recommendations.count < limit {
      let existingIds = Set(recommendations.compactMap { $0.itemId })
      let randomSongs = library.songs
        .filter {
          !existingIds.contains($0.id) && !recentlyPlayed.contains(where: { $0.id == $0.id })
        }
        .shuffled()
        .prefix(limit - recommendations.count)

      recommendations.append(
        contentsOf: randomSongs.map {
          Recommendation(
            item: .song($0),
            reason: .discovery,
            confidence: 0.5
          )
        })
    }

    // Sort by confidence and remove duplicates
    let uniqueRecommendations = removeDuplicates(from: recommendations)
    return Array(uniqueRecommendations.prefix(limit))
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

    var scoredSongs: [(song: LibrarySong, score: Double)] = []

    for song in library.songs where !excludeIds.contains(song.id) {
      var score: Double = 0

      // Same artist bonus
      if referenceArtists.contains(song.artist) {
        score += 3.0
      }

      // Same album bonus (for finding other tracks from same album)
      if let album = song.album, referenceAlbums.contains(album) {
        score += 2.5
      }

      // Genre similarity
      let songGenres = extractGenres(from: [song])
      let commonGenres = referenceGenres.intersection(songGenres)
      score += Double(commonGenres.count) * 1.5

      // Similar release year (within 5 years)
      if let songYear = song.year {
        for refSong in referenceSongs {
          if let refYear = refSong.year {
            let yearDiff = abs(songYear - refYear)
            if yearDiff <= 5 {
              score += 1.0 - (Double(yearDiff) * 0.15)
            }
          }
        }
      }

      // Duration similarity (within 30 seconds)
      for refSong in referenceSongs {
        let durationDiff = abs(song.duration - refSong.duration)
        if durationDiff <= 30 {
          score += 0.5 - (durationDiff * 0.01)
        }
      }

      if score > 0 {
        scoredSongs.append((song, score))
      }
    }

    // Sort by score and return top matches
    scoredSongs.sort { $0.score > $1.score }
    return scoredSongs.prefix(limit).map { $0.song }
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
        guard let songGenre = song.genre else { return false }
        return songGenre.lowercased().contains(genre.lowercased())
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
    let discoverySongs = library.songs.filter { song in
      !playedArtists.contains(song.artist)
    }.shuffled().prefix(limit)

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
    let playlistSongs = playlist.songs

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
      if let genre = song.genre {
        let normalized = genre.trimmingCharacters(in: .whitespaces).lowercased()
        genreCounts[normalized, default: 0] += 1
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
      guard let songGenre = song.genre else { return false }

      let normalizedGenre = songGenre.trimmingCharacters(in: .whitespaces).lowercased()
      return genres.contains(normalizedGenre)
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
      let id = recommendation.id
      if seenIds.contains(id) {
        return false
      }
      seenIds.insert(id)
      return true
    }
  }
}
