//
//  PlaylistImportExport.swift
//  Ampwave
//

import Foundation
import SwiftData
import UniformTypeIdentifiers

enum PlaylistImportExport {
  static let playlistM3UType = UTType(filenameExtension: "m3u") ?? .plainText
  static let playlistM3U8Type = UTType(filenameExtension: "m3u8") ?? .plainText
  static let playlistJSONType = UTType.json
  static let playlistUTType = playlistM3UType
  static let importableContentTypes: [UTType] = [
    playlistJSONType, playlistM3UType, playlistM3U8Type, .plainText,
  ]

  @MainActor
  static func writeJSONToTemp(playlist: Playlist, library: SongLibrary) throws -> URL {
    let filename = exportFilename(for: playlist, pathExtension: "json")
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(filename)
    let payload = PortablePlaylistDocument(playlist: playlist, library: library)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    encoder.dateEncodingStrategy = .iso8601
    try encoder.encode(payload).write(to: url, options: .atomic)
    return url
  }

  @MainActor
  static func writeM3UToTemp(playlist: Playlist, library: SongLibrary) throws -> URL {
    let filename = exportFilename(for: playlist, pathExtension: "m3u")
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(filename)
    try makeM3UString(playlist: playlist, library: library).write(
      to: url,
      atomically: true,
      encoding: .utf8
    )
    return url
  }

  static func makeM3UString(playlist: Playlist, library: SongLibrary) -> String {
    let portable = PortablePlaylistDocument(playlist: playlist, library: library)
    var lines = [
      "#EXTM3U",
      "#PLAYLIST:\(playlist.name)",
      "#AMPWAVE-FORMAT:\(portable.format)",
      "#AMPWAVE-VERSION:\(portable.version)",
    ]

    for track in portable.tracks {
      let duration = Int(track.duration ?? 0)
      lines.append("#EXTINF:\(duration),\(track.artistName) - \(track.songName)")
      if let fileHash = track.hash { lines.append("#AMPWAVE-HASH:\(fileHash)") }
      if let album = track.albumName, !album.isEmpty { lines.append("#AMPWAVE-ALBUM:\(album)") }
      if let duration = track.duration { lines.append("#AMPWAVE-DURATION:\(duration)") }
      lines.append("\(track.artistName) - \(track.songName)")
    }

    return lines.joined(separator: "\n")
  }

  @MainActor
  static func importPlaylist(
    data: Data,
    sourceURL: URL?,
    into modelContext: ModelContext,
    library: SongLibrary
  ) throws -> Playlist {
    if shouldTreatAsJSON(data: data, sourceURL: sourceURL) {
      return try importJSON(data: data, into: modelContext, library: library)
    }
    return try importM3U(
      data: data,
      sourceURL: sourceURL,
      into: modelContext,
      library: library
    )
  }

  @MainActor
  static func importM3U(
    data: Data,
    sourceURL: URL?,
    into modelContext: ModelContext,
    library: SongLibrary
  ) throws -> Playlist {
    guard let text = String(data: data, encoding: .utf8) else {
      throw importError("Invalid M3U file.")
    }

    var playlistName: String?
    var importedTracks: [PortableTrackDocument] = []
    var pending = PendingM3UEntry()

    for rawLine in text.components(separatedBy: .newlines) {
      // UTF-8 playlists produced on Windows often start with a BOM. Treat it
      // as encoding metadata, not as part of the first directive or path.
      let line = rawLine.trimmingCharacters(
        in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "\u{FEFF}"))
      )
      guard !line.isEmpty else { continue }

      if line.hasPrefix("#PLAYLIST:") {
        playlistName = String(line.dropFirst("#PLAYLIST:".count)).trimmingCharacters(
          in: .whitespacesAndNewlines)
        continue
      }

      if line.hasPrefix("#EXTINF:") {
        pending.applyEXTINF(line)
        continue
      }

      if line.hasPrefix("#AMPWAVE-HASH:") {
        pending.fileHash = String(line.dropFirst("#AMPWAVE-HASH:".count))
        continue
      }

