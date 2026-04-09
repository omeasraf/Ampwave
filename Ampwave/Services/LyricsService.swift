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
            source: .lrclib, // Local but we use .lrclib for now
            language: nil
          )
          cacheLyrics(lyrics)
          song.lyrics = lrcContent
          return lyrics
        }
      }
    }

    // Skip online if autoFetchLyrics is false or if song already has embedded lyrics
    guard let modelContext = modelContext else { return nil }
    let settings = AppSettings.getOrCreate(in: modelContext)
    if !settings.autoFetchLyrics && (song.lyrics != nil && !song.lyrics!.isEmpty) {
      return nil
    }

    return await fetchOnlineLyrics(for: song)
  }

  func fetchOnlineLyrics(for song: LibrarySong) async -> SyncedLyric? {
    if let lyrics = await fetchFromLRCLIB(song: song) {
      cacheLyrics(lyrics)
      // Update song.lyrics with the plain text or LRC if possible
      if let synced = getCachedLyrics(for: song) {
        song.lyrics = LRCParser.toLRC(synced.lines)
      }
      return lyrics
    }

    // Fallback to lyrics.ovh if LRCLIB has nothing
    if let lyrics = await fetchFromLyricsOVH(song: song) {
      cacheLyrics(lyrics)
      if let synced = getCachedLyrics(for: song) {
        song.lyrics = synced.lines.map(\.text).joined(separator: "\n")
      }
      return lyrics
    }

    return nil
  }

  private func fetchFromLRCLIB(song: LibrarySong) async -> SyncedLyric? {
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

    guard let url = components.url else { return nil }

    do {
      let (data, response) = try await URLSession.shared.data(from: url)

      // Check for 404 (no lyrics found)
      if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 404 {
        return nil
      }

      let lrclibResponse = try JSONDecoder().decode(LRCLIBResponse.self, from: data)

      // Parse synced lyrics if available
      if let syncedLyrics = lrclibResponse.syncedLyrics, !syncedLyrics.isEmpty {
        let lines = LRCParser.parse(syncedLyrics)
        if !lines.isEmpty {
          return SyncedLyric(
            songId: song.id,
            lines: lines,
            source: .lrclib,
            language: lrclibResponse.language
          )
        }
      }

      // Fall back to plain lyrics
      if let plainLyrics = lrclibResponse.plainLyrics, !plainLyrics.isEmpty {
        let lines = plainLyrics.split(separator: "\n").enumerated().map { index, line in
          LyricLine(timestamp: TimeInterval(index * 5), text: String(line))
        }
        return SyncedLyric(
          songId: song.id,
          lines: lines,
          source: .lrclib,
          language: lrclibResponse.language
        )
      }

      return nil
    } catch {
      print("Failed to fetch lyrics: \(error)")
      return nil
    }
  }

  private func fetchFromLyricsOVH(song: LibrarySong) async -> SyncedLyric? {
    // Build URL: https://api.lyrics.ovh/v1/ARTIST/SONG
    let artist = song.artist.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? ""
    let title = song.title.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? ""

    guard let url = URL(string: "\(lyricsOvhBaseURL)/\(artist)/\(title)") else {
      return nil
    }

    do {
      let (data, response) = try await URLSession.shared.data(from: url)

      // Check for 404 (no lyrics found)
      if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 404 {
        return nil
      }

      let lyricsOVHResponse = try JSONDecoder().decode(LyricsOVHResponse.self, from: data)

      guard let lyricsText = lyricsOVHResponse.lyrics, !lyricsText.isEmpty else {
        return nil
      }

      // Convert plain text lyrics to LyricLine array
      let lines = lyricsText.split(separator: "\n").enumerated().map { index, line in
        LyricLine(timestamp: TimeInterval(index * 5), text: String(line))
      }

      return SyncedLyric(
        songId: song.id,
        lines: lines,
        source: .lrclib,
        language: nil
      )
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

  private func cacheLyrics(_ lyrics: SyncedLyric) {
    guard let modelContext = modelContext else { return }

    let descriptor = FetchDescriptor<SyncedLyric>()

    if let allLyrics = try? modelContext.fetch(descriptor),
      let existing = allLyrics.first(where: { $0.songId == lyrics.songId })
    {
      existing.lines = lyrics.lines
      existing.source = lyrics.source
      existing.language = lyrics.language
      existing.lastUpdated = Date()
    } else {
      modelContext.insert(lyrics)
    }

    try? modelContext.save()
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
