//
//  LyricsService.swift
//  Ampwave
//

import Foundation
import Observation
import SwiftData

extension Notification.Name {
  /// Posted whenever a song's cached lyrics change, with the song's `UUID` as
  /// the object. Lets the player refresh what it's displaying when lyrics are
  /// fetched or edited from somewhere else (the song editor, a background
  /// pass) rather than only at track start.
  static let lyricsDidUpdate = Notification.Name("com.ampwave.lyricsDidUpdate")
}

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

  /// Collects every lyric representation available for `song` — word-synced,
  /// line-synced and plain — and caches them together.
  ///
  /// All three are gathered regardless of the word-synced *preference*: that
  /// setting decides what gets drawn, not what gets stored. Fetching only the
  /// preferred form meant toggling the setting mid-song showed nothing until a
  /// refetch, and losing word timings whenever a later pass found line-synced
  /// lyrics first.
  /// - Parameters:
  ///   - forceRefresh: skips the cache, the embedded tag and the re-check
  ///     throttle, so an explicit refresh really does re-query the providers
  ///     instead of re-seeding from what's already stored.
  ///   - includeWordSynced: whether to ask the word-synced providers. Bulk
  ///     import passes `false` — those endpoints rate-limit hard, and firing
  ///     one request per song across a whole library gets us throttled. Word
  ///     timings are then picked up per-song on first play instead.
  func fetchLyrics(
    for song: LibrarySong,
    forceRefresh: Bool = false,
    includeWordSynced: Bool = true
  ) async -> SyncedLyric? {
    guard let modelContext = modelContext else { return nil }
    let preferences = UserPreferences.getOrCreate(in: modelContext)

    // Seed from whatever is already known, so a partial cache is topped up
    // rather than thrown away and refetched.
    var lines: [LyricLine] = []
    var plain: String?
    var source: LyricSource = .local
    var language: String?

    let cached = getCachedLyrics(for: song)
    if let cached, !forceRefresh {
      lines = cached.lines
      plain = cached.plainLyrics
      source = cached.source
      language = cached.language
    }

    // Offline sources first — a sidecar .lrc costs nothing and is authoritative
    // if the user dropped one next to the file.
    if lines.isEmpty, let sidecar = localSidecarLyrics(for: song) {
      lines = sidecar
      source = .local
    }

    let embedded = song.lyrics ?? ""
    if !embedded.isEmpty, !forceRefresh {
      let embeddedLines = LRCParser.parse(embedded)
      if lines.isEmpty, !embeddedLines.isEmpty {
        lines = embeddedLines
        source = .local
      }
      // An embedded tag with no parseable timings is still a fine plain copy —
      // but run it through the sanitizer, since "unparseable" doesn't mean
      // "unmarked" and raw timings must never reach the plain tier.
      if embeddedLines.isEmpty, plain?.isEmpty ?? true {
        let sanitized = LRCParser.plainText(from: embedded)
        if !sanitized.isEmpty { plain = sanitized }
      }
    }

    // Nothing left for a provider to add — don't go online at all. When word
    // timings are out of scope for this pass, line-synced counts as complete
    // so a bulk import doesn't keep retrying for them.
    let syncGoalMet = includeWordSynced ? hasWordSyncedLyrics(lines) : !lines.isEmpty
    let isComplete = syncGoalMet && !(plain?.isEmpty ?? true)

    // Otherwise we try exactly once, then not again for a week. Without this,
    // a song with no lyrics upstream would hit every provider on every play.
    let recheckInterval: TimeInterval = 7 * 24 * 60 * 60
    let triedRecently =
      cached?.lastFetchAttemptAt.map { Date().timeIntervalSince($0) < recheckInterval } ?? false

    let canGoOnline =
      preferences.autoFetchLyrics
      && NetworkMonitor.shared.isOnline
      && !preferences.isOfflineMode
      && !isComplete
      && (forceRefresh || !triedRecently)

    if canGoOnline {
      // 1. Word-synced providers — the richest form, so try them first.
      if includeWordSynced, !hasWordSyncedLyrics(lines),
        let wordSynced = await fetchFromWordSyncedProviders(song: song)
      {
        lines = wordSynced.lines
        source = wordSynced.source
        language = wordSynced.language ?? language
      }

      // 2. LRCLIB returns line-synced *and* plain in one response; ask when
      //    either is still missing.
      if lines.isEmpty || (plain?.isEmpty ?? true) {
        let result = await fetchFromLRCLIB(song: song)
        if lines.isEmpty, let synced = result.synced {
          lines = synced.lines
          source = .lrclib
          language = synced.language ?? language
        }
        if plain?.isEmpty ?? true, let fetchedPlain = result.plain {
          plain = fetchedPlain
        }
      }

      // 3. Last resort, plain text only.
      if plain?.isEmpty ?? true, let ovh = await fetchFromLyricsOVH(song: song) {
        plain = ovh
      }
    }

    guard !lines.isEmpty || !(plain?.isEmpty ?? true) else {
      // Genuinely nothing upstream. Record the attempt so we wait a week
      // before asking again — but only if we actually went looking, or an
      // offline play would block the next online one.
      if canGoOnline {
        let placeholder = SyncedLyric(songId: song.id, lines: [], source: source)
        // Same reasoning as above: a partial pass records that we looked, but
        // doesn't start the week-long cooldown.
        if includeWordSynced { placeholder.lastFetchAttemptAt = Date() }
        cacheLyrics(placeholder)
      }
      return nil
    }

    // Flattening synced lines gives a plain copy for free when no provider
    // supplied one, so the plain tier is always populated.
    if plain?.isEmpty ?? true, !lines.isEmpty {
      plain = lines.map(\.text).joined(separator: "\n")
    }

    let merged = SyncedLyric(
      songId: song.id,
      lines: lines,
      source: source,
      language: language,
      plainLyrics: plain
    )
    // Only stamp after a *full* attempt. A purely local hit shouldn't start a
    // cooldown, and neither should a bulk-import pass that deliberately skipped
    // the word-synced providers — otherwise first play would find the song
    // "recently tried" and never go looking for word timings.
    if canGoOnline, includeWordSynced {
      merged.lastFetchAttemptAt = Date()
    }
    let stored = cacheLyrics(merged)

    song.lyrics = lines.isEmpty ? plain : LRCParser.toLRC(lines)
    song.updateSearchIndex()
    try? modelContext.save()

    return stored
  }

  /// Lines from a `.lrc` file sitting next to the audio file, if present.
  private func localSidecarLyrics(for song: LibrarySong) -> [LyricLine]? {
    let url = SongLibrary.shared.getFileURL(for: song)
    let lrcURL = url.deletingPathExtension().appendingPathExtension("lrc")

    // Referenced files live outside the container; the sidecar needs the same
    // security-scoped access the audio file does.
    let secured = lrcURL.startAccessingSecurityScopedResource()
    defer { if secured { lrcURL.stopAccessingSecurityScopedResource() } }

    guard FileManager.default.fileExists(atPath: lrcURL.path),
      let content = try? String(contentsOf: lrcURL, encoding: .utf8)
    else { return nil }

    let lines = LRCParser.parse(content)
    return lines.isEmpty ? nil : lines
  }

  private func hasWordSyncedLyrics(_ lines: [LyricLine]) -> Bool {
    lines.contains { ($0.wordOffsets?.count ?? 0) > 1 }
  }

  /// Fetches word-level timings specifically.
  ///
  /// Deliberately *not* gated on `wordSyncedLyricsEnabled` — that preference
  /// controls rendering. Gating the fetch meant a user who turned the setting
  /// on later had nothing cached to show.
  func fetchWordSyncedLyrics(for song: LibrarySong) async -> SyncedLyric? {
    guard let modelContext = modelContext else { return nil }
    let preferences = UserPreferences.getOrCreate(in: modelContext)

    guard NetworkMonitor.shared.isOnline,
      !preferences.isOfflineMode,
      let wordSynced = await fetchFromWordSyncedProviders(song: song)
    else { return nil }

    // Carry the existing plain copy across — the word-synced provider doesn't
    // supply one, and dropping it would demote a complete cache.
    wordSynced.plainLyrics =
      getCachedLyrics(for: song)?.plainLyrics
      ?? wordSynced.lines.map(\.text).joined(separator: "\n")

    let cached = cacheLyrics(wordSynced)
    song.lyrics = LRCParser.toLRC(cached.lines)
    song.updateSearchIndex()
    try? modelContext.save()
    SongLibrary.shared.notifyLibraryChange()
    return cached
  }

  /// Online-only fetch for explicit "get lyrics now" actions.
  ///
  /// Shares the unified path so it collects all three tiers too. It used to
  /// delete cached synced lyrics whenever a provider returned only plain text,
  /// which silently downgraded songs that already had good timings.
  func fetchOnlineLyrics(for song: LibrarySong) async -> SyncedLyric? {
    await fetchLyrics(for: song, forceRefresh: true)
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

      // The response carries both forms; keep whichever are present rather
      // than treating them as alternatives.
      let plain = lrclibResponse.plainLyrics.flatMap { $0.isEmpty ? nil : $0 }

      if let syncedLyrics = lrclibResponse.syncedLyrics, !syncedLyrics.isEmpty {
        let lines = LRCParser.parse(syncedLyrics)
        if !lines.isEmpty {
          let synced = SyncedLyric(
            songId: song.id,
            lines: lines,
            source: .lrclib,
            language: lrclibResponse.language
          )
          return (synced, plain)
        }
      }

      return (nil, plain)
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
      // Never let an update blank out a plain copy we already had.
      if let incoming = lyrics.plainLyrics, !incoming.isEmpty {
        existing.plainLyrics = incoming
      }
      if let attempted = lyrics.lastFetchAttemptAt {
        existing.lastFetchAttemptAt = attempted
      }
      existing.lastUpdated = Date()
      try? modelContext.save()
      notifyLyricsChanged(songId: existing.songId)
      return existing
    } else {
      modelContext.insert(lyrics)
      try? modelContext.save()
      notifyLyricsChanged(songId: lyrics.songId)
      return lyrics
    }
  }

  private func notifyLyricsChanged(songId: UUID) {
    NotificationCenter.default.post(name: .lyricsDidUpdate, object: songId)
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
    return await fetchLyrics(for: song, forceRefresh: true)
  }

  func saveLyrics(for song: LibrarySong, content: String) {
    guard let modelContext = modelContext else { return }

    let lines = LRCParser.parse(content)
    if !lines.isEmpty {
      // It's LRC format
      let syncedLyric = SyncedLyric(
        songId: song.id,
        lines: lines,
        source: .user,
        language: nil,
        plainLyrics: lines.map(\.text).joined(separator: "\n")
      )
      cacheLyrics(syncedLyric)
    } else {
      // Plain text the user typed in: store it as the plain tier and drop the
      // stale timings, since they no longer describe this text.
      let plainLyric = SyncedLyric(
        songId: song.id,
        lines: [],
        source: .user,
        language: nil,
        plainLyrics: content
      )
      clearCachedLyrics(for: song)
      cacheLyrics(plainLyric)
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
