//
//  LibraryBackupService.swift
//  Ampwave
//
//  Creates versioned JSON exports of the user's library state.
//

import Foundation
import SwiftData
internal import SwiftUI

enum LibraryBackupService {
  static func exportBackup(from modelContext: ModelContext) throws -> URL {
    let document = try makeBackupDocument(from: modelContext)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    encoder.dateEncodingStrategy = .iso8601

    let filename = "Ampwave Backup \(Date().formatted(date: .abbreviated, time: .omitted)).json"
      .replacingOccurrences(of: "/", with: "-")
      .replacingOccurrences(of: ":", with: "-")
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(filename)
    try encoder.encode(document).write(to: url, options: .atomic)
    return url
  }

  static func importBackup(
    data: Data,
    into modelContext: ModelContext
  ) throws -> BackupRestoreSummary {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let document = try decoder.decode(BackupDocument.self, from: data)

    let existingSongs = try modelContext.fetch(FetchDescriptor<LibrarySong>())
    let existingPlaylists = try modelContext.fetch(FetchDescriptor<Playlist>())
    let existingStats = try modelContext.fetch(FetchDescriptor<SongPlayStatistics>())

    var matchedSongsByBackupID: [UUID: LibrarySong] = [:]
    var matchedCount = 0
    var unmatchedCount = 0

    for backupSong in document.songs {
      let match =
        existingSongs.first(where: { $0.id == backupSong.id })
        ?? existingSongs.first(where: { $0.fileHash == backupSong.fileHash })

      guard let match else {
        unmatchedCount += 1
        continue
      }

      matchedCount += 1
      matchedSongsByBackupID[backupSong.id] = match

      match.title = backupSong.title
      match.artist = backupSong.artist
      match.album = backupSong.album
      match.albumArtist = backupSong.albumArtist
      match.genre = backupSong.genre
      match.duration = backupSong.duration
      match.year = backupSong.year
      match.composer = backupSong.composer
      match.lyricist = backupSong.lyricist
      match.trackNumber = backupSong.trackNumber
      match.discNumber = backupSong.discNumber
      match.isrc = backupSong.isrc
      match.appleMusicURL = backupSong.appleMusicURL
      match.lyricsTimingOffset = backupSong.lyricsTimingOffset ?? 0
      match.shouldSyncToWatch = backupSong.shouldSyncToWatch
      match.userEditedFields = backupSong.userEditedFields
      match.sampleRate = backupSong.sampleRate
      match.bitDepth = backupSong.bitDepth
      match.bitRate = backupSong.bitRate
      match.channels = backupSong.channels
      match.format = backupSong.format
      match.titleConfidence = backupSong.titleConfidence
      match.artistConfidence = backupSong.artistConfidence
      match.albumConfidence = backupSong.albumConfidence
      match.metadataSourceTitle = backupSong.metadataSourceTitle
      match.metadataSourceArtist = backupSong.metadataSourceArtist
      match.metadataSourceAlbum = backupSong.metadataSourceAlbum
      if let lyrics = backupSong.lyrics {
        LyricsService.shared.saveLyrics(for: match, content: lyrics)
      }
    }

    var restoredStats = 0
    for backupStats in document.statistics {
      guard let song = matchedSongsByBackupID[backupStats.songId] else { continue }
      let stats =
        existingStats.first(where: { $0.songId == song.id })
        ?? {
          let created = SongPlayStatistics(songId: song.id)
          modelContext.insert(created)
          return created
        }()

      stats.playCount = backupStats.playCount
      stats.totalPlayTime = backupStats.totalPlayTime
      stats.lastPlayedAt = backupStats.lastPlayedAt
      stats.firstPlayedAt = backupStats.firstPlayedAt
      stats.skipCount = backupStats.skipCount
      stats.userRating = backupStats.userRating
      stats.isLiked = backupStats.isLiked
      stats.isDisliked = backupStats.isDisliked
      restoredStats += 1
    }

    var restoredPlaylists = 0
    for backupPlaylist in document.playlists {
      let resolvedType = PlaylistType(rawValue: backupPlaylist.playlistType) ?? .custom
      let playlist =
        existingPlaylists.first(where: { $0.id == backupPlaylist.id })
        ?? existingPlaylists.first(where: {
          $0.name == backupPlaylist.name && $0.playlistType == resolvedType
        })
        ?? {
          let created = Playlist(
            name: backupPlaylist.name,
            description: backupPlaylist.description,
            playlistType: resolvedType
          )
          modelContext.insert(created)
          return created
        }()

      playlist.name = backupPlaylist.name
      playlist.playlistDescription = backupPlaylist.description
      playlist.playlistType = resolvedType
      playlist.createdDate = backupPlaylist.createdDate
      playlist.lastModifiedDate = backupPlaylist.lastModifiedDate
      playlist.artworkPath = backupPlaylist.artworkPath
      playlist.artworkType = PlaylistArtworkType(rawValue: backupPlaylist.artworkType) ?? .grid
      if let iconName = backupPlaylist.iconName, let iconColorHex = backupPlaylist.iconColorHex {
        playlist.icon = PlaylistIcon(icon: iconName, color: Color(hex: iconColorHex))
      } else {
        playlist.icon = nil
      }
      playlist.isPinned = backupPlaylist.isPinned
      playlist.sortOrder = PlaylistSortOrder(rawValue: backupPlaylist.sortOrder) ?? .manual
      playlist.shouldSyncToWatch = backupPlaylist.shouldSyncToWatch
      playlist.smartRules = backupPlaylist.smartRules
      playlist.songs = backupPlaylist.songOrder.compactMap { matchedSongsByBackupID[$0] }
      playlist.songOrder = playlist.songs.map(\.id)
      restoredPlaylists += 1
    }

    if let appSettings = document.appSettings {
      let settings = AppSettings.getOrCreate(in: modelContext)
      settings.groupSongsByAlbum = appSettings.groupSongsByAlbum
      settings.mergeAlbumDuplicates = appSettings.mergeAlbumDuplicates
      settings.mergeSongDuplicates = appSettings.mergeSongDuplicates
      settings.songSortOrderRaw = appSettings.songSortOrder
      settings.albumSortOrderRaw = appSettings.albumSortOrder
      settings.artistSortOrderRaw = appSettings.artistSortOrder
      settings.playlistSortOrderRaw = appSettings.playlistSortOrder
    }

    if let preferences = document.userPreferences {
      let userPreferences = UserPreferences.getOrCreate(in: modelContext)
      userPreferences.crossfadeEnabled = preferences.crossfadeEnabled
      userPreferences.crossfadeDuration = preferences.crossfadeDuration
      userPreferences.gaplessPlayback = preferences.gaplessPlayback
      userPreferences.normalizeVolume = preferences.normalizeVolume
      userPreferences.defaultShuffleModeRaw = preferences.defaultShuffleMode
      userPreferences.defaultRepeatModeRaw = preferences.defaultRepeatMode
      userPreferences.showNowPlayingOnLaunch = preferences.showNowPlayingOnLaunch
      userPreferences.expandPlayerAutomatically = preferences.expandPlayerAutomatically
      userPreferences.showLyricsByDefault = preferences.showLyricsByDefault
      userPreferences.artworkQualityRaw = preferences.artworkQuality
      userPreferences.autoFetchMetadata = preferences.autoFetchMetadata
      userPreferences.autoFetchArtistAlbumInfo = preferences.autoFetchArtistAlbumInfo ?? false
      userPreferences.autoFetchLyrics = preferences.autoFetchLyrics
      userPreferences.wordSyncedLyricsEnabled = preferences.wordSyncedLyricsEnabled
      userPreferences.animatedArtworkEnabled = preferences.animatedArtworkEnabled ?? false
      userPreferences.copyMusicToStorage = preferences.copyMusicToStorage
      userPreferences.deleteReferencedFilesOnRemoval =
        preferences.deleteReferencedFilesOnRemoval ?? false
      userPreferences.preferOnlineArtwork = preferences.preferOnlineArtwork
      userPreferences.organizeByAlbum = preferences.organizeByAlbum
      userPreferences.isOfflineMode = preferences.isOfflineMode
      userPreferences.lastSyncDate = preferences.lastSyncDate
      userPreferences.showPlaybackNotifications = preferences.showPlaybackNotifications
      userPreferences.showLyricsNotifications = preferences.showLyricsNotifications
      userPreferences.enableRecommendations = preferences.enableRecommendations
      userPreferences.recommendationSourcesRaw = preferences.recommendationSources
      userPreferences.selectedThemeRaw = preferences.selectedTheme
      userPreferences.customAccentColorHex = preferences.customAccentColorHex
      userPreferences.customBackgroundColorHex = preferences.customBackgroundColorHex
      userPreferences.customCardBackgroundColorHex = preferences.customCardBackgroundColorHex
      userPreferences.customPrimaryTextColorHex = preferences.customPrimaryTextColorHex
      userPreferences.customSecondaryTextColorHex = preferences.customSecondaryTextColorHex
      userPreferences.fullArtworkBackground = preferences.fullArtworkBackground
      userPreferences.openPlayerGlassBackground = preferences.openPlayerGlassBackground
      userPreferences.wavyPlayerSlider = preferences.wavyPlayerSlider ?? false
      userPreferences.coloredSurfaces = preferences.coloredSurfaces
      userPreferences.showFullArtworkGradient = preferences.showFullArtworkGradient
      userPreferences.miniPlayerFloating = preferences.miniPlayerFloating
      userPreferences.fullScreenArtworkExpanded = preferences.fullScreenArtworkExpanded
      userPreferences.isPremiumUser = preferences.isPremiumUser
      userPreferences.customColorSchemeRaw = preferences.customColorScheme
    }

    if let backupPlaybackState = document.playbackState {
      let playbackState = PlaybackState.getOrCreate(in: modelContext)
      playbackState.lastSongId = matchedSongsByBackupID[backupPlaybackState.lastSongId ?? UUID()]?.id
        ?? backupPlaybackState.lastSongId
      playbackState.lastTime = backupPlaybackState.lastTime
      playbackState.lastQueueIds = backupPlaybackState.lastQueueIds.compactMap {
        matchedSongsByBackupID[$0]?.id
      }
      playbackState.lastQueueIndex = min(
        backupPlaybackState.lastQueueIndex,
        max(playbackState.lastQueueIds.count - 1, 0)
      )
      playbackState.lastSourceRaw = backupPlaybackState.lastSourceRaw
      playbackState.lastPlaylistId = backupPlaybackState.lastPlaylistId
      playbackState.isVocalSliderVisible = backupPlaybackState.isVocalSliderVisible
      playbackState.vocalLevel = backupPlaybackState.vocalLevel
    }

    try modelContext.save()
    SongLibrary.shared.notifyLibraryChange()

    return BackupRestoreSummary(
      matchedSongs: matchedCount,
      unmatchedSongs: unmatchedCount,
      restoredPlaylists: restoredPlaylists,
      restoredStatistics: restoredStats
    )
  }

