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
  private let biniLyricsBaseURL = "https://lyrics-api.binimum.org"
  private let lyricsPlusBaseURLs = [
    "https://lyricsplus.binimum.org",
    "https://lyricsplus-seven.vercel.app",
    "https://lyricsplus.prjktla.workers.dev",
    "https://lyrics-plus-backend.vercel.app",
  ]

  private init() {}

  func setModelContext(_ context: ModelContext) {
    self.modelContext = context
  }

  func fetchLyrics(for song: LibrarySong) async -> SyncedLyric? {
    guard let modelContext = modelContext else { return nil }
    let preferences = UserPreferences.getOrCreate(in: modelContext)

    if let cached = getCachedLyrics(for: song) {
      if !preferences.wordSyncedLyricsEnabled || hasWordSyncedLyrics(cached.lines) {
        return cached
      }

      if let upgraded = await fetchWordSyncedLyrics(for: song) {
        return upgraded
      }

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
            source: .local,
            language: nil
          )
          cacheLyrics(lyrics)
          song.lyrics = lrcContent
          return lyrics
        }
      }
    }

    // Check if we already have synced lyrics in the model
    let storedLines = LRCParser.parse(song.lyrics ?? "")
    let hasSyncedLyrics = !storedLines.isEmpty
    let needsWordSyncedUpgrade = preferences.wordSyncedLyricsEnabled && !hasWordSyncedLyrics(storedLines)

    if needsWordSyncedUpgrade {
      return await fetchWordSyncedLyrics(for: song)
    }

    // If auto-fetch is off, or we already have synced lyrics, don't fetch
    if !preferences.autoFetchLyrics || hasSyncedLyrics {
      return nil
    }

    // Rate limit checks for songs we already checked but found nothing for
    // (We could add a 'lastLyricsCheckDate' to LibrarySong in a future update)

    return await fetchOnlineLyrics(for: song)
  }

  private func hasWordSyncedLyrics(_ lines: [LyricLine]) -> Bool {
    lines.contains { ($0.wordOffsets?.count ?? 0) > 1 }
  }

  func fetchWordSyncedLyrics(for song: LibrarySong) async -> SyncedLyric? {
    guard let modelContext = modelContext else { return nil }
    let preferences = UserPreferences.getOrCreate(in: modelContext)

    guard preferences.wordSyncedLyricsEnabled,
      NetworkMonitor.shared.isOnline,
      !preferences.isOfflineMode,
      let wordSynced = await fetchFromWordSyncedProviders(song: song)
    else { return nil }

    let cached = cacheLyrics(wordSynced)
    song.lyrics = LRCParser.toLRC(cached.lines)
    song.updateSearchIndex()
    try? modelContext.save()
    SongLibrary.shared.notifyLibraryChange()
    return cached
  }

  func fetchOnlineLyrics(for song: LibrarySong) async -> SyncedLyric? {
    // YouLy+/am-lyrics — prefers word-synced lyrics from LyricsPlus/Binimum.
    if let cached = await fetchWordSyncedLyrics(for: song) {
      return cached
    }

    // LRCLIB — returns line-synced LRC, and word-synced enhanced LRC for many songs.
    // The LRCParser already handles the <mm:ss.xx> word-offset format.
    let lrclibResult = await fetchFromLRCLIB(song: song)

    if let synced = lrclibResult.synced {
      let cached = cacheLyrics(synced)
      song.lyrics = LRCParser.toLRC(cached.lines)
      song.updateSearchIndex()
      return cached
    }

    if let plain = lrclibResult.plain {
      song.lyrics = plain
      song.updateSearchIndex()
      // Clear any old cached synced lyrics since we now have plain text
      clearCachedLyrics(for: song)
      return nil
    }

    // Fallback to lyrics.ovh if LRCLIB has nothing
    if let plain = await fetchFromLyricsOVH(song: song) {
      song.lyrics = plain
      song.updateSearchIndex()
      clearCachedLyrics(for: song)
      return nil
    }

    return nil
  }

  private func fetchFromWordSyncedProviders(song: LibrarySong) async -> SyncedLyric? {
    if let biniLyrics = await fetchFromBiniLyrics(song: song) {
      return biniLyrics
    }

    return await fetchFromLyricsPlus(song: song)
  }

  private func fetchFromBiniLyrics(song: LibrarySong) async -> SyncedLyric? {
    var queryURLs: [URL] = []

    if let isrc = song.isrc, !isrc.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      var components = URLComponents(string: biniLyricsBaseURL)!
      components.queryItems = [URLQueryItem(name: "isrc", value: isrc)]
      if let url = components.url {
        queryURLs.append(url)
      }
    }

    var components = URLComponents(string: biniLyricsBaseURL)!
    var queryItems = [
      URLQueryItem(name: "track", value: song.title),
      URLQueryItem(name: "artist", value: song.artist),
    ]

    if let album = song.album, !album.isEmpty {
      queryItems.append(URLQueryItem(name: "album", value: album))
    }

    if song.duration > 0 {
      queryItems.append(URLQueryItem(name: "duration", value: String(Int(song.duration))))
    }

    components.queryItems = queryItems
    if let url = components.url {
      queryURLs.append(url)
    }

    for queryURL in queryURLs {
      do {
        let (data, response) = try await URLSession.shared.data(from: queryURL)
        guard (response as? HTTPURLResponse)?.statusCode != 404 else { continue }
        guard
          let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
          let results = object["results"] as? [[String: Any]],
          let firstResult = results.first,
          let lyricsURLString = firstResult["lyricsUrl"] as? String,
          let lyricsURL = URL(string: lyricsURLString)
        else { continue }

        let (ttmlData, ttmlResponse) = try await URLSession.shared.data(from: lyricsURL)
        guard (ttmlResponse as? HTTPURLResponse)?.statusCode != 404 else { continue }
        guard let ttml = String(data: ttmlData, encoding: .utf8) else { continue }

        let lines = TTMLLyricParser.parse(ttml)
        guard !lines.isEmpty else { continue }

        return SyncedLyric(songId: song.id, lines: lines, source: .biniLyrics, language: nil)
      } catch {
        print("Failed to fetch lyrics from BiniLyrics: \(error)")
      }
    }

    return nil
  }

  private func fetchFromLyricsPlus(song: LibrarySong) async -> SyncedLyric? {
    let serverOrder = Array(lyricsPlusBaseURLs.shuffled().prefix(3)) + ["https://lyricsplus.binimum.org"]

    for baseURL in serverOrder {
      var components = URLComponents(string: "\(baseURL)/v2/lyrics/get")!
      var queryItems = [
        URLQueryItem(name: "title", value: song.title),
        URLQueryItem(name: "artist", value: song.artist),
      ]

      if let isrc = song.isrc, !isrc.isEmpty {
        queryItems.append(URLQueryItem(name: "isrc", value: isrc))
      }

      if let album = song.album, !album.isEmpty {
        queryItems.append(URLQueryItem(name: "album", value: album))
      }

      if song.duration > 0 {
        queryItems.append(URLQueryItem(name: "duration", value: String(Int(song.duration))))
      }

      components.queryItems = queryItems
      guard let url = components.url else { continue }

      do {
        let (data, response) = try await URLSession.shared.data(from: url)
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
          continue
        }

        guard
          let payload = try JSONSerialization.jsonObject(with: data) as? [String: Any],
          let lines = LyricsPlusParser.parse(payload),
          !lines.isEmpty
        else { continue }

        return SyncedLyric(songId: song.id, lines: lines, source: .lyricsPlus, language: nil)
      } catch {
        print("Failed to fetch lyrics from LyricsPlus: \(error)")
      }
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

    let songId = song.id
    let descriptor = FetchDescriptor<SyncedLyric>(
      predicate: #Predicate<SyncedLyric> { $0.songId == songId }
    )

    return try? modelContext.fetch(descriptor).first
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
    song.updateSearchIndex()
    try? modelContext.save()
    SongLibrary.shared.notifyLibraryChange()
  }
}

