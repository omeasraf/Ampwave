//
//  ListeningHistoryTracker.swift
//  Ampwave
//

import Foundation
import Observation
import SwiftData

@MainActor
@Observable
final class ListeningHistoryTracker {
  static let shared = ListeningHistoryTracker()

  var modelContext: ModelContext?
  private var currentSong: LibrarySong?
  private var currentPlayStartTime: Date?
  private var currentPlayDuration: TimeInterval = 0
  private var currentSourceRaw: String?
  private var currentPlaylistId: UUID?
  /// When the current track first started, kept across pauses. Scrobbles are
  /// timestamped from when playback began, and `currentPlayStartTime` is reset
  /// every time the user pauses.
  private var currentTrackStartedAt: Date?

  private init() {
    // Deleting a song removes its statistics rows behind this cache's back.
    NotificationCenter.default.addObserver(
      forName: .songsWereDeleted,
      object: nil,
      queue: .main
    ) { _ in
      MainActor.assumeIsolated { ListeningHistoryTracker.shared.invalidateStatisticsIndex() }
    }
  }

  func setModelContext(_ context: ModelContext) {
    self.modelContext = context
    invalidateStatisticsIndex()
  }

  /// Called when a song starts playing
  func songStarted(
    _ song: LibrarySong, source: PlaySource = PlaySource.library, playlistId: UUID? = nil
  ) {
    // Already tracking this exact track: a redundant start (a KVO re-fire, or
    // a play() on the song already playing) would reset the timers and throw
    // away the listening time accumulated so far, which then reads back as a
    // far shorter play than actually happened.
    if let currentSong, currentSong.id == song.id {
      print("[DEBUG] ListeningHistoryTracker: ignoring duplicate start for \(song.title)")
      return
    }

    // If there was a previous song playing, record it
    if let previousSong = currentSong {
      let sessionDuration = currentPlayStartTime.map { Date().timeIntervalSince($0) } ?? 0
      let totalDuration = currentPlayDuration + sessionDuration

      // Record the previous song with its known source
      let usedSource = PlaySource(rawValue: currentSourceRaw ?? source.rawValue) ?? .library
      recordPlay(
        song: previousSong, duration: totalDuration, source: usedSource,
        playlistId: currentPlaylistId ?? playlistId)
      scrobblePlay(previousSong, playedDuration: totalDuration)
    }

    currentSong = song
    currentPlayStartTime = Date()
    currentTrackStartedAt = Date()
    currentPlayDuration = 0
    currentSourceRaw = source.rawValue
    currentPlaylistId = playlistId

    LastFMScrobbler.shared.nowPlaying(song)
  }

  /// Called when a song is paused
  func songPaused() {
    if let startTime = currentPlayStartTime {
      currentPlayDuration += Date().timeIntervalSince(startTime)
      currentPlayStartTime = nil
    }
    LastFMScrobbler.shared.playbackPaused()
  }

  /// Called when a song is resumed
  func songResumed() {
    currentPlayStartTime = Date()
    LastFMScrobbler.shared.playbackResumed()
  }

  /// Called when a song ends or is skipped
  func songEnded(skipped: Bool = false) {
    guard let song = currentSong else { return }

    if let startTime = currentPlayStartTime {
      currentPlayDuration += Date().timeIntervalSince(startTime)
    }

    if skipped {
      recordSkip(song: song)
    } else {
      let usedSource =
        PlaySource(rawValue: currentSourceRaw ?? PlaySource.library.rawValue) ?? .library
      recordPlay(
        song: song, duration: currentPlayDuration, source: usedSource, playlistId: currentPlaylistId
      )
    }

    // Offered even for skips: a "skip" here just means under 10 seconds of the
    // *current* pass, while the user may still have heard enough of the track
    // overall. The scrobbler applies Last.fm's own threshold.
    scrobblePlay(song, playedDuration: currentPlayDuration)

    currentSong = nil
    currentPlayStartTime = nil
    currentTrackStartedAt = nil
    currentPlayDuration = 0
    currentSourceRaw = nil
    currentPlaylistId = nil
  }