      if line.hasPrefix("#AMPWAVE-ALBUM:") {
        pending.album = String(line.dropFirst("#AMPWAVE-ALBUM:".count))
        continue
      }

      if line.hasPrefix("#AMPWAVE-DURATION:") {
        pending.duration = Double(String(line.dropFirst("#AMPWAVE-DURATION:".count)))
        continue
      }

      if line.hasPrefix("#") { continue }

      // Standard M3U/M3U8 files put the audio path on this line. Keep it so
      // referenced songs can be matched against their original Files URLs.
      pending.filePath = line

      // Ampwave's portable format uses "Artist - Title" here. Standard M3U
      // files normally already supplied that information through EXTINF.
      if pending.songName == "Unknown Title" {
        let parts = line.components(separatedBy: " - ")
        if parts.count >= 2 {
          pending.artistName = parts[0].trimmingCharacters(in: .whitespacesAndNewlines)
          pending.songName = parts.dropFirst().joined(separator: " - ").trimmingCharacters(
            in: .whitespacesAndNewlines)
        }
      }

      importedTracks.append(pending.asTrack())
      pending = PendingM3UEntry()
    }

    return try makeImportedPlaylist(
      name: playlistName ?? sourceURL?.deletingPathExtension().lastPathComponent,
      tracks: importedTracks,
      into: modelContext,
      library: library,
      playlistURL: sourceURL
    )
  }

  @MainActor
  static func importJSON(
    data: Data,
    into modelContext: ModelContext,
    library: SongLibrary
  ) throws -> Playlist {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let payload = try decoder.decode(PortablePlaylistDocument.self, from: data)
    return try makeImportedPlaylist(
      name: payload.name,
      tracks: payload.tracks,
      into: modelContext,
      library: library
    )
  }

  private static func makeImportedPlaylist(
    name: String?,
    tracks: [PortableTrackDocument],
    into modelContext: ModelContext,
    library: SongLibrary,
    playlistURL: URL? = nil
  ) throws -> Playlist {
    let playlistManager = PlaylistManager.shared
    playlistManager.setModelContext(modelContext)

    let trimmedName = name?.trimmingCharacters(in: .whitespacesAndNewlines)
    let playlistTitle =
      (trimmedName?.isEmpty == false ? trimmedName : nil)
      ?? "Imported \(Date().formatted(date: .abbreviated, time: .shortened))"

    let resolvedSongs = tracks.compactMap {
      resolveSong(from: $0, playlistURL: playlistURL, library: library)
    }
    if !tracks.isEmpty && resolvedSongs.isEmpty {
      throw importError(
        "None of the playlist's songs could be matched. Import or reference the music folder first, then try the playlist again."
      )
    }

    guard let playlist = playlistManager.createPlaylist(name: playlistTitle) else {
      throw importError("Could not create playlist.")
    }

    for song in resolvedSongs {
      playlistManager.addSong(song, to: playlist)
    }

    return playlist
  }

  private static func resolveSong(
    from track: PortableTrackDocument,
    playlistURL: URL?,
    library: SongLibrary
  ) -> LibrarySong?
  {
    // 1. Match by hash first (most reliable)
    if let fileHash = track.hash, !fileHash.isEmpty,
      let match = library.songs.first(where: { $0.fileHash == fileHash })
    {
      return match
    }

    // 2. Resolve standard relative/absolute M3U paths. Referenced songs retain
    // their original URL, so this works without copying them into Ampwave.
    if let filePath = track.filePath,
      let match = resolveSongByPath(filePath, playlistURL: playlistURL, library: library)
    {
      return match
    }

    // 3. Fall back to metadata matching
    let normalizedTitle = normalize(track.songName)
    let normalizedArtist = normalize(track.artistName)
    let normalizedAlbum = normalize(track.albumName ?? "")

    let rankedMatches = library.songs.compactMap { song -> (LibrarySong, Double)? in
      let songTitle = normalize(song.title)
      let songArtist = normalize(song.artist)
      let songAlbum = normalize(song.album ?? "")

      guard songTitle == normalizedTitle, songArtist == normalizedArtist else {
        return nil
      }

      var score = 0.0
      if songTitle == normalizedTitle { score += 5.0 }
      if songArtist == normalizedArtist { score += 5.0 }
      if !normalizedAlbum.isEmpty, songAlbum == normalizedAlbum { score += 2.0 }
      if let duration = track.duration, duration > 0 {
        let delta = abs(song.duration - duration)
        if delta <= 1.5 {
          score += 2.5
        } else if delta <= 4 {
          score += 1.0
        } else {
          score -= min(delta / 10, 2.5)
        }
      }
      return score >= 8 ? (song, score) : nil
    }

    return
      rankedMatches
      .sorted { lhs, rhs in
        if lhs.1 == rhs.1 {
          return lhs.0.importedDate > rhs.0.importedDate
        }
        return lhs.1 > rhs.1
      }
      .first?.0
  }

  private static func resolveSongByPath(
    _ rawPath: String,
    playlistURL: URL?,
    library: SongLibrary
  ) -> LibrarySong? {
    let path = normalizedPlaylistPath(rawPath)
    guard !path.isEmpty else { return nil }

    let referencedURLs = library.songs.map { song in
      (song, library.getFileURL(for: song).standardizedFileURL)
    }

    // Relative entries are relative to the playlist file, per the M3U format.
    if let playlistURL, !isAbsolutePlaylistPath(path) {
      let candidate = playlistURL.deletingLastPathComponent()
        .appendingPathComponent(path)
        .standardizedFileURL
      if let exact = referencedURLs.first(where: { $0.1.path == candidate.path }) {
        return exact.0
      }
    } else if path.hasPrefix("/") {
      let candidate = URL(fileURLWithPath: path).standardizedFileURL
      if let exact = referencedURLs.first(where: { $0.1.path == candidate.path }) {
        return exact.0
      }
    }

    // A Windows absolute path cannot exist verbatim on iOS, but the trailing
    // relative hierarchy usually remains the same after the folder is synced.
    let comparablePath = normalizePathForComparison(path)
    let suffixMatches = referencedURLs.filter {
      let actual = normalizePathForComparison($0.1.path)
      return actual == comparablePath || actual.hasSuffix("/" + comparablePath)
    }
    if suffixMatches.count == 1 { return suffixMatches[0].0 }

    // MusicBee playlists commonly retain just enough Windows-only prefix to
    // prevent a full suffix match. A unique filename is still deterministic.
    let fileName = URL(fileURLWithPath: path).lastPathComponent
    let fileNameMatches = referencedURLs.filter {
      $0.1.lastPathComponent.compare(fileName, options: [.caseInsensitive]) == .orderedSame
        || $0.0.fileName.compare(fileName, options: [.caseInsensitive]) == .orderedSame
    }
    return fileNameMatches.count == 1 ? fileNameMatches[0].0 : nil
  }

  private static func normalizedPlaylistPath(_ rawPath: String) -> String {
    var path = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
    if path.hasPrefix("\"") && path.hasSuffix("\"") && path.count >= 2 {
      path.removeFirst()
      path.removeLast()
    }
    path = path.replacingOccurrences(of: "\\", with: "/")
    if let decoded = path.removingPercentEncoding { path = decoded }
    if path.lowercased().hasPrefix("file://"), let url = URL(string: path) {
      return url.path
    }
    return path
  }

  private static func isAbsolutePlaylistPath(_ path: String) -> Bool {
    path.hasPrefix("/")
      || path.range(of: #"^[A-Za-z]:/"#, options: .regularExpression) != nil
  }

  private static func normalizePathForComparison(_ path: String) -> String {
    path
      .replacingOccurrences(of: "\\", with: "/")
      .replacingOccurrences(of: #"^[A-Za-z]:/"#, with: "", options: .regularExpression)
      .split(separator: "/")
      .filter { $0 != "." && $0 != ".." }
      .joined(separator: "/")
      .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
      .lowercased()
  }

  private static func shouldTreatAsJSON(data: Data, sourceURL: URL?) -> Bool {
    if sourceURL?.pathExtension.lowercased() == "json" {
      return true
    }

    guard
      let firstNonWhitespace = String(data: data, encoding: .utf8)?
        .trimmingCharacters(in: .whitespacesAndNewlines)
        .first
    else {
      return false
    }
    return firstNonWhitespace == "{"
  }

  private static func exportFilename(for playlist: Playlist, pathExtension: String) -> String {
    let safeName =
      playlist.name
      .replacingOccurrences(of: "/", with: "-")
      .replacingOccurrences(of: ":", with: "-")
      .prefix(72)
    let base = String(safeName).trimmingCharacters(in: .whitespacesAndNewlines)
    if base.isEmpty {
      return "playlist-\(playlist.id.uuidString.prefix(8)).\(pathExtension)"
    }
    return "\(base).\(pathExtension)"
  }

  private static func normalize(_ value: String) -> String {
    value
      .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
      .replacingOccurrences(of: "[^a-z0-9 ]", with: " ", options: .regularExpression)
      .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .lowercased()
  }

  private static func importError(_ message: String) -> NSError {
    NSError(
      domain: "Ampwave",
      code: 1,
      userInfo: [NSLocalizedDescriptionKey: message]
    )
  }
}

private struct PortablePlaylistDocument: Codable {
  let format: String
  let version: Int
  let name: String
  let exportedAt: Date
  let tracks: [PortableTrackDocument]

  init(
    format: String = "ampwave-playlist",
    version: Int = 2,
    name: String,
    exportedAt: Date = .now,
    tracks: [PortableTrackDocument]
  ) {
    self.format = format
    self.version = version
    self.name = name
    self.exportedAt = exportedAt
    self.tracks = tracks
  }

  init(playlist: Playlist, library: SongLibrary) {
    self.init(
      name: playlist.name,
      tracks: playlist.orderedSongs.map { PortableTrackDocument(song: $0, library: library) }
    )
  }
}

private struct PortableTrackDocument: Codable {
  let songName: String
  let artistName: String
  let albumName: String?
  let duration: TimeInterval?
  let hash: String?
  let filePath: String?

  init(
    songName: String,
    artistName: String,
    albumName: String? = nil,
    duration: TimeInterval? = nil,
    hash: String? = nil,
    filePath: String? = nil
  ) {
    self.songName = songName
    self.artistName = artistName
    self.albumName = albumName
    self.duration = duration
    self.hash = hash
    self.filePath = filePath
  }

  init(song: LibrarySong, library: SongLibrary) {
    self.init(
      songName: song.title,
      artistName: song.artist,
      albumName: song.album,
      duration: song.duration > 0 ? song.duration : nil,
      hash: song.fileHash,
      filePath: nil
    )
  }
}

private struct PendingM3UEntry {
  var songName: String = "Unknown Title"
  var artistName: String = "Unknown Artist"
  var album: String?
  var duration: TimeInterval?
  var fileHash: String?
  var filePath: String?

  mutating func applyEXTINF(_ line: String) {
    let payload = String(line.dropFirst("#EXTINF:".count))
    let pieces = payload.split(separator: ",", maxSplits: 1).map(String.init)

    if let first = pieces.first {
      duration = Double(first)
    }

    guard pieces.count > 1 else { return }
    let metadata = pieces[1]
    let parts = metadata.components(separatedBy: " - ")
    if parts.count >= 2 {
      artistName = parts[0].trimmingCharacters(in: .whitespacesAndNewlines)
      songName = parts.dropFirst().joined(separator: " - ").trimmingCharacters(
        in: .whitespacesAndNewlines)
    } else {
      songName = metadata.trimmingCharacters(in: .whitespacesAndNewlines)
    }
  }

  func asTrack() -> PortableTrackDocument {
    PortableTrackDocument(
      songName: songName,
      artistName: artistName,
      albumName: album,
      duration: duration,
      hash: fileHash,
      filePath: filePath
    )
  }
}
