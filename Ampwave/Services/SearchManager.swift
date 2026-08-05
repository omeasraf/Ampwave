//
//  SearchManager.swift
//  Ampwave
//
//  Thread-safe search engine that handles background indexing and fuzzy matching.
//

import Foundation
import Observation
import SwiftData

@MainActor
@Observable
final class SearchManager {
  static let shared = SearchManager()

  private(set) var isIndexing = false
  private var currentIndex: SearchLibraryIndex?
  private var lastLibrarySignature: String = ""
  /// Normalized per-song text carried across rebuilds; see `getOrBuildIndex`.
  private var normalizedTextCache: [UUID: NormalizedSongText] = [:]

  private init() {}

  func search(query: String, filter: SearchView.SearchFilter) async -> SearchResultsBundle {
    let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard trimmed.count >= 2 else {
      return .empty
    }

    // Ensure index is ready
    let index = await getOrBuildIndex()

    // Scoring runs here rather than on a detached task: it walks precomputed
    // tokens and reads `LibrarySong` properties for the final ranking, and
    // PersistentModels aren't Sendable. The costly half — normalizing and
    // tokenizing every song's lyrics — already happens off the main actor in
    // `getOrBuildIndex`, and is reused across rebuilds.
    return index.buildResults(for: trimmed, filter: filter)
  }

  private func getOrBuildIndex() async -> SearchLibraryIndex {
    let signature = calculateLibrarySignature()

    if let index = currentIndex, signature == lastLibrarySignature {
      return index
    }

    isIndexing = true
    defer { isIndexing = false }

    let albums = SongLibrary.shared.albums
    let artists = SongLibrary.shared.artists
    let playlists = PlaylistManager.shared.playlists
    let songs = SongLibrary.shared.songs

    // Snapshot the text on the main actor. `LibrarySong` is a SwiftData
    // PersistentModel and is not Sendable, so reading its properties from a
    // detached task is a genuine data race — only these plain value copies
    // cross over.
    let snapshots = songs.map { SongTextSnapshot(song: $0) }
    let reusable = normalizedTextCache

    // Normalizing and tokenizing lyrics dominates indexing cost, and a library
    // change usually touches a single song — so entries whose fingerprint is
    // unchanged are carried over untouched rather than recomputed.
    let normalized = await Task.detached(priority: .utility) {
      var result: [UUID: NormalizedSongText] = [:]
      result.reserveCapacity(snapshots.count)
      for snapshot in snapshots {
        if let cached = reusable[snapshot.id], cached.fingerprint == snapshot.fingerprint {
          result[snapshot.id] = cached
        } else {
          result[snapshot.id] = NormalizedSongText(snapshot: snapshot)
        }
      }
      return result
    }.value

    normalizedTextCache = normalized

    // Re-attach model references on the main actor; this is just struct
    // assembly, no string work.
    let entries = songs.compactMap { song in
      normalized[song.id].map { SearchLibraryIndex.SongEntry(song: song, text: $0) }
    }

    let newIndex = SearchLibraryIndex(
      songEntries: entries,
      albums: albums,
      artists: artists,
      playlists: playlists
    )

    currentIndex = newIndex
    lastLibrarySignature = signature
    return newIndex
  }

  private func calculateLibrarySignature() -> String {
    let library = SongLibrary.shared
    let playlists = PlaylistManager.shared
    return
      "\(library.songs.count)-\(library.albums.count)-\(library.artists.count)-\(playlists.playlists.count)-\(library.libraryVersion)"
  }
}

struct SearchResultsBundle {
  let songs: [LibrarySong]
  let albums: [Album]
  let artists: [Artist]
  let playlists: [Playlist]
  let topSong: LibrarySong?

  var isEmpty: Bool {
    songs.isEmpty && albums.isEmpty && artists.isEmpty && playlists.isEmpty
  }

  static let empty = SearchResultsBundle(
    songs: [], albums: [], artists: [], playlists: [], topSong: nil)
}

private struct Ranked<Item> {
  let item: Item
  let score: Double
}

/// Identity of a song's searchable text. Equal fingerprints normalize to the
/// same result, so a cached entry can be reused instead of recomputed.
nonisolated struct SongEntryFingerprint: Equatable, Sendable {
  let contentVersion: Int
  let title: String
  let artist: String
  let album: String
  let genre: String
  let lyricsLength: Int
}