  /// Drops model references without writing a play. Used before the entire
  /// library is deleted, when retaining the current song would leave a
  /// detached SwiftData model in this long-lived singleton.
  func discardCurrentSong() {
    currentSong = nil
    currentPlayStartTime = nil
    currentTrackStartedAt = nil
    currentPlayDuration = 0
    currentSourceRaw = nil
    currentPlaylistId = nil
    LastFMScrobbler.shared.cancelCurrentTracking()
  }

  private func scrobblePlay(_ song: LibrarySong, playedDuration: TimeInterval) {
    LastFMScrobbler.shared.recordPlay(
      song,
      playedDuration: playedDuration,
      startedAt: currentTrackStartedAt ?? Date().addingTimeInterval(-playedDuration)
    )
  }

  /// Records a play in the database
  private func recordPlay(
    song: LibrarySong, duration: TimeInterval, source: PlaySource, playlistId: UUID? = nil
  ) {
    guard let modelContext = modelContext else { return }

    // Create history entry
    let history = ListeningHistory(
      song: song,
      playDuration: duration,
      source: source,
      playlistId: playlistId
    )
    modelContext.insert(history)

    // Update or create statistics
    updateStatistics(for: song, duration: duration)

    // Save
    try? modelContext.save()
  }

  /// Records a skip
  private func recordSkip(song: LibrarySong) {
    guard let modelContext = modelContext else { return }

    let stats = getOrCreateStatistics(for: song)
    stats.recordSkip()

    try? modelContext.save()
  }

  // MARK: - Statistics index

  /// songId → stats, built once and kept in step with writes.
  ///
  /// Every lookup used to fetch the whole `SongPlayStatistics` table and scan it
  /// linearly. That is called from sort comparators and once per song per rule
  /// when evaluating smart playlists, so a few hundred songs meant thousands of
  /// full-table fetches and a visibly stalled UI.
  private var statsIndex: [UUID: SongPlayStatistics] = [:]
  private var statsIndexLoaded = false

  private func loadStatsIndex() {
    guard !statsIndexLoaded, let modelContext else { return }
    let all = (try? modelContext.fetch(FetchDescriptor<SongPlayStatistics>())) ?? []
    statsIndex = Dictionary(all.map { ($0.songId, $0) }, uniquingKeysWith: { first, _ in first })
    statsIndexLoaded = true
  }

  /// Drops the index so it is rebuilt on next access. Call after bulk deletes,
  /// a context swap, or anything that inserts stats behind our back.
  func invalidateStatisticsIndex() {
    statsIndex.removeAll()
    statsIndexLoaded = false
  }

  /// All statistics keyed by song id — for callers that need many lookups at
  /// once (smart playlist evaluation, sorting) so they never re-query per song.
  func statisticsBySongId() -> [UUID: SongPlayStatistics] {
    loadStatsIndex()
    return statsIndex
  }

  /// Gets or creates statistics for a song
  private func getOrCreateStatistics(for song: LibrarySong) -> SongPlayStatistics {
    guard let modelContext = modelContext else {
      return SongPlayStatistics(songId: song.id)
    }

    loadStatsIndex()
    if let existing = statsIndex[song.id] { return existing }

    let newStats = SongPlayStatistics(songId: song.id)
    modelContext.insert(newStats)
    statsIndex[song.id] = newStats
    return newStats
  }

  /// Updates statistics for a song
  private func updateStatistics(for song: LibrarySong, duration: TimeInterval) {
    let stats = getOrCreateStatistics(for: song)
    stats.recordPlay(duration: duration)
  }

  // MARK: - Query Methods

  /// Gets play statistics for a song
  func getStatistics(for song: LibrarySong) -> SongPlayStatistics? {
    statistics(forSongId: song.id)
  }