  private static func makeBackupDocument(from modelContext: ModelContext) throws -> BackupDocument {
    let songs = try modelContext.fetch(FetchDescriptor<LibrarySong>())
    let playlists = try modelContext.fetch(FetchDescriptor<Playlist>())
    let stats = try modelContext.fetch(FetchDescriptor<SongPlayStatistics>())
    let history = try modelContext.fetch(
      FetchDescriptor<ListeningHistory>(
        sortBy: [SortDescriptor(\.playedAt, order: .reverse)]
      ))
    let appSettings = try modelContext.fetch(FetchDescriptor<AppSettings>()).first
    let userPreferences = try modelContext.fetch(FetchDescriptor<UserPreferences>()).first
    let playbackState = try modelContext.fetch(FetchDescriptor<PlaybackState>()).first

    return BackupDocument(
      exportedAt: Date(),
      songs: songs.map(BackupSong.init),
      playlists: playlists.map(BackupPlaylist.init),
      statistics: stats.map(BackupStatistics.init),
      history: history.prefix(500).map(BackupHistoryEntry.init),
      appSettings: appSettings.map(BackupAppSettings.init),
      userPreferences: userPreferences.map(BackupUserPreferences.init),
      playbackState: playbackState.map(BackupPlaybackState.init)
    )
  }
}