private enum LyricsPlusParser {
  static func parse(_ payload: [String: Any]) -> [LyricLine]? {
    guard let rawLyrics = lyricsArray(from: payload), !rawLyrics.isEmpty else { return nil }
    let isLineSynced = (payload["type"] as? String)?.localizedCaseInsensitiveCompare("line") == .orderedSame

    let lines = rawLyrics.compactMap { entry -> LyricLine? in
      let lineStart = milliseconds(entry["time"])
      let lineText = entry["text"] as? String ?? ""

      let rawSyllables =
        (entry["syllabus"] as? [[String: Any]]) ?? (entry["words"] as? [[String: Any]]) ?? []

      var wordOffsets: [WordOffset] = []
      if !isLineSynced {
        for syllable in rawSyllables {
          guard (syllable["isBackground"] as? Bool) != true else { continue }
          let text = syllable["text"] as? String ?? ""
          guard !text.isEmpty else { continue }
          let timestamp = milliseconds(syllable["time"], fallback: lineStart) / 1000.0
          wordOffsets.append(WordOffset(timestamp: timestamp, text: text))
        }
      }

      let text: String
      if !wordOffsets.isEmpty {
        text = wordOffsets.map(\.text).joined().trimmingCharacters(in: .whitespacesAndNewlines)
      } else {
        text = lineText.trimmingCharacters(in: .whitespacesAndNewlines)
      }

      guard !text.isEmpty else { return nil }

      return LyricLine(
        timestamp: lineStart / 1000.0,
        text: text,
        translation: (entry["translation"] as? [String: Any])?["text"] as? String,
        wordOffsets: wordOffsets.isEmpty ? nil : wordOffsets
      )
    }

    return lines.sorted { $0.timestamp < $1.timestamp }
  }