  func statistics(forSongId id: UUID) -> SongPlayStatistics? {
    guard modelContext != nil else { return nil }
    loadStatsIndex()
    return statsIndex[id]
  }

  func setLiked(_ isLiked: Bool, for song: LibrarySong) {
    guard modelContext != nil else { return }

    let stats = getOrCreateStatistics(for: song)
    stats.isLiked = isLiked
    if isLiked {
      stats.isDisliked = false
    }

    try? modelContext?.save()
  }

  func setDisliked(_ isDisliked: Bool, for song: LibrarySong) {
    guard modelContext != nil else { return }

    let stats = getOrCreateStatistics(for: song)
    stats.isDisliked = isDisliked
    if isDisliked {
      stats.isLiked = false
    }

    try? modelContext?.save()
  }

  func isDisliked(song: LibrarySong) -> Bool {
    getStatistics(for: song)?.isDisliked ?? false
  }

  func setRating(_ rating: Int?, for song: LibrarySong) {
    guard modelContext != nil else { return }

    let stats = getOrCreateStatistics(for: song)
    if let rating {
      stats.userRating = min(max(rating, 1), 5)
    } else {
      stats.userRating = nil
    }

    try? modelContext?.save()
  }

  func rating(for song: LibrarySong) -> Int? {
    getStatistics(for: song)?.userRating
  }

  /// Gets recently played songs (unique, ordered by most recent)
  func getRecentlyPlayed(limit: Int = 20) -> [LibrarySong] {
    guard let modelContext = modelContext else { return [] }

    let descriptor = FetchDescriptor<ListeningHistory>(
      sortBy: [SortDescriptor(\.playedAt, order: .reverse)]
    )

    guard let history = try? modelContext.fetch(descriptor) else { return [] }

    // Get unique song IDs in order of most recent play
    var seenIds = Set<UUID>()
    var uniqueHistory: [ListeningHistory] = []

    for entry in history {
      if !seenIds.contains(entry.songId) {
        seenIds.insert(entry.songId)
        uniqueHistory.append(entry)
        if uniqueHistory.count >= limit {
          break
        }
      }
    }

    return SongLibrary.shared.songs(ids: uniqueHistory.map(\.songId))
  }

  /// Gets most played songs
  func getMostPlayed(limit: Int = 20) -> [(song: LibrarySong, count: Int)] {
    guard let modelContext = modelContext else { return [] }

    let descriptor = FetchDescriptor<SongPlayStatistics>(
      sortBy: [SortDescriptor(\.playCount, order: .reverse)]
    )

    guard let stats = try? modelContext.fetch(descriptor) else { return [] }

    let library = SongLibrary.shared
    return stats.prefix(limit).compactMap { stat in
      guard let song = library.song(id: stat.songId) else { return nil }
      return (song: song, count: stat.playCount)
    }
  }

  /// Gets listening history for a specific time period
  func getHistory(from startDate: Date, to endDate: Date) -> [ListeningHistory] {
    guard let modelContext = modelContext else { return [] }

    // Fetch all and filter in memory to avoid predicate macro issues
    let descriptor = FetchDescriptor<ListeningHistory>(
      sortBy: [SortDescriptor(\.playedAt, order: .reverse)]
    )

    guard let allHistory = try? modelContext.fetch(descriptor) else { return [] }
    return allHistory.filter { $0.playedAt >= startDate && $0.playedAt <= endDate }
  }

  /// Gets total listening time
  func getTotalListeningTime() -> TimeInterval {
    guard let modelContext = modelContext else { return 0 }

    let descriptor = FetchDescriptor<SongPlayStatistics>()
    guard let stats = try? modelContext.fetch(descriptor) else { return 0 }

    return stats.reduce(0) { $0 + $1.totalPlayTime }
  }

  /// Gets listening time for a specific period
  func getListeningTime(from startDate: Date, to endDate: Date) -> TimeInterval {
    let history = getHistory(from: startDate, to: endDate)
    return history.reduce(0) { $0 + $1.playDuration }
  }
}
