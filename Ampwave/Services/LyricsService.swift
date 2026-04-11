//
//  LyricsService.swift
//  Ampwave
//

import Foundation
import Observation
import SwiftData

@MainActor
@Observable
final class LyricsService {
  static let shared = LyricsService()

  var modelContext: ModelContext?
  private let lrclibBaseURL = "https://lrclib.net/api"
  private let lyricsOvhBaseURL = "https://api.lyrics.ovh/v1"

  private init() {}

  func setModelContext(_ context: ModelContext) {
    self.modelContext = context
  }

  func fetchLyrics(for song: LibrarySong) async -> SyncedLyric? {
    if let cached = getCachedLyrics(for: song) {
      return cached
    }

    // Check for local .lrc file first
    let url = SongLibrary.shared.getFileURL(for: song)
    let lrcURL = url.deletingPathExtension().appendingPathExtension("lrc")
    if FileManager.default.fileExists(atPath: lrcURL.path) {
      if let lrcContent = try? String(contentsOf: lrcURL, encoding: .utf8) {
        let lines = LRCParser.parse(lrcContent)
        if !lines.isEmpty {
          let lyrics = SyncedLyric(
            songId: song.id,
            lines: lines,
            source: .lrclib,  // Local but we use .lrclib for now
            language: nil
          )
          cacheLyrics(lyrics)
          song.lyrics = lrcContent
          return lyrics
        }
      }
    }

    // Skip online if autoFetchLyrics is false or if song already has synced lyrics
    guard let modelContext = modelContext else { return nil }
    let preferences = UserPreferences.getOrCreate(in: modelContext)
    
    // Check if we already have synced lyrics in the model
    let hasSyncedLyrics = !LRCParser.parse(song.lyrics ?? "").isEmpty
    
    // If auto-fetch is off, or we already have synced lyrics, don't fetch
    if !preferences.autoFetchLyrics || hasSyncedLyrics {
      return nil
    }

    // Rate limit checks for songs we already checked but found nothing for
    // (We could add a 'lastLyricsCheckDate' to LibrarySong in a future update)
    
    return await fetchOnlineLyrics(for: song)
  }

  func fetchOnlineLyrics(for song: LibrarySong) async -> SyncedLyric? {
    let lrclibResult = await fetchFromLRCLIB(song: song)

    if let synced = lrclibResult.synced {
      let cached = cacheLyrics(synced)
      song.lyrics = LRCParser.toLRC(cached.lines)
      return cached
    }

    if let plain = lrclibResult.plain {
      song.lyrics = plain
      // Clear any old cached synced lyrics since we now have plain text
      clearCachedLyrics(for: song)
      return nil
    }

    // Fallback to lyrics.ovh if LRCLIB has nothing
    if let plain = await fetchFromLyricsOVH(song: song) {
      song.lyrics = plain
      clearCachedLyrics(for: song)
      return nil
    }

    return nil
  }

  private func fetchFromLRCLIB(song: LibrarySong) async -> (synced: SyncedLyric?, plain: String?) {
    // Build query parameters
    var components = URLComponents(string: "\(lrclibBaseURL)/get")!

    var queryItems: [URLQueryItem] = []
    queryItems.append(URLQueryItem(name: "track_name", value: song.title))
    queryItems.append(URLQueryItem(name: "artist_name", value: song.artist))
    if let album = song.album {
      queryItems.append(URLQueryItem(name: "album_name", value: album))
    }
    if song.duration > 0 {
      queryItems.append(URLQueryItem(name: "duration", value: String(Int(song.duration))))
    }

    components.queryItems = queryItems

    guard let url = components.url else { return (nil, nil) }

    do {
      let (data, response) = try await URLSession.shared.data(from: url)

      if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 404 {
        return (nil, nil)
      }

      let lrclibResponse = try JSONDecoder().decode(LRCLIBResponse.self, from: data)

      // Parse synced lyrics if available
      if let syncedLyrics = lrclibResponse.syncedLyrics, !syncedLyrics.isEmpty {
        let lines = LRCParser.parse(syncedLyrics)
        if !lines.isEmpty {
          let synced = SyncedLyric(
            songId: song.id,
            lines: lines,
            source: .lrclib,
            language: lrclibResponse.language
          )
          return (synced, nil)
        }
      }

      // Return plain lyrics as is
      if let plainLyrics = lrclibResponse.plainLyrics, !plainLyrics.isEmpty {
        return (nil, plainLyrics)
      }

      return (nil, nil)
    } catch {
      print("Failed to fetch lyrics: \(error)")
      return (nil, nil)
    }
  }