  private static func lyricsArray(from payload: [String: Any]) -> [[String: Any]]? {
    if let lyrics = payload["lyrics"] as? [[String: Any]] {
      return lyrics
    }

    if let data = payload["data"] as? [String: Any],
      let lyrics = data["lyrics"] as? [[String: Any]]
    {
      return lyrics
    }

    return payload["data"] as? [[String: Any]]
  }

  private static func milliseconds(_ value: Any?, fallback: Double = 0) -> Double {
    let number: Double?

    if let double = value as? Double {
      number = double
    } else if let int = value as? Int {
      number = Double(int)
    } else if let string = value as? String {
      number = Double(string)
    } else {
      number = nil
    }

    guard let number, number.isFinite else { return fallback }
    if number.rounded() != number {
      return (number * 1000).rounded()
    }

    return max(0, number.rounded())
  }
}

private final class TTMLLyricParser: NSObject, XMLParserDelegate {
  private struct Span {
    let text: String
    let begin: TimeInterval
    let end: TimeInterval
    let isBackground: Bool
  }

  private struct Paragraph {
    let text: String
    let begin: TimeInterval
    let end: TimeInterval
    let translation: String?
    let spans: [Span]
  }

  private var paragraphs: [Paragraph] = []
  private var translations: [String: String] = [:]
  private var paragraphKey: String?
  private var paragraphBegin: TimeInterval = 0
  private var paragraphEnd: TimeInterval = 0
  private var paragraphText = ""
  private var paragraphSpans: [Span] = []
  private var currentSpanBegin: TimeInterval?
  private var currentSpanEnd: TimeInterval?
  private var currentSpanText = ""
  private var backgroundDepth = 0
  private var currentTranslationKey: String?
  private var currentTranslationText = ""
  private var elementStack: [String] = []

