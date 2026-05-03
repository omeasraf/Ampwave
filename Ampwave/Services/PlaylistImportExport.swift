//
//  PlaylistImportExport.swift
//  Ampwave
//

import Foundation
import SwiftData
import UniformTypeIdentifiers

enum PlaylistImportExport {
  static let playlistUTType = UTType(filenameExtension: "m3u") ?? .plainText

  /// Writes an extended M3U with relative paths when under Documents.
  /// Writes M3U to a temporary file for sharing (reuses the same path while the playlist is unchanged).
  @MainActor
  static func writeM3UToTemp(playlist: Playlist, library: SongLibrary) throws -> URL {
    let safeName =
      playlist.name
      .replacingOccurrences(of: "/", with: "-")
      .replacingOccurrences(of: ":", with: "-")
      .prefix(72)
    let base = String(safeName).trimmingCharacters(in: .whitespacesAndNewlines)
    let filename =
      base.isEmpty
      ? "playlist-\(playlist.id.uuidString.prefix(8)).m3u" : "\(base).m3u"
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(filename)
    try makeM3UString(playlist: playlist, library: library).write(
      to: url, atomically: true, encoding: .utf8)
    return url
  }

  static func makeM3UString(playlist: Playlist, library: SongLibrary) -> String {
    var lines = ["#EXTM3U", "#PLAYLIST:\(playlist.name)"]
    for song in playlist.songs {
      let url = library.getFileURL(for: song)
      let dur = Int(song.duration)
      lines.append("#EXTINF:\(dur),\(song.artist) - \(song.title)")
      lines.append(url.path)
    }
    return lines.joined(separator: "\n")
  }

  @MainActor
  static func importM3U(
    data: Data, into modelContext: ModelContext, library: SongLibrary
  ) throws -> Playlist {
    guard let text = String(data: data, encoding: .utf8) else {
      throw NSError(domain: "Ampwave", code: 1, userInfo: [NSLocalizedDescriptionKey: "Invalid file"])
    }
    let pm = PlaylistManager.shared
    pm.setModelContext(modelContext)
    guard
      let playlist = pm.createPlaylist(
        name: "Imported \(Date().formatted(date: .abbreviated, time: .shortened))")
    else {
      throw NSError(
        domain: "Ampwave", code: 2,
        userInfo: [NSLocalizedDescriptionKey: "Could not create playlist"])
    }
    var pending: [LibrarySong] = []
    var currentTitle: String?
    for raw in text.components(separatedBy: .newlines) {
      let line = raw.trimmingCharacters(in: .whitespaces)
      if line.hasPrefix("#EXTINF:") {
        let parts = line.dropFirst(8).split(separator: ",", maxSplits: 1)
        currentTitle = parts.count > 1 ? String(parts[1]) : nil
        continue
      }
      if line.isEmpty || line.hasPrefix("#") { continue }
      let url = URL(fileURLWithPath: line)
      if let song = library.songs.first(where: { library.getFileURL(for: $0).standardizedFileURL == url.standardizedFileURL }) {
        pending.append(song)
      } else if FileManager.default.fileExists(atPath: url.path),
        let song = library.songs.first(where: { $0.fileName == url.lastPathComponent })
      {
        pending.append(song)
      } else {
        print("[PlaylistImport] Skipped missing: \(line) hint:\(currentTitle ?? "")")
      }
    }
    for song in pending {
      pm.addSong(song, to: playlist)
    }
    return playlist
  }
}