struct BackupRestoreSummary {
  let matchedSongs: Int
  let unmatchedSongs: Int
  let restoredPlaylists: Int
  let restoredStatistics: Int

  var userFacingText: String {
    "Restore complete: matched \(matchedSongs) songs, left \(unmatchedSongs) unmatched, restored \(restoredPlaylists) playlists, and restored \(restoredStatistics) statistic records."
  }
}

private struct BackupDocument: Codable {
  let format: String = "ampwave-backup"
  let version: Int = 1
  let exportedAt: Date
  let songs: [BackupSong]
  let playlists: [BackupPlaylist]
  let statistics: [BackupStatistics]
  let history: [BackupHistoryEntry]
  let appSettings: BackupAppSettings?
  let userPreferences: BackupUserPreferences?
  let playbackState: BackupPlaybackState?
}

private struct BackupSong: Codable {
  let id: UUID
  let fileName: String
  let fileHash: String
  let storageMode: String
  let title: String
  let artist: String
  let album: String?
  let albumArtist: String?
  let genre: String?
  let duration: TimeInterval
  let year: Int?
  let composer: String?
  let lyricist: String?
  let lyrics: String?
  let lyricsTimingOffset: TimeInterval?
  let trackNumber: Int?
  let discNumber: Int?
  let isrc: String?
  let appleMusicURL: String?
  let importedDate: Date
  let shouldSyncToWatch: Bool
  let userEditedFields: [String]
  let sampleRate: Double?
  let bitDepth: Int?
  let bitRate: Int?
  let channels: Int?
  let format: String?
  let titleConfidence: Double
  let artistConfidence: Double
  let albumConfidence: Double
  let metadataSourceTitle: String?
  let metadataSourceArtist: String?
  let metadataSourceAlbum: String?