/// Plain text copied off a `LibrarySong` on the main actor.
///
/// PersistentModels aren't Sendable, so this is what travels to the background
/// normalizer — never the model itself.
nonisolated struct SongTextSnapshot: Sendable {
  let id: UUID
  let fingerprint: SongEntryFingerprint
  let title: String
  let artist: String
  let album: String
  let genre: String
  let lyrics: String

  @MainActor
  init(song: LibrarySong) {
    self.id = song.id
    self.title = song.title
    self.artist = song.artist
    self.album = song.album ?? ""
    self.genre = song.genre ?? ""
    self.lyrics = song.lyrics ?? ""
    self.fingerprint = SongEntryFingerprint(
      contentVersion: song.searchContentVersion,
      title: title,
      artist: artist,
      album: album,
      genre: genre,
      lyricsLength: lyrics.count
    )
  }
}

/// The expensive part of indexing: normalized strings and their tokens.
nonisolated struct NormalizedSongText: Sendable {
  let fingerprint: SongEntryFingerprint
  let title: String
  let artist: String
  let album: String
  let genre: String
  let lyrics: String
  let titleTokens: [String]
  let artistTokens: [String]
  let albumTokens: [String]
  let genreTokens: [String]
  let lyricsTokens: [String]

  init(snapshot: SongTextSnapshot) {
    self.fingerprint = snapshot.fingerprint
    self.title = SearchFuzzyEngine.normalize(snapshot.title)
    self.artist = SearchFuzzyEngine.normalize(snapshot.artist)
    self.album = SearchFuzzyEngine.normalize(snapshot.album)
    self.genre = SearchFuzzyEngine.normalize(snapshot.genre)

    // Timestamps are stripped so LRC markers don't enter the index as stray
    // digits, and the text is capped so a long track can't dominate indexing.
    let plain = LRCParser.plainText(from: snapshot.lyrics)
    self.lyrics = SearchFuzzyEngine.normalize(String(plain.prefix(5000)))

    self.titleTokens = SearchFuzzyEngine.tokens(from: title)
    self.artistTokens = SearchFuzzyEngine.tokens(from: artist)
    self.albumTokens = SearchFuzzyEngine.tokens(from: album)
    self.genreTokens = SearchFuzzyEngine.tokens(from: genre)
    self.lyricsTokens = SearchFuzzyEngine.tokens(from: lyrics)
  }
}

private struct SearchLibraryIndex {
  let songs: [SongEntry]
  let albums: [AlbumEntry]
  let artists: [ArtistEntry]
  let playlists: [PlaylistEntry]

  init(
    songEntries: [SongEntry],
    albums: [Album],
    artists: [Artist],
    playlists: [Playlist]
  ) {
    self.songs = songEntries
    self.albums = albums.map { AlbumEntry(album: $0) }
    self.artists = artists.map { ArtistEntry(artist: $0) }
    self.playlists = playlists.map { PlaylistEntry(playlist: $0) }
  }

  func buildResults(for query: String, filter: SearchView.SearchFilter) -> SearchResultsBundle {
    let normalizedQuery = SearchFuzzyEngine.normalize(query)
    let queryTokens = SearchFuzzyEngine.tokens(from: normalizedQuery)

    var songs: [LibrarySong] = []
    var albums: [Album] = []
    var artists: [Artist] = []
    var playlists: [Playlist] = []
    var topSong: LibrarySong?

    if filter == .all || filter == .songs {
      let ranked = rankedSongs(for: normalizedQuery, queryTokens: queryTokens)
      songs = ranked.map(\.item)
      topSong = ranked.first?.item
    }

    if filter == .all || filter == .albums {
      albums = rankedAlbums(for: normalizedQuery, queryTokens: queryTokens).map(\.item)
    }

    if filter == .all || filter == .artists {
      artists = rankedArtists(for: normalizedQuery, queryTokens: queryTokens).map(\.item)
    }

    if filter == .all || filter == .playlists {
      playlists = rankedPlaylists(for: normalizedQuery, queryTokens: queryTokens).map(\.item)
    }

    return SearchResultsBundle(
      songs: songs,
      albums: albums,
      artists: artists,
      playlists: playlists,
      topSong: topSong
    )
  }

