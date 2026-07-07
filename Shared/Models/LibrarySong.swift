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
  /// Relative path to the actual audio file inside the app group/container.
  /// Kept separate from metadata so artist/album edits do not break playback.
  var filePath: String?
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
  var lyricist: String?
  var isrc: String?
  var appleMusicURL: String?
  var artworkPath: String?
  var embeddedArtworkPath: String?
  var isRemoteArtwork: Bool = false
  var artworkSourceRaw: String = "embedded"
  var artworkBackgroundColor: String?
  var artworkPrimaryTextColor: String?
  var artworkSecondaryTextColor: String?
  var artworkTertiaryTextColor: String?
  @Attribute(.externalStorage) var userEditedFields: [String] = []
  
  // MARK: - Metadata confidence & sources
  var titleConfidence: Double = 0.0
  var artistConfidence: Double = 0.0
  var albumConfidence: Double = 0.0
  var metadataSourceTitle: String?
  var metadataSourceArtist: String?
  var metadataSourceAlbum: String?
  var isLive: Bool = false
  var isMedley: Bool = false

  @Relationship(inverse: \Album.songs)
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
  /// True when at least one successful metadata response was applied to this song.
  /// Used on startup to re-queue songs that were attempted but never completed
  /// (e.g. app was killed mid-fetch or the network call failed).
  var metadataFetchSucceeded: Bool = false
  var lyricsCheckAttempted: Bool = false

  // MARK: - Watch Sync status
  var shouldSyncToWatch: Bool = false

  init(
    title: String,
    artist: String,
    fileName: String,
    filePath: String? = nil,
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
    lyricist: String? = nil,
    isrc: String? = nil,
    appleMusicURL: String? = nil,
    artworkPath: String? = nil,
    embeddedArtworkPath: String? = nil,
    artworkBackgroundColor: String? = nil,
    artworkPrimaryTextColor: String? = nil,
    artworkSecondaryTextColor: String? = nil,
    artworkTertiaryTextColor: String? = nil,
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
    bookmarkData: Data? = nil,
    titleConfidence: Double = 0.0,
    artistConfidence: Double = 0.0,
    albumConfidence: Double = 0.0,
    metadataSourceTitle: String? = nil,
    metadataSourceArtist: String? = nil,
    metadataSourceAlbum: String? = nil,
    isLive: Bool = false,
    isMedley: Bool = false
  ) {
    self.id = UUID()
    self.title = title
    self.artist = artist
    self.artists = ArtistParser.parseArtists(from: artist)
    self.fileName = fileName
    self.filePath = filePath
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
    self.lyricist = lyricist
    self.isrc = isrc
    self.appleMusicURL = appleMusicURL
    self.artworkPath = artworkPath
    self.embeddedArtworkPath = embeddedArtworkPath
    self.artworkBackgroundColor = artworkBackgroundColor
    self.artworkPrimaryTextColor = artworkPrimaryTextColor
    self.artworkSecondaryTextColor = artworkSecondaryTextColor
    self.artworkTertiaryTextColor = artworkTertiaryTextColor
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
    self.titleConfidence = titleConfidence
    self.artistConfidence = artistConfidence
    self.albumConfidence = albumConfidence
    self.metadataSourceTitle = metadataSourceTitle
    self.metadataSourceArtist = metadataSourceArtist
    self.metadataSourceAlbum = metadataSourceAlbum
    self.isLive = isLive
    self.isMedley = isMedley
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
      .replacingOccurrences(of: "[''\"\"“”]", with: "", options: .regularExpression)
      .replacingOccurrences(of: "[^a-z0-9 ]", with: " ", options: .regularExpression)
      .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .lowercased()
  }

  private func cleanLyrics() -> String {
    guard let lyrics = lyrics, !lyrics.isEmpty else { return "" }

    // Remove LRC timestamps like [00:12.34] or [00:12:34]
    let timestampPattern = #"\[\d{2}:\d{2}[\.:]\d{2,3}\]"#
    let cleaned = lyrics.replacingOccurrences(
      of: timestampPattern,
      with: "",
      options: .regularExpression
    )

    // Limit indexing to first 5000 characters to allow better lyric searching for long songs
    return String(cleaned.prefix(5000))
  }
}