  init(_ song: LibrarySong) {
    id = song.id
    fileName = song.fileName
    fileHash = song.fileHash
    storageMode = song.storageModeRaw
    title = song.title
    artist = song.artist
    album = song.album
    albumArtist = song.albumArtist
    genre = song.genre
    duration = song.duration
    year = song.year
    composer = song.composer
    lyricist = song.lyricist
    lyrics = song.lyrics
    lyricsTimingOffset = song.lyricsTimingOffset
    trackNumber = song.trackNumber
    discNumber = song.discNumber
    isrc = song.isrc
    appleMusicURL = song.appleMusicURL
    importedDate = song.importedDate
    shouldSyncToWatch = song.shouldSyncToWatch
    userEditedFields = song.userEditedFields
    sampleRate = song.sampleRate
    bitDepth = song.bitDepth
    bitRate = song.bitRate
    channels = song.channels
    format = song.format
    titleConfidence = song.titleConfidence
    artistConfidence = song.artistConfidence
    albumConfidence = song.albumConfidence
    metadataSourceTitle = song.metadataSourceTitle
    metadataSourceArtist = song.metadataSourceArtist
    metadataSourceAlbum = song.metadataSourceAlbum
  }
}

private struct BackupPlaylist: Codable {
  let id: UUID
  let name: String
  let description: String?
  let createdDate: Date
  let lastModifiedDate: Date
  let playlistType: String
  let artworkPath: String?
  let artworkType: String
  let iconName: String?
  let iconColorHex: String?
  let isPinned: Bool
  let sortOrder: String
  let shouldSyncToWatch: Bool
  let songOrder: [UUID]
  let smartRules: SmartPlaylistRules?