  private func rankedSongs(for normalizedQuery: String, queryTokens: [String]) -> [Ranked<
    LibrarySong
  >] {
    songs.compactMap { entry in
      let titleScore = SearchFuzzyEngine.score(
        needle: normalizedQuery,
        needleTokens: queryTokens,
        haystack: entry.normalizedTitle,
        haystackTokens: entry.titleTokens,
        weight: 4.6
      )
      let artistScore = SearchFuzzyEngine.score(
        needle: normalizedQuery,
        needleTokens: queryTokens,
        haystack: entry.normalizedArtist,
        haystackTokens: entry.artistTokens,
        weight: 3.2
      )
      let albumScore = SearchFuzzyEngine.score(
        needle: normalizedQuery,
        needleTokens: queryTokens,
        haystack: entry.normalizedAlbum,
        haystackTokens: entry.albumTokens,
        weight: 2.1
      )
      let genreScore = SearchFuzzyEngine.score(
        needle: normalizedQuery,
        needleTokens: queryTokens,
        haystack: entry.normalizedGenre,
        haystackTokens: entry.genreTokens,
        weight: 1.2
      )

      var score = titleScore + artistScore + albumScore + genreScore

      if queryTokens.count >= 2 || normalizedQuery.count >= 5 {
        score += SearchFuzzyEngine.scoreLyrics(
          needle: normalizedQuery,
          needleTokens: queryTokens,
          haystackTokens: entry.lyricsTokens,
          haystackText: entry.normalizedLyrics
        )
      }

      if score <= 0.35 { return nil }
      if entry.song.effectiveArtworkPath != nil { score += 0.25 }
      if entry.song.genre != nil { score += 0.1 }

      return Ranked(item: entry.song, score: score)
    }
    .sorted { lhs, rhs in
      if lhs.score == rhs.score {
        return lhs.item.title.localizedCaseInsensitiveCompare(rhs.item.title) == .orderedAscending
      }
      return lhs.score > rhs.score
    }
  }

  private func rankedAlbums(for normalizedQuery: String, queryTokens: [String]) -> [Ranked<Album>] {
    albums.compactMap { entry in
      let score =
        SearchFuzzyEngine.score(
          needle: normalizedQuery,
          needleTokens: queryTokens,
          haystack: entry.normalizedName,
          haystackTokens: entry.nameTokens,
          weight: 3.6
        )
        + SearchFuzzyEngine.score(
          needle: normalizedQuery,
          needleTokens: queryTokens,
          haystack: entry.normalizedArtist,
          haystackTokens: entry.artistTokens,
          weight: 2.4
        )
      guard score > 0.5 else { return nil }
      return Ranked(item: entry.album, score: score)
    }
    .sorted { $0.score > $1.score }
  }

  private func rankedArtists(for normalizedQuery: String, queryTokens: [String]) -> [Ranked<Artist>]
  {
    artists.compactMap { entry in
      let score = SearchFuzzyEngine.score(
        needle: normalizedQuery,
        needleTokens: queryTokens,
        haystack: entry.normalizedName,
        haystackTokens: entry.nameTokens,
        weight: 3.3
      )
      guard score > 0.5 else { return nil }
      return Ranked(item: entry.artist, score: score)
    }
    .sorted { $0.score > $1.score }
  }

  private func rankedPlaylists(for normalizedQuery: String, queryTokens: [String]) -> [Ranked<
    Playlist
  >] {
    playlists.compactMap { entry in
      let score = SearchFuzzyEngine.score(
        needle: normalizedQuery,
        needleTokens: queryTokens,
        haystack: entry.normalizedName,
        haystackTokens: entry.nameTokens,
        weight: 3.0
      )
      guard score > 0.5 else { return nil }
      return Ranked(item: entry.playlist, score: score)
    }
    .sorted { $0.score > $1.score }
  }

  struct SongEntry {
    let song: LibrarySong
    let fingerprint: SongEntryFingerprint
    let normalizedTitle: String
    let normalizedArtist: String
    let normalizedAlbum: String
    let normalizedGenre: String
    let normalizedLyrics: String
    let titleTokens: [String]
    let artistTokens: [String]
    let albumTokens: [String]
    let genreTokens: [String]
    let lyricsTokens: [String]

    /// Pairs a model reference with text normalized off the main actor.
    ///
    /// Lyrics come from the song's own text — an earlier version fed in the
    /// combined `searchIndex` blob (title + artist + album + genre + lyrics),
    /// so a plain title match also scored as a full-strength lyrics hit worth
    /// up to 4.5 points and badly skewed ranking.
    init(song: LibrarySong, text: NormalizedSongText) {
      self.song = song
      self.fingerprint = text.fingerprint
      self.normalizedTitle = text.title
      self.normalizedArtist = text.artist
      self.normalizedAlbum = text.album
      self.normalizedGenre = text.genre
      self.normalizedLyrics = text.lyrics
      self.titleTokens = text.titleTokens
      self.artistTokens = text.artistTokens
      self.albumTokens = text.albumTokens
      self.genreTokens = text.genreTokens
      self.lyricsTokens = text.lyricsTokens
    }
  }

  struct AlbumEntry {
    let album: Album
    let normalizedName: String
    let normalizedArtist: String
    let nameTokens: [String]
    let artistTokens: [String]

