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

  private init() {}

  func search(query: String, filter: SearchView.SearchFilter) async -> SearchResultsBundle {
    let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard trimmed.count >= 2 else {
      return .empty
    }

    // Ensure index is ready
    let index = await getOrBuildIndex()

    // Perform search on a background thread
    return await Task.detached(priority: .userInitiated) {
      return index.buildResults(for: trimmed, filter: filter)
    }.value
  }

  private func getOrBuildIndex() async -> SearchLibraryIndex {
    let signature = calculateLibrarySignature()

    if let index = currentIndex, signature == lastLibrarySignature {
      return index
    }

    isIndexing = true
    defer { isIndexing = false }

    let songs = SongLibrary.shared.songs
    let albums = SongLibrary.shared.albums
    let artists = SongLibrary.shared.artists
    let playlists = PlaylistManager.shared.playlists

    // Indexing is heavy, do it off-main
    let newIndex = await Task.detached(priority: .utility) {
      return SearchLibraryIndex(
        songs: songs,
        albums: albums,
        artists: artists,
        playlists: playlists
      )
    }.value

    currentIndex = newIndex
    lastLibrarySignature = signature
    return newIndex
  }

  private func calculateLibrarySignature() -> String {
    let library = SongLibrary.shared
    let playlists = PlaylistManager.shared
    return
      "\(library.songs.count)-\(library.albums.count)-\(library.artists.count)-\(playlists.playlists.count)"
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

private struct SearchLibraryIndex {
  let songs: [SongEntry]
  let albums: [AlbumEntry]
  let artists: [ArtistEntry]
  let playlists: [PlaylistEntry]

  init(songs: [LibrarySong], albums: [Album], artists: [Artist], playlists: [Playlist]) {
    self.songs = songs.map { SongEntry(song: $0) }
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
      if entry.song.artworkPath != nil { score += 0.25 }
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

    init(song: LibrarySong) {
      self.song = song

      // Use pre-calculated search index if available, otherwise fallback to live normalization
      if let index = song.searchIndex, !index.isEmpty {
        // We still need individual fields for weighted scoring
        self.normalizedTitle = SearchFuzzyEngine.normalize(song.title)
        self.normalizedArtist = SearchFuzzyEngine.normalize(song.artist)
        self.normalizedAlbum = SearchFuzzyEngine.normalize(song.album ?? "")
        self.normalizedGenre = SearchFuzzyEngine.normalize(song.genre ?? "")
        self.normalizedLyrics = index  // The index already contains normalized lyrics and metadata
      } else {
        self.normalizedTitle = SearchFuzzyEngine.normalize(song.title)
        self.normalizedArtist = SearchFuzzyEngine.normalize(song.artist)
        self.normalizedAlbum = SearchFuzzyEngine.normalize(song.album ?? "")
        self.normalizedGenre = SearchFuzzyEngine.normalize(song.genre ?? "")
        self.normalizedLyrics = SearchFuzzyEngine.normalize(song.lyrics ?? "")
      }

      self.titleTokens = SearchFuzzyEngine.tokens(from: normalizedTitle)
      self.artistTokens = SearchFuzzyEngine.tokens(from: normalizedArtist)
      self.albumTokens = SearchFuzzyEngine.tokens(from: normalizedAlbum)
      self.genreTokens = SearchFuzzyEngine.tokens(from: normalizedGenre)
      self.lyricsTokens = SearchFuzzyEngine.tokens(from: normalizedLyrics)
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

private enum SearchFuzzyEngine {
  static func normalize(_ value: String) -> String {
    value
      .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
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
    if haystackText.contains(needle) { return 2.0 }
    return tokenOverlapScore(needleTokens: needleTokens, haystackTokens: haystackTokens) * 1.5
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
