//
//  CapsulePackage.swift
//  Ampwave
//
//  Self-contained Ampwave Capsule: manifest plus compressed audio files.
//

import Foundation
import SwiftData
import UniformTypeIdentifiers

enum CapsulePackage {
  static let fileExtension = "ampcap"
  static let contentType = UTType(
    exportedAs: "com.ampwave.capsule",
    conformingTo: .zip
  )

  @MainActor
  static func writeToTemporaryFile(
    capsule: AmpwaveCapsule,
    library: SongLibrary
  ) async throws -> URL {
    let songs = capsule.resolvedSongs(in: library)
    guard songs.count == capsule.songIDs.count else {
      throw packageError("Some Capsule songs are missing from your library.")
    }

    let tracks = songs.enumerated().map { index, song in
      CapsuleTrack(song: song, audioPath: audioPath(for: song, index: index))
    }
    let document = CapsuleDocument(capsule: capsule, tracks: tracks)
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let manifest = try encoder.encode(document)

    var sources = [ZipArchive.Source(path: "manifest.json", data: manifest)]
    for (song, track) in zip(songs, tracks) {
      let fileURL = library.getFileURL(for: song)
      let secured = fileURL.startAccessingSecurityScopedResource()
      let fileExists = FileManager.default.fileExists(atPath: fileURL.path)
      if secured { fileURL.stopAccessingSecurityScopedResource() }
      guard fileExists else {
        throw packageError("“\(song.title)” could not be found on this device.")
      }
      sources.append(ZipArchive.Source(path: track.audioPath, fileURL: fileURL))
    }

    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent(safeFilename(capsule.title))
      .appendingPathExtension(fileExtension)
    return try await Task.detached(priority: .userInitiated) {
      try ZipArchive.create(at: url, sources: sources)
      return url
    }.value
  }

  @MainActor
  static func importCapsule(
    from archiveURL: URL,
    into modelContext: ModelContext,
    library: SongLibrary
  ) async throws -> AmpwaveCapsule {
    let extractionURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("AmpwaveCapsuleImport-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: extractionURL) }

    try await Task.detached(priority: .userInitiated) {
      try ZipArchive.extract(archiveURL: archiveURL, to: extractionURL)
    }.value

    let manifestURL = extractionURL.appendingPathComponent("manifest.json")
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let document = try decoder.decode(
      CapsuleDocument.self,
      from: Data(contentsOf: manifestURL)
    )
    guard document.format == "ampwave-capsule", document.version <= CapsuleDocument.currentVersion else {
      throw packageError("This Capsule was created by a newer version of Ampwave.")
    }

    let audioURLs = document.tracks.compactMap { track -> URL? in
      let url = extractionURL.appendingPathComponent(track.audioPath)
      return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }
    guard audioURLs.count == document.tracks.count else {
      throw packageError("One or more audio files are missing from this Capsule.")
    }

    if library.modelContext == nil {
      library.setModelContext(modelContext)
    }
    await library.importFiles(audioURLs, forceCopy: true)

    let songs = document.tracks.compactMap { resolve($0, in: library) }
    guard songs.count == document.tracks.count else {
      throw packageError("Ampwave could not add every Capsule song to your library.")
    }

    let existing = try modelContext.fetch(FetchDescriptor<AmpwaveCapsule>())
      .first { $0.id == document.id }
    let capsule: AmpwaveCapsule
    if let existing {
      existing.title = document.title
      existing.capsuleDescription = document.description
      existing.personalMessage = document.personalMessage
      existing.creatorName = document.creatorName
      existing.lastModifiedDate = .now
      existing.songIDs = songs.map(\.id)
      existing.playExactlyAsCreated = document.playExactlyAsCreated
      capsule = existing
    } else {
      capsule = AmpwaveCapsule(
        id: document.id,
        title: document.title,
        description: document.description,
        personalMessage: document.personalMessage,
        creatorName: document.creatorName,
        createdDate: document.createdAt,
        songIDs: songs.map(\.id),
        playExactlyAsCreated: document.playExactlyAsCreated
      )
      modelContext.insert(capsule)
    }
    try modelContext.save()
    return capsule
  }

  private static func resolve(_ track: CapsuleTrack, in library: SongLibrary) -> LibrarySong? {
    if !track.fileHash.isEmpty,
      let exact = library.songs.first(where: { $0.fileHash == track.fileHash })
    {
      return exact
    }
    return nil
  }

  private static func audioPath(for song: LibrarySong, index: Int) -> String {
    let safeTitle = song.title
      .replacingOccurrences(of: "[^a-zA-Z0-9 _-]", with: "", options: .regularExpression)
      .trimmingCharacters(in: .whitespacesAndNewlines)
    let base = safeTitle.isEmpty ? "Track" : String(safeTitle.prefix(60))
    let fileExtension = URL(fileURLWithPath: song.fileName).pathExtension
    let suffix = fileExtension.isEmpty ? "" : ".\(fileExtension.lowercased())"
    return String(format: "audio/%03d - %@%@", index + 1, base, suffix)
  }

  private static func safeFilename(_ value: String) -> String {
    let cleaned = value
      .replacingOccurrences(of: "/", with: "-")
      .replacingOccurrences(of: ":", with: "-")
      .trimmingCharacters(in: .whitespacesAndNewlines)
    return cleaned.isEmpty ? "Ampwave Capsule" : String(cleaned.prefix(72))
  }

  private static func packageError(_ message: String) -> NSError {
    NSError(
      domain: "com.ampwave.capsule",
      code: 1,
      userInfo: [NSLocalizedDescriptionKey: message]
    )
  }
}

private struct CapsuleDocument: Codable {
  static let currentVersion = 2

  let format: String
  let version: Int
  let id: UUID
  let title: String
  let description: String?
  let personalMessage: String?
  let creatorName: String?
  let createdAt: Date
  let exportedAt: Date
  let playExactlyAsCreated: Bool
  let tracks: [CapsuleTrack]

  @MainActor
  init(capsule: AmpwaveCapsule, tracks: [CapsuleTrack]) {
    format = "ampwave-capsule"
    version = Self.currentVersion
    id = capsule.id
    title = capsule.title
    description = capsule.capsuleDescription
    personalMessage = capsule.personalMessage
    creatorName = capsule.creatorName
    createdAt = capsule.createdDate
    exportedAt = .now
    playExactlyAsCreated = capsule.playExactlyAsCreated
    self.tracks = tracks
  }
}

private struct CapsuleTrack: Codable, Sendable {
  let title: String
  let artist: String
  let album: String?
  let duration: TimeInterval
  let fileHash: String
  let isrc: String?
  let audioPath: String

  @MainActor
  init(song: LibrarySong, audioPath: String) {
    title = song.title
    artist = song.artist
    album = song.album
    duration = song.duration
    fileHash = song.fileHash
    isrc = song.isrc
    self.audioPath = audioPath
  }
}