  init(_ playlist: Playlist) {
    id = playlist.id
    name = playlist.name
    description = playlist.playlistDescription
    createdDate = playlist.createdDate
    lastModifiedDate = playlist.lastModifiedDate
    playlistType = playlist.playlistType.rawValue
    artworkPath = playlist.artworkPath
    artworkType = playlist.artworkType.rawValue
    iconName = playlist.icon?.icon
    iconColorHex = playlist.icon?.colorHex
    isPinned = playlist.isPinned
    sortOrder = playlist.sortOrder.rawValue
    shouldSyncToWatch = playlist.shouldSyncToWatch
    songOrder = playlist.songOrder
    smartRules = playlist.smartRules
  }
}

private struct BackupStatistics: Codable {
  let songId: UUID
  let playCount: Int
  let totalPlayTime: TimeInterval
  let lastPlayedAt: Date?
  let firstPlayedAt: Date?
  let skipCount: Int
  let userRating: Int?
  let isLiked: Bool
  let isDisliked: Bool

  init(_ stats: SongPlayStatistics) {
    songId = stats.songId
    playCount = stats.playCount
    totalPlayTime = stats.totalPlayTime
    lastPlayedAt = stats.lastPlayedAt
    firstPlayedAt = stats.firstPlayedAt
    skipCount = stats.skipCount
    userRating = stats.userRating
    isLiked = stats.isLiked
    isDisliked = stats.isDisliked
  }
}

private struct BackupHistoryEntry: Codable {
  let songId: UUID
  let songTitle: String
  let songArtist: String
  let songAlbum: String?
  let playedAt: Date
  let playDuration: TimeInterval
  let songDuration: TimeInterval
  let completionPercentage: Double
  let source: String
  let playlistId: UUID?

  init(_ entry: ListeningHistory) {
    songId = entry.songId
    songTitle = entry.songTitle
    songArtist = entry.songArtist
    songAlbum = entry.songAlbum
    playedAt = entry.playedAt
    playDuration = entry.playDuration
    songDuration = entry.songDuration
    completionPercentage = entry.completionPercentage
    source = entry.source.rawValue
    playlistId = entry.playlistId
  }
}

private struct BackupAppSettings: Codable {
  let groupSongsByAlbum: Bool
  let mergeAlbumDuplicates: Bool
  let mergeSongDuplicates: Bool
  let songSortOrder: String
  let albumSortOrder: String
  let artistSortOrder: String
  let playlistSortOrder: String

  init(_ settings: AppSettings) {
    groupSongsByAlbum = settings.groupSongsByAlbum
    mergeAlbumDuplicates = settings.mergeAlbumDuplicates
    mergeSongDuplicates = settings.mergeSongDuplicates
    songSortOrder = settings.songSortOrderRaw
    albumSortOrder = settings.albumSortOrderRaw
    artistSortOrder = settings.artistSortOrderRaw
    playlistSortOrder = settings.playlistSortOrderRaw
  }
}

private struct BackupUserPreferences: Codable {
  let crossfadeEnabled: Bool
  let crossfadeDuration: Double
  let gaplessPlayback: Bool
  let normalizeVolume: Bool
  let defaultShuffleMode: String
  let defaultRepeatMode: String
  let showNowPlayingOnLaunch: Bool
  let expandPlayerAutomatically: Bool
  let showLyricsByDefault: Bool
  let artworkQuality: String
  let autoFetchMetadata: Bool
  let autoFetchArtistAlbumInfo: Bool?
  let autoFetchLyrics: Bool
  let wordSyncedLyricsEnabled: Bool
  let animatedArtworkEnabled: Bool?
  let copyMusicToStorage: Bool
  let deleteReferencedFilesOnRemoval: Bool?
  let preferOnlineArtwork: Bool
  let organizeByAlbum: Bool
  let isOfflineMode: Bool
  let lastSyncDate: Date?
  let showPlaybackNotifications: Bool
  let showLyricsNotifications: Bool
  let enableRecommendations: Bool
  let recommendationSources: [String]
  let selectedTheme: String?
  let customAccentColorHex: String?
  let customBackgroundColorHex: String?
  let customCardBackgroundColorHex: String?
  let customPrimaryTextColorHex: String?
  let customSecondaryTextColorHex: String?
  let fullArtworkBackground: Bool?
  let openPlayerGlassBackground: Bool?
  let wavyPlayerSlider: Bool?
  let coloredSurfaces: Bool?
  let showFullArtworkGradient: Bool?
  let miniPlayerFloating: Bool?
  let fullScreenArtworkExpanded: Bool?
  let isPremiumUser: Bool?
  let customColorScheme: String?