  static func parse(_ ttml: String) -> [LyricLine] {
    let parserDelegate = TTMLLyricParser()
    let parser = XMLParser(data: Data(ttml.utf8))
    parser.delegate = parserDelegate
    guard parser.parse() else { return [] }

    return parserDelegate.paragraphs.compactMap { paragraph in
      let wordOffsets = paragraph.spans
        .filter { !$0.isBackground && !$0.text.isEmpty }
        .map { WordOffset(timestamp: $0.begin, text: $0.text) }

      let text: String
      if !wordOffsets.isEmpty {
        text = wordOffsets.map(\.text).joined().trimmingCharacters(in: .whitespacesAndNewlines)
      } else {
        text = paragraph.text.trimmingCharacters(in: .whitespacesAndNewlines)
      }

      guard !text.isEmpty else { return nil }

      return LyricLine(
        timestamp: paragraph.begin,
        text: text,
        translation: paragraph.translation,
        wordOffsets: wordOffsets.count > 1 ? wordOffsets : nil
      )
    }.sorted { $0.timestamp < $1.timestamp }
  }

  func parser(
    _ parser: XMLParser,
    didStartElement elementName: String,
    namespaceURI: String?,
    qualifiedName qName: String?,
    attributes attributeDict: [String: String]
  ) {
    elementStack.append(elementName)

    switch elementName {
    case "p":
      paragraphKey = attributeDict["itunes:key"]
      paragraphBegin = Self.seconds(from: attributeDict["begin"])
      paragraphEnd = Self.seconds(from: attributeDict["end"])
      paragraphText = ""
      paragraphSpans = []
    case "span":
      if attributeDict["ttm:role"] == "x-bg" {
        backgroundDepth += 1
      }

      if let begin = attributeDict["begin"] {
        currentSpanBegin = Self.seconds(from: begin)
        currentSpanEnd = Self.seconds(from: attributeDict["end"])
        currentSpanText = ""
      }
    case "text":
      if isInside("translation") {
        currentTranslationKey = attributeDict["for"]
        currentTranslationText = ""
      }
    default:
      break
    }
  }

  func parser(_ parser: XMLParser, foundCharacters string: String) {
    if currentTranslationKey != nil {
      currentTranslationText += string
    } else if currentSpanBegin != nil {
      currentSpanText += string
    } else if paragraphKey != nil {
      paragraphText += string
    }
  }

  func parser(
    _ parser: XMLParser,
    didEndElement elementName: String,
    namespaceURI: String?,
    qualifiedName qName: String?
  ) {
    switch elementName {
    case "p":
      let translation = paragraphKey.flatMap { translations[$0] }
      paragraphs.append(
        Paragraph(
          text: paragraphText,
          begin: paragraphBegin,
          end: paragraphEnd,
          translation: translation,
          spans: paragraphSpans
        ))
      paragraphKey = nil
      paragraphText = ""
      paragraphSpans = []
    case "span":
      if let begin = currentSpanBegin {
        paragraphSpans.append(
          Span(
            text: currentSpanText,
            begin: begin,
            end: currentSpanEnd ?? begin,
            isBackground: backgroundDepth > 0
          ))
        currentSpanBegin = nil
        currentSpanEnd = nil
        currentSpanText = ""
      }

      if backgroundDepth > 0 {
        backgroundDepth -= 1
      }
    case "text":
      if let key = currentTranslationKey {
        let text = currentTranslationText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty {
          translations[key] = text
        }
        currentTranslationKey = nil
        currentTranslationText = ""
      }
    default:
      break
    }

    _ = elementStack.popLast()
  }

  private func isInside(_ elementName: String) -> Bool {
    elementStack.contains(elementName)
  }

  private static func seconds(from timeString: String?) -> TimeInterval {
    guard let timeString, !timeString.isEmpty else { return 0 }
    let parts = timeString.split(separator: ":").map(String.init)

    if parts.count == 3 {
      return (Double(parts[0]) ?? 0) * 3600 + (Double(parts[1]) ?? 0) * 60
        + (Double(parts[2]) ?? 0)
    }

    if parts.count == 2 {
      return (Double(parts[0]) ?? 0) * 60 + (Double(parts[1]) ?? 0)
    }

    return Double(timeString) ?? 0
  }
}
