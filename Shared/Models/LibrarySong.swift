//
//  LibrarySong.swift
//  Ampwave
//
//  SwiftData model for a song in the user's library.
//

import CryptoKit
import Foundation
import SwiftData

@Model
final class LibrarySong: Identifiable, Hashable {
  enum StorageMode: String, Codable {
    case copied
    case referenced
  }

  enum ArtworkSource: String, Codable {
    case embedded
    case online
    case user
  }

  // MARK: - Required (identity & storage)
  @Attribute(.unique) var id: UUID
  var fileName: String
  var fileHash: String
  var importedDate: Date
  var size: Int
  var storageModeRaw: String = "copied"
  var bookmarkData: Data?

  var storageMode: StorageMode {
    get { StorageMode(rawValue: storageModeRaw) ?? .copied }
    set { storageModeRaw = newValue.rawValue }
  }

  // MARK: - Core display
  var title: String
  var artist: String
  @Attribute(.externalStorage) var artists: [String]  // All artists (parsed from artist field)
  var duration: TimeInterval

  // MARK: - Extended metadata (optional)
  var lyrics: String?
  var album: String?
  var albumArtist: String?
  var genre: String?
  var songDescription: String?
  var trackNumber: Int?
  var discNumber: Int?
  var year: Int?
  var composer: String?
  var artworkPath: String?
  var embeddedArtworkPath: String?
  var isRemoteArtwork: Bool = false
  var artworkSourceRaw: String = "embedded"
  @Attribute(.externalStorage) var userEditedFields: [String] = []
  var albumReference: Album?

  var artworkSource: ArtworkSource {
    get { ArtworkSource(rawValue: artworkSourceRaw) ?? (isRemoteArtwork ? .online : .embedded) }
    set { artworkSourceRaw = newValue.rawValue }
  }

  /// Returns the song's artwork path, falling back to the album's artwork if available.
  var effectiveArtworkPath: String? {
    artworkPath ?? albumReference?.artworkPath
  }

  @Relationship(inverse: \Playlist.songs)
  var playlists: [Playlist]? = []

  // MARK: - Technical metadata
  var sampleRate: Double?
  var bitDepth: Int?
  var bitRate: Int?  // in kbps
  var channels: Int?
  var format: String?
  var source: String?
  var output: String?
  var mode: String?
  var processingChain: String?

  // MARK: - Search Indexing
  var searchIndex: String? = ""

  // MARK: - Fetching status
  var metadataCheckAttempted: Bool = false
  var lyricsCheckAttempted: Bool = false

  // MARK: - Watch Sync status
  var shouldSyncToWatch: Bool = false

  init(
    title: String,
    artist: String,
    fileName: String,
    fileHash: String,
    size: Int,
    duration: TimeInterval = 0,
    lyrics: String? = nil,
    album: String? = nil,
    albumArtist: String? = nil,
    genre: String? = nil,
    songDescription: String? = nil,
    trackNumber: Int? = nil,
    discNumber: Int? = nil,
    year: Int? = nil,
    composer: String? = nil,
    artworkPath: String? = nil,
    embeddedArtworkPath: String? = nil,
    isRemoteArtwork: Bool = false,
    sampleRate: Double? = nil,
    bitDepth: Int? = nil,
    bitRate: Int? = nil,
    channels: Int? = nil,
    format: String? = nil,
    source: String? = nil,
    output: String? = nil,
    mode: String? = nil,
    processingChain: String? = nil,
    shouldSyncToWatch: Bool = false,
    storageMode: StorageMode = .copied,
    bookmarkData: Data? = nil
  ) {
    self.id = UUID()
    self.title = title
    self.artist = artist
    self.artists = ArtistParser.parseArtists(from: artist)
    self.fileName = fileName
    self.fileHash = fileHash
    self.size = size
    self.importedDate = Date()
    self.duration = duration
    self.lyrics = lyrics
    self.album = album
    self.albumArtist = albumArtist
    self.genre = genre
    self.songDescription = songDescription
    self.trackNumber = trackNumber
    self.discNumber = discNumber
    self.year = year
    self.composer = composer
    self.artworkPath = artworkPath
    self.embeddedArtworkPath = embeddedArtworkPath
    self.isRemoteArtwork = isRemoteArtwork
    self.sampleRate = sampleRate
    self.bitDepth = bitDepth
    self.bitRate = bitRate
    self.channels = channels
    self.format = format
    self.source = source
    self.output = output
    self.mode = mode
    self.processingChain = processingChain
    self.metadataCheckAttempted = false
    self.lyricsCheckAttempted = false
    self.shouldSyncToWatch = shouldSyncToWatch
    self.storageModeRaw = storageMode.rawValue
    self.bookmarkData = bookmarkData
  }

  static func == (lhs: LibrarySong, rhs: LibrarySong) -> Bool {
    lhs.id == rhs.id
  }

  func hash(into hasher: inout Hasher) {
    hasher.combine(id)
  }

  // MARK: - Search Indexing

  func updateSearchIndex() {
    let components = [
      title,
      artist,
      album ?? "",
      albumArtist ?? "",
      genre ?? "",
      cleanLyrics(),
    ]

    self.searchIndex =
      components
      .filter { !$0.isEmpty }
      .joined(separator: " ")
      .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
      .replacingOccurrences(of: "[^a-z0-9 ]", with: " ", options: .regularExpression)
      .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .lowercased()
  }

  private func cleanLyrics() -> String {
    guard let lyrics = lyrics, !lyrics.isEmpty else { return "" }

    // Remove LRC timestamps like [00:12.34]
    let timestampPattern = #"\\[\\d{2}:\\d{2}\\.\\d{2,3}\\]"#
    let cleaned = lyrics.replacingOccurrences(
      of: timestampPattern,
      with: "",
      options: .regularExpression
    )

    // Limit indexing to first 1000 characters to keep searchIndex size manageable
    return String(cleaned.prefix(1000))
  }
}