  init(_ preferences: UserPreferences) {
    crossfadeEnabled = preferences.crossfadeEnabled
    crossfadeDuration = preferences.crossfadeDuration
    gaplessPlayback = preferences.gaplessPlayback
    normalizeVolume = preferences.normalizeVolume
    defaultShuffleMode = preferences.defaultShuffleModeRaw
    defaultRepeatMode = preferences.defaultRepeatModeRaw
    showNowPlayingOnLaunch = preferences.showNowPlayingOnLaunch
    expandPlayerAutomatically = preferences.expandPlayerAutomatically
    showLyricsByDefault = preferences.showLyricsByDefault
    artworkQuality = preferences.artworkQualityRaw
    autoFetchMetadata = preferences.autoFetchMetadata
    autoFetchArtistAlbumInfo = preferences.autoFetchArtistAlbumInfo
    autoFetchLyrics = preferences.autoFetchLyrics
    wordSyncedLyricsEnabled = preferences.wordSyncedLyricsEnabled
    animatedArtworkEnabled = preferences.animatedArtworkEnabled
    copyMusicToStorage = preferences.copyMusicToStorage
    deleteReferencedFilesOnRemoval = preferences.deleteReferencedFilesOnRemoval
    preferOnlineArtwork = preferences.preferOnlineArtwork
    organizeByAlbum = preferences.organizeByAlbum
    isOfflineMode = preferences.isOfflineMode
    lastSyncDate = preferences.lastSyncDate
    showPlaybackNotifications = preferences.showPlaybackNotifications
    showLyricsNotifications = preferences.showLyricsNotifications
    enableRecommendations = preferences.enableRecommendations
    recommendationSources = preferences.recommendationSourcesRaw
    selectedTheme = preferences.selectedThemeRaw
    customAccentColorHex = preferences.customAccentColorHex
    customBackgroundColorHex = preferences.customBackgroundColorHex
    customCardBackgroundColorHex = preferences.customCardBackgroundColorHex
    customPrimaryTextColorHex = preferences.customPrimaryTextColorHex
    customSecondaryTextColorHex = preferences.customSecondaryTextColorHex
    fullArtworkBackground = preferences.fullArtworkBackground
    openPlayerGlassBackground = preferences.openPlayerGlassBackground
    wavyPlayerSlider = preferences.wavyPlayerSlider
    coloredSurfaces = preferences.coloredSurfaces
    showFullArtworkGradient = preferences.showFullArtworkGradient
    miniPlayerFloating = preferences.miniPlayerFloating
    fullScreenArtworkExpanded = preferences.fullScreenArtworkExpanded
    isPremiumUser = preferences.isPremiumUser
    customColorScheme = preferences.customColorSchemeRaw
  }
}

private struct BackupPlaybackState: Codable {
  let lastSongId: UUID?
  let lastTime: TimeInterval
  let lastQueueIds: [UUID]
  let lastQueueIndex: Int
  let lastSourceRaw: String?
  let lastPlaylistId: UUID?
  let isVocalSliderVisible: Bool
  let vocalLevel: Float

  init(_ state: PlaybackState) {
    lastSongId = state.lastSongId
    lastTime = state.lastTime
    lastQueueIds = state.lastQueueIds
    lastQueueIndex = state.lastQueueIndex
    lastSourceRaw = state.lastSourceRaw
    lastPlaylistId = state.lastPlaylistId
    isVocalSliderVisible = state.isVocalSliderVisible
    vocalLevel = state.vocalLevel
  }
}