    init(album: Album) {
      self.album = album
      self.normalizedName = SearchFuzzyEngine.normalize(album.name)
      self.normalizedArtist = SearchFuzzyEngine.normalize(album.artist ?? "")
      self.nameTokens = SearchFuzzyEngine.tokens(from: normalizedName)
      self.artistTokens = SearchFuzzyEngine.tokens(from: normalizedArtist)
    }
  }

  struct ArtistEntry {
    let artist: Artist
    let normalizedName: String
    let nameTokens: [String]

    init(artist: Artist) {
      self.artist = artist
      self.normalizedName = SearchFuzzyEngine.normalize(artist.name)
      self.nameTokens = SearchFuzzyEngine.tokens(from: normalizedName)
    }
  }

  struct PlaylistEntry {
    let playlist: Playlist
    let normalizedName: String
    let nameTokens: [String]

    init(playlist: Playlist) {
      self.playlist = playlist
      self.normalizedName = SearchFuzzyEngine.normalize(playlist.name)
      self.nameTokens = SearchFuzzyEngine.tokens(from: normalizedName)
    }
  }
}

/// Pure string scoring — no state, so it runs wherever the caller is. Marked
/// `nonisolated` because the project defaults to MainActor isolation and the
/// index is normalized on a background task.
private nonisolated enum SearchFuzzyEngine {
  static func normalize(_ value: String) -> String {
    value
      .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
      .replacingOccurrences(of: "[''\"\"“”]", with: "", options: .regularExpression)
      .replacingOccurrences(of: "[^a-z0-9 ]", with: " ", options: .regularExpression)
      .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .lowercased()
  }

  static func tokens(from value: String) -> [String] {
    value.split(separator: " ").map(String.init)
  }

  static func score(
    needle: String, needleTokens: [String], haystack: String, haystackTokens: [String],
    weight: Double
  ) -> Double {
    guard !needle.isEmpty, !haystack.isEmpty else { return 0 }
    if haystack == needle { return weight * 1.3 }
    if haystack.hasPrefix(needle) { return weight * 1.1 }
    if haystack.contains(needle) { return weight * 0.9 }

    let overlap = tokenOverlapScore(needleTokens: needleTokens, haystackTokens: haystackTokens)
    guard overlap > 0 else { return 0 }
    return weight * overlap
  }

  static func scoreLyrics(
    needle: String, needleTokens: [String], haystackTokens: [String], haystackText: String
  ) -> Double {
    guard !needle.isEmpty, !haystackText.isEmpty else { return 0 }

    // 1. Exact phrase match (Highest priority)
    if haystackText.contains(needle) { return 4.5 }

    // 2. Proximity/Sliding Window Match (Handles minor typos/missing words)
    let proximityScore = calculateProximityScore(needleTokens: needleTokens, haystackTokens: haystackTokens)
    if proximityScore > 0.6 {
      return proximityScore * 3.5
    }

    // 3. General bag-of-words overlap (Fallback)
    let overlap = tokenOverlapScore(needleTokens: needleTokens, haystackTokens: haystackTokens)
    guard overlap >= 0.4 else {
      return overlap * 0.5
    }

    return overlap * 2.0
  }

  /// Checks if the needle tokens appear in the haystack close to each other in sequence.
  private static func calculateProximityScore(needleTokens: [String], haystackTokens: [String]) -> Double {
    guard needleTokens.count >= 3, haystackTokens.count >= needleTokens.count else { return 0 }
    
    var maxScore: Double = 0
    let windowSize = needleTokens.count + 5 // Allow for 5 "missing" or "extra" words
    
    // Slide through haystack
    for i in 0..<(haystackTokens.count - needleTokens.count) {
      let window = haystackTokens[i..<min(i + windowSize, haystackTokens.count)]
      
      var matchesInOrder = 0
      var lastMatchIdx = -1
      
      for token in needleTokens {
        if let matchIdx = window.firstIndex(where: { $0.hasPrefix(token) }), matchIdx > lastMatchIdx {
          matchesInOrder += 1
          lastMatchIdx = matchIdx
        }
      }
      
      let score = Double(matchesInOrder) / Double(needleTokens.count)
      maxScore = max(maxScore, score)
      
      if maxScore >= 0.95 { break } // Good enough
    }
    
    return maxScore
  }

  private static func tokenOverlapScore(needleTokens: [String], haystackTokens: [String]) -> Double
  {
    guard !needleTokens.isEmpty, !haystackTokens.isEmpty else { return 0 }
    let matches = needleTokens.filter { token in
      haystackTokens.contains { $0.hasPrefix(token) || (token.count > 3 && $0.contains(token)) }
    }.count
    return Double(matches) / Double(needleTokens.count)
  }
}
