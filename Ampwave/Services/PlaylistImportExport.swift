//
//  PlaylistImportExport.swift
//  Ampwave
//

import Foundation
import SwiftData
import UniformTypeIdentifiers

enum PlaylistImportExport {
  static let playlistM3UType = UTType(filenameExtension: "m3u") ?? .plainText
  static let playlistJSONType = UTType.json
  static let playlistUTType = playlistM3UType
  static let importableContentTypes: [UTType] = [playlistJSONType, playlistM3UType, .plainText]

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
      lines.append("#EXTINF:\(duration),\(track.artist) - \(track.title)")
      if let songID = track.songID { lines.append("#AMPWAVE-ID:\(songID)") }
      if let fileHash = track.fileHash { lines.append("#AMPWAVE-HASH:\(fileHash)") }
      if let album = track.album, !album.isEmpty { lines.append("#AMPWAVE-ALBUM:\(album)") }
      if let duration = track.duration { lines.append("#AMPWAVE-DURATION:\(duration)") }
      lines.append(track.fileName ?? track.title)
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
    return try importM3U(data: data, into: modelContext, library: library)
  }

  @MainActor
  static func importM3U(
    data: Data,
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
      let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
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

      if line.hasPrefix("#AMPWAVE-ID:") {
        pending.songID = String(line.dropFirst("#AMPWAVE-ID:".count))
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

      pending.identifier = line
      importedTracks.append(pending.asTrack())
      pending = PendingM3UEntry()
    }

    return try makeImportedPlaylist(
      name: playlistName,
      tracks: importedTracks,
      into: modelContext,
      library: library
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
    library: SongLibrary
  ) throws -> Playlist {
    let playlistManager = PlaylistManager.shared
    playlistManager.setModelContext(modelContext)

    let trimmedName = name?.trimmingCharacters(in: .whitespacesAndNewlines)
    let playlistTitle =
      (trimmedName?.isEmpty == false ? trimmedName : nil)
      ?? "Imported \(Date().formatted(date: .abbreviated, time: .shortened))"

    guard let playlist = playlistManager.createPlaylist(name: playlistTitle) else {
      throw importError("Could not create playlist.")
    }

    let resolvedSongs = tracks.compactMap { resolveSong(from: $0, library: library) }
    for song in resolvedSongs {
      playlistManager.addSong(song, to: playlist)
    }

    return playlist
  }

  private static func resolveSong(from track: PortableTrackDocument, library: SongLibrary)
    -> LibrarySong?
  {
    if let songID = track.songID,
      let uuid = UUID(uuidString: songID),
      let match = library.songs.first(where: { $0.id == uuid })
    {
      return match
    }

    if let fileHash = track.fileHash, !fileHash.isEmpty,
      let match = library.songs.first(where: { $0.fileHash == fileHash })
    {
      return match
    }

    if let identifier = track.identifier?.trimmingCharacters(in: .whitespacesAndNewlines),
      !identifier.isEmpty
    {
      let normalizedIdentifier = normalize(identifier)
      if let match = library.songs.first(where: {
        normalize($0.fileName) == normalizedIdentifier
      }) {
        return match
      }
    }

    let normalizedTitle = normalize(track.title)
    let normalizedArtist = normalize(track.artist)
    let normalizedAlbum = normalize(track.album ?? "")

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
      if let fileName = track.fileName, normalize(song.fileName) == normalize(fileName) {
        score += 1.5
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
    version: Int = 1,
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
  let songID: String?
  let fileHash: String?
  let title: String
  let artist: String
  let album: String?
  let duration: TimeInterval?
  let fileName: String?
  let identifier: String?

  init(
    songID: String? = nil,
    fileHash: String? = nil,
    title: String,
    artist: String,
    album: String? = nil,
    duration: TimeInterval? = nil,
    fileName: String? = nil,
    identifier: String? = nil
  ) {
    self.songID = songID
    self.fileHash = fileHash
    self.title = title
    self.artist = artist
    self.album = album
    self.duration = duration
    self.fileName = fileName
    self.identifier = identifier
  }

  init(song: LibrarySong, library: SongLibrary) {
    let resolvedFileName = library.getFileURL(for: song).lastPathComponent
    self.init(
      songID: song.id.uuidString,
      fileHash: song.fileHash,
      title: song.title,
      artist: song.artist,
      album: song.album,
      duration: song.duration > 0 ? song.duration : nil,
      fileName: resolvedFileName,
      identifier: resolvedFileName
    )
  }
}

private struct PendingM3UEntry {
  var songID: String?
  var fileHash: String?
  var title: String = "Unknown Title"
  var artist: String = "Unknown Artist"
  var album: String?
  var duration: TimeInterval?
  var identifier: String?

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
      artist = parts[0].trimmingCharacters(in: .whitespacesAndNewlines)
      title = parts.dropFirst().joined(separator: " - ").trimmingCharacters(
        in: .whitespacesAndNewlines)
    } else {
      title = metadata.trimmingCharacters(in: .whitespacesAndNewlines)
    }
  }

  func asTrack() -> PortableTrackDocument {
    PortableTrackDocument(
      songID: songID,
      fileHash: fileHash,
      title: title,
      artist: artist,
      album: album,
      duration: duration,
      fileName: identifier,
      identifier: identifier
    )
  }
}