  private func fetchFromLyricsOVH(song: LibrarySong) async -> String? {
    // Build URL: https://api.lyrics.ovh/v1/ARTIST/SONG
    let artist = song.artist.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? ""
    let title = song.title.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? ""

    guard let url = URL(string: "\(lyricsOvhBaseURL)/\(artist)/\(title)") else {
      return nil
    }

    do {
      let (data, response) = try await URLSession.shared.data(from: url)

      if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 404 {
        return nil
      }

      let lyricsOVHResponse = try JSONDecoder().decode(LyricsOVHResponse.self, from: data)

      guard let lyricsText = lyricsOVHResponse.lyrics, !lyricsText.isEmpty else {
        return nil
      }

      return lyricsText
    } catch {
      print("Failed to fetch lyrics from lyrics.ovh: \(error)")
      return nil
    }
  }

  private struct LyricsOVHResponse: Codable {
    let lyrics: String?
    let error: String?
  }

  func getCachedLyrics(for song: LibrarySong) -> SyncedLyric? {
    guard let modelContext = modelContext else { return nil }

    let descriptor = FetchDescriptor<SyncedLyric>()

    guard let allLyrics = try? modelContext.fetch(descriptor) else { return nil }
    return allLyrics.first(where: { $0.songId == song.id })
  }

  @discardableResult
  private func cacheLyrics(_ lyrics: SyncedLyric) -> SyncedLyric {
    guard let modelContext = modelContext else { return lyrics }

    let descriptor = FetchDescriptor<SyncedLyric>()

    if let allLyrics = try? modelContext.fetch(descriptor),
      let existing = allLyrics.first(where: { $0.songId == lyrics.songId })
    {
      existing.lines = lyrics.lines
      existing.source = lyrics.source
      existing.language = lyrics.language
      existing.lastUpdated = Date()
      try? modelContext.save()
      return existing
    } else {
      modelContext.insert(lyrics)
      try? modelContext.save()
      return lyrics
    }
  }

  func clearCachedLyrics(for song: LibrarySong) {
    guard let modelContext = modelContext else { return }

    let descriptor = FetchDescriptor<SyncedLyric>()

    guard let allLyrics = try? modelContext.fetch(descriptor),
      let existing = allLyrics.first(where: { $0.songId == song.id })
    else { return }

    modelContext.delete(existing)
    try? modelContext.save()
  }

  func refreshLyrics(for song: LibrarySong) async -> SyncedLyric? {
    clearCachedLyrics(for: song)
    return await fetchOnlineLyrics(for: song)
  }

  func saveLyrics(for song: LibrarySong, content: String) {
    guard let modelContext = modelContext else { return }

    let lines = LRCParser.parse(content)
    if !lines.isEmpty {
      // It's LRC format
      let syncedLyric = SyncedLyric(
        songId: song.id,
        lines: lines,
        source: .lrclib,  // Mark as manual/local if possible, but .lrclib is fine for now
        language: nil
      )
      cacheLyrics(syncedLyric)
    } else {
      // It's plain text - we don't store plain text in SyncedLyric for now,
      // but we might want to clear existing synced lyrics if user explicitly puts plain text
      clearCachedLyrics(for: song)
    }

    song.lyrics = content
    try? modelContext.save()
  }
}
