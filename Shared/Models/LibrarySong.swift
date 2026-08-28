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
  // Artist lists are tiny and are read throughout navigation, search, and
  // cleanup. Keeping them inline prevents an external-storage fault from
  // being resolved after SwiftData has detached a deleted model.
  var artists: [String]  // All artists (parsed from artist field)
  var duration: TimeInterval

  // MARK: - Extended metadata (optional)
  var lyrics: String?
  /// Per-song synchronization correction shared by line- and word-synced
  /// lyrics. Positive values delay the lyrics; negative values show them
  /// earlier. Stored with the song so it survives future playback sessions.
  var lyricsTimingOffset: TimeInterval = 0
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
  var isExplicit: Bool = false
  /// ReplayGain track gain in dB from the file's tags, used by volume
  /// normalization. Nil when the file carries no ReplayGain tag.
  var replayGainDB: Double?

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
  /// Bumped whenever searchable text changes, so the in-memory search index
  /// can tell which entries need rebuilding. Replaces a persisted copy of the
  /// normalized text, which cost a multi-kilobyte write per song per update
  /// and was only ever read to be re-normalized anyway.
  var searchContentVersion: Int = 0

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
    isMedley: Bool = false,
    isExplicit: Bool = false,
    replayGainDB: Double? = nil
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
    self.isExplicit = isExplicit
    self.replayGainDB = replayGainDB
  }

  static func == (lhs: LibrarySong, rhs: LibrarySong) -> Bool {
    lhs.id == rhs.id
  }

  func hash(into hasher: inout Hasher) {
    hasher.combine(id)
  }

  // MARK: - Search Indexing

  /// Marks the song's searchable text as changed.
  ///
  /// The normalized text itself is no longer persisted — `SearchManager` keeps
  /// it in memory and rebuilds only the entries whose fingerprint changed. This
  /// bumps that fingerprint, which is all a persisted column was ever really
  /// providing, without rewriting a multi-kilobyte string to SwiftData on
  /// every metadata or lyrics update.
  func updateSearchIndex() {
    searchContentVersion &+= 1
  }

  // MARK: - Album Track Ordering

  /// Orders songs the way an album track list should read: disc first, then
  /// track number within the disc, with unknown numbers sorting to the end
  /// (not collapsing to the front the way `?? 0` does) and title as the final
  /// tiebreak.
  static func albumTrackOrder(_ lhs: LibrarySong, _ rhs: LibrarySong) -> Bool {
    let lhsDisc = lhs.discNumber ?? 1
    let rhsDisc = rhs.discNumber ?? 1
    if lhsDisc != rhsDisc { return lhsDisc < rhsDisc }

    let lhsTrack = lhs.trackNumber ?? .max
    let rhsTrack = rhs.trackNumber ?? .max
    if lhsTrack != rhsTrack { return lhsTrack < rhsTrack }

    return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
  }
}
