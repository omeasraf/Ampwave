//
//  PlaybackController.swift
//  Ampwave
//
//  Enhanced playback controller with AVQueuePlayer for gapless playback,
//  volume normalization, and persistence.
//

import AVFoundation
import AudioToolbox
import Combine
import Foundation
import MediaPlayer
import MediaToolbox
import MusicKit
import SwiftData
internal import SwiftUI

/// Finds long, effectively-silent tails without modifying the source file.
/// Native AVQueuePlayer handoff removes player-created gaps; this additionally
/// prevents several seconds of encoded digital silence from sounding like a
/// playback gap. The threshold is intentionally conservative so quiet fades
/// and room tone remain part of the recording.
private enum GaplessSilenceAnalyzer {
  nonisolated private static let analysisWindow: TimeInterval = 15
  nonisolated private static let minimumSilentTail: TimeInterval = 1.5
  nonisolated private static let retainedTail: TimeInterval = 0.15
  nonisolated private static let windowDuration: TimeInterval = 0.025
  // Roughly -50 dBFS. The former -32 dBFS threshold could classify audible
  // fade-outs as silence; this value targets genuinely inaudible tails.
  nonisolated private static let audibleRMS: Float = 0.0032

  nonisolated static func trailingPlaybackEnd(for url: URL) async -> TimeInterval? {
    await Task.detached(priority: .utility) {
      do {
        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat
        let sampleRate = format.sampleRate
        guard sampleRate > 0, file.length > 0 else { return nil }

        let framesToRead = min(
          file.length,
          AVAudioFramePosition((analysisWindow * sampleRate).rounded(.up))
        )
        let startFrame = max(0, file.length - framesToRead)
        file.framePosition = startFrame

        guard let buffer = AVAudioPCMBuffer(
          pcmFormat: format,
          frameCapacity: AVAudioFrameCount(framesToRead)
        ) else { return nil }
        try file.read(into: buffer, frameCount: AVAudioFrameCount(framesToRead))
        guard buffer.frameLength > 0, let channels = buffer.floatChannelData else { return nil }

        let frameCount = Int(buffer.frameLength)
        let channelCount = Int(format.channelCount)
        let windowFrames = max(1, Int((windowDuration * sampleRate).rounded()))
        var lastAudibleFrame: Int?
        var windowEnd = frameCount

        while windowEnd > 0 {
          let windowStart = max(0, windowEnd - windowFrames)
          var sumSquares: Float = 0
          var sampleCount = 0
          for channel in 0..<channelCount {
            let samples = channels[channel]
            for frame in windowStart..<windowEnd {
              let sample = samples[frame]
              sumSquares += sample * sample
              sampleCount += 1
            }
          }
          let rms = sampleCount > 0 ? sqrt(sumSquares / Float(sampleCount)) : 0
          if rms >= audibleRMS {
            lastAudibleFrame = windowEnd
            break
          }
          windowEnd = windowStart
        }

        guard let lastAudibleFrame else { return nil }
        let fullDuration = Double(file.length) / sampleRate
        let lastAudibleTime = Double(startFrame + AVAudioFramePosition(lastAudibleFrame)) / sampleRate
        let silentTail = fullDuration - lastAudibleTime
        guard silentTail >= minimumSilentTail else { return nil }
        return min(fullDuration, lastAudibleTime + retainedTail)
      } catch {
        return nil
      }
    }.value
  }
}

/// A deliberately tiny observable clock for karaoke rendering.
///
/// General playback UI only needs a few updates per second, while word-synced
/// lyrics need much finer timing. Keeping those updates on a separate object
/// prevents the rest of the app from being invalidated for every lyric tick.
@Observable
@MainActor
final class LyricsPlaybackClock {
  fileprivate(set) var currentTime: TimeInterval = 0 {
    didSet { anchorUptime = ProcessInfo.processInfo.systemUptime }
  }

  /// Host time captured alongside `currentTime`. Deliberately untracked: it is
  /// written on every sample and nothing should re-render just because of it.
  @ObservationIgnored
  private(set) var anchorUptime: TimeInterval = ProcessInfo.processInfo.systemUptime

  /// `currentTime` extrapolated to *now*.
  ///
  /// The player samples us ~30x a second, which is enough to know *which* word
  /// is being sung but not enough to draw a highlight sweeping *through* one —
  /// at 30 Hz the fill visibly steps. Karaoke rendering runs off a display-linked
  /// timeline instead and asks for the time at each frame, so the sweep is
  /// continuous no matter how coarsely the player reports progress.
  func interpolatedTime(isPlaying: Bool) -> TimeInterval {
    guard isPlaying else { return currentTime }
    let elapsed = ProcessInfo.processInfo.systemUptime - anchorUptime
    // Clamp: if sampling stalls, the highlight should pause rather than run
    // away from the audio.
    return currentTime + min(max(elapsed, 0), 0.5)
  }
}

@Observable
@MainActor
final class PlaybackController {
  static let shared = PlaybackController()

  private var player: AVQueuePlayer?
  private var timeObserver: (observer: Any, player: AVPlayer)?
  private var lyricTimeObserver: (observer: Any, player: AVPlayer)?
  private var playerObservers: [NSKeyValueObservation] = []
  private var itemObservers: [ObjectIdentifier: [NSKeyValueObservation]] = [:]
  private var itemSongIDs: [ObjectIdentifier: UUID] = [:]
  private var authoritativeItemDurations: [ObjectIdentifier: TimeInterval] = [:]
  private var gaplessPlaybackEndTimes: [ObjectIdentifier: TimeInterval] = [:]
  private var itemSecurityScopedURLs: [ObjectIdentifier: URL] = [:]
  private var gaplessPreloadToken: UUID?
  private var gaplessPreloadSongID: UUID?
  private let library = SongLibrary.shared
  private let historyTracker = ListeningHistoryTracker.shared
  private var audioSessionConfigured = false
  #if os(iOS)
    private var shouldResumeAfterSystemInterruption = false
  #endif

  private var modelContext: ModelContext?
  private var preferences: UserPreferences?
  private var persistentState: PlaybackState?
  private var isInitializing = false

  // MARK: - Playback State

  private(set) var currentItem: LibrarySong? {
    didSet {
      currentInstrumentActivity = currentItem.flatMap {
        SonicRecommendationService.shared.instrumentActivity(for: $0)
      }
      if let currentItem, currentInstrumentActivity == nil,
        MusicUnderstandingAnalyzer.isAvailable
      {
        SonicRecommendationService.shared.prioritizeAnalysis(for: currentItem)
      }
    }
  }
  private var currentInstrumentActivity: SonicInstrumentActivity?
  var currentTime: TimeInterval = 0 {
    didSet {
      currentTimeAnchorUptime = ProcessInfo.processInfo.systemUptime
    }
  }
  @ObservationIgnored
  private var currentTimeAnchorUptime: TimeInterval = ProcessInfo.processInfo.systemUptime
  private(set) var duration: TimeInterval = 0
  private(set) var isPlaying: Bool = false
  private(set) var isLoading: Bool = false
  var isScrubbing: Bool = false
  private(set) var isSeeking: Bool = false

  /// Smooth UI-only playback time between AVPlayer's lower-frequency samples.
  /// The authoritative `currentTime` is still replaced by each real player
  /// sample, so interpolation can never drift over time.
  func interpolatedCurrentTime() -> TimeInterval {
    guard isPlaying, !isScrubbing, !isSeeking else { return currentTime }
    let elapsed = ProcessInfo.processInfo.systemUptime - currentTimeAnchorUptime
    let projected = currentTime + min(max(elapsed, 0), 0.75)
    return projected
  }

  var volume: Float = 1.0 {
    didSet {
      applyPlayerOutputVolume()
    }
  }

  /// Applies pre-amp (UserDefaults `com.ampwave.audioPreamp`) and Sound Check-style leveling when enabled.
  private func applyPlayerOutputVolume() {
    player?.volume = effectiveOutputVolume
  }

  private var effectiveOutputVolume: Float {
    let preamp = Float(UserDefaults.standard.double(forKey: "com.ampwave.audioPreamp"))
    let gain = (preamp > 0.25 && preamp < 4.0) ? preamp : 1.0
    return min(1, volume * gain * normalizationGain)
  }

  /// Per-track attenuation that levels loudness across the library.
  ///
  /// Replaces a flat 0.94 multiplier that was applied to every track equally —
  /// which only made everything quieter and left the *relative* loudness
  /// between tracks exactly as it was, so the setting did nothing.
  ///
  /// `player.volume` can only attenuate (it clamps at 1.0), so this normalizes
  /// downward: loud tracks are pulled toward the reference level and quiet
  /// tracks are left alone. Files with no ReplayGain tag are untouched rather
  /// than guessed at.
  private var normalizationGain: Float {
    guard preferences?.normalizeVolume ?? false else { return 1.0 }
    guard let gainDB = currentItem?.replayGainDB else { return 1.0 }
    // A positive tag gain means the track is quieter than reference and wants
    // boosting, which we can't do — leave it at unity.
    guard gainDB < 0 else { return 1.0 }
    // Floor at -12 dB so a badly tagged file can't render playback inaudible.
    let clamped = max(gainDB, -12)
    return powf(10, Float(clamped) / 20)
  }

  func refreshAudioEnhancementsFromSettings() {
    applyEQPresetForPlayback()
    applyPlayerOutputVolume()
  }

  private func applyEQPresetForPlayback() {
    // EQManager owns EQ persistence. The previous legacy preset lookup always
    // resolved to "flat" and reset VocalSlider to 100% at every play/restore,
    // making an attached processing tap silently become a no-op.
    EQManager.shared.syncToVocalIsolator()
  }

  // MARK: - Vocal Isolation

  private(set) var isVocalSliderVisible: Bool = false
  private(set) var currentVocalLevel: Float = 1.0
  private var vocalSliderTimer: Timer?

  func toggleVocalSlider() {
    withAnimation(.spring(response: 0.4, dampingFraction: 0.75)) {
      isVocalSliderVisible.toggle()
    }

    print("[DEBUG] PlaybackController: toggleVocalSlider - New state: \(isVocalSliderVisible)")

    if isVocalSliderVisible {
      resetVocalSliderTimer()
    } else {
      vocalSliderTimer?.invalidate()
      vocalSliderTimer = nil
    }

    saveState()
  }

  var vocalLevel: Float {
    get { currentVocalLevel }
    set {
      let clamped = min(max(newValue, 0), 1)
      let needsTap = currentVocalLevel >= 0.999 && clamped < 0.999
      currentVocalLevel = clamped
      VocalIsolator.shared.vocalLevel = clamped

      if needsTap {
        attachAudioProcessingToCurrentItemIfNeeded()
      }

      if isVocalSliderVisible {
        resetVocalSliderTimer()
      }
    }
  }

  /// Live Music Understanding confidence for the current playback position.
  /// Nil preserves the ordinary slider appearance on iOS 26 and for songs that
  /// have not produced instrument activity results.
  var currentVocalActivity: Float? {
    guard let currentInstrumentActivity else { return nil }
    return currentInstrumentActivity.vocalActivity(at: interpolatedCurrentTime())
  }

  private func attachAudioProcessingToCurrentItemIfNeeded() {
    guard let item = player?.currentItem, item.audioMix == nil else { return }
    Task { @MainActor [weak self, weak item] in
      guard let self, let item else { return }
      do {
        guard let track = try await item.asset.loadTracks(withMediaType: .audio).first,
          self.player?.currentItem === item,
          let song = self.currentItem
        else { return }
        let instrumentActivity = SonicRecommendationService.shared.instrumentActivity(for: song)
        self.currentInstrumentActivity = instrumentActivity
        item.audioMix = VocalIsolator.shared.createAudioMix(
          for: track,
          instrumentActivity: instrumentActivity
        )
        DiagnosticLog.shared.log(
          "audio-processing",
          "Attached VocalSlider tap title=\(song.title) level=\(self.currentVocalLevel) "
            + "mode=\(instrumentActivity == nil ? "fallback" : "music-understanding") "
            + "vocalPoints=\(instrumentActivity?.vocal.count ?? 0)"
        )
      } catch {
        DiagnosticLog.shared.log("error", "Could not attach processing tap: \(error)")
      }
    }
  }

  private func resetVocalSliderTimer() {
    vocalSliderTimer?.invalidate()
    vocalSliderTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: false) {
      [weak self] _ in
      Task { @MainActor in
        withAnimation(.easeInOut(duration: 0.5)) {
          self?.isVocalSliderVisible = false
          self?.saveState()
        }
      }
    }
  }

  // MARK: - Queue Management

  private(set) var queue: [LibrarySong] = []
  private var originalQueue: [LibrarySong] = []
  private(set) var currentQueueIndex: Int = 0

  var upNext: [LibrarySong] {
    guard currentQueueIndex < queue.count - 1 else { return [] }
    return Array(queue[(currentQueueIndex + 1)...])
  }

  var previouslyPlayed: [LibrarySong] {
    guard currentQueueIndex > 0 else { return [] }
    return Array(queue[0..<currentQueueIndex])
  }

  // MARK: - Playback Modes

  var shuffleMode: ShuffleMode = .off {
    didSet {
      applyShuffleMode()
      saveState()
    }
  }

  var repeatMode: RepeatMode = .off {
    didSet {
      applyRepeatModeToPlayer()
      saveState()
    }
  }

  /// Keeps AVQueuePlayer's own end-of-item behavior in sync with Ampwave's
  /// repeat setting. With its default `.advance` behavior, AVQueuePlayer moves
  /// to a gapless-preloaded successor before `AVPlayerItemDidPlayToEndTime` is
  /// delivered, so seeking the finished item for Repeat One is already too
  /// late and the next song plays instead.
  private func applyRepeatModeToPlayer() {
    guard let player else { return }

    if repeatMode == .one {
      player.actionAtItemEnd = .none
      gaplessPreloadToken = nil
      gaplessPreloadSongID = nil
      // Repeat One always plays the complete recording before restarting.
      player.currentItem?.forwardPlaybackEndTime = .invalid
      cleanupCrossfade()
      applyPlayerOutputVolume()

      // A successor may already have been preloaded before Repeat One was
      // selected. Remove it so there is nothing for the queue to promote.
      if let currentItem = player.currentItem {
        for queuedItem in player.items() where queuedItem !== currentItem {
          releaseResources(for: queuedItem)
          player.remove(queuedItem)
        }
      }
    } else {
      player.actionAtItemEnd = .advance
      if let currentItem = player.currentItem,
        let playbackEnd = gaplessPlaybackEndTimes[ObjectIdentifier(currentItem)],
        shouldTrimGaplessEnding(at: currentQueueIndex, songID: self.currentItem?.id)
      {
        currentItem.forwardPlaybackEndTime = CMTime(
          seconds: playbackEnd,
          preferredTimescale: 600
        )
      }
      prepareNextItem()
    }
  }

  // MARK: - Lyrics

  private(set) var currentLyrics: SyncedLyric? {
    didSet {
      lyricLineTimestamps = currentLyrics?.lines.map(\.timestamp) ?? []
    }
  }
  private(set) var currentLyricIndex: Int?
  let lyricsClock = LyricsPlaybackClock()
  private var lyricLineTimestamps: [TimeInterval] = []

  var hasLyrics: Bool {
    currentLyrics?.hasLyrics ?? false
  }

  /// One correction applies to both line and word timings. A positive value
  /// means the lyrics should appear later than the timestamps in the file.
  var lyricsTimingOffset: TimeInterval {
    currentItem?.lyricsTimingOffset ?? 0
  }

  func adjustedLyricsTime(for playbackTime: TimeInterval) -> TimeInterval {
    playbackTime - lyricsTimingOffset
  }

  func playbackTime(forLyricTimestamp timestamp: TimeInterval) -> TimeInterval {
    min(max(timestamp + lyricsTimingOffset, 0), max(duration, 0))
  }

  func seekToLyricTimestamp(_ timestamp: TimeInterval) {
    seek(to: playbackTime(forLyricTimestamp: timestamp))
  }

  /// Updates the live lyric position immediately. Slider drags can defer the
  /// database write until the gesture/sheet finishes.
  func setLyricsTimingOffset(
    _ offset: TimeInterval,
    for targetSong: LibrarySong? = nil,
    persist: Bool = true
  ) {
    guard let song = targetSong ?? currentItem else { return }
    song.lyricsTimingOffset = min(max(offset, -10), 10)
    if song.id == currentItem?.id {
      updateCurrentLyric(at: currentTime)
      updateWidget(force: true)
    }
    if persist {
      do {
        try modelContext?.save()
      } catch {
        DiagnosticLog.shared.log(
          "lyrics-timing",
          "Failed to save offset song=\(song.title) error=\(error.localizedDescription)"
        )
      }
    }
  }

  /// Unsynced text for the current song, used when there are no timings to
  /// follow. Prefers the provider's own plain copy over stripping timestamps
  /// out of the LRC, which leaves odd spacing on enhanced (word-synced) lines.
  var currentPlainLyrics: String? {
    if let plain = currentLyrics?.plainLyrics, !plain.isEmpty { return plain }
    guard let raw = currentItem?.lyrics, !raw.isEmpty else { return nil }
    // `song.lyrics` holds LRC once synced lyrics land, including inline word
    // timings — strip them rather than showing timestamps as lyrics.
    let sanitized = LRCParser.plainText(from: raw)
    return sanitized.isEmpty ? nil : sanitized
  }

  // MARK: - Source Tracking

  private(set) var currentSource: PlaySource = .library
  private var currentPlaylistId: UUID?

  private init() {
    DiagnosticLog.shared.log("playback", "PlaybackController initialized")
    setupRemoteCommands()
    setupNotifications()
  }

  private func cleanupPlayer() {
    if let (observer, obsPlayer) = timeObserver {
      obsPlayer.removeTimeObserver(observer)
      timeObserver = nil
    }
    if let (observer, obsPlayer) = lyricTimeObserver {
      obsPlayer.removeTimeObserver(observer)
      lyricTimeObserver = nil
    }
    player?.pause()
    player = nil

    // Invalidate item observers
    playerObservers.forEach { $0.invalidate() }
    playerObservers.removeAll()
    itemObservers.values.flatMap { $0 }.forEach { $0.invalidate() }
    itemObservers.removeAll()
    itemSongIDs.removeAll()
    authoritativeItemDurations.removeAll()
    gaplessPlaybackEndTimes.removeAll()
    gaplessPreloadToken = nil
    gaplessPreloadSongID = nil
    releaseAllSecurityScopes()
  }

  private func releaseResources(for item: AVPlayerItem) {
    let key = ObjectIdentifier(item)
    itemObservers.removeValue(forKey: key)?.forEach { $0.invalidate() }
    itemSongIDs.removeValue(forKey: key)
    authoritativeItemDurations.removeValue(forKey: key)
    gaplessPlaybackEndTimes.removeValue(forKey: key)
    if let url = itemSecurityScopedURLs.removeValue(forKey: key) {
      url.stopAccessingSecurityScopedResource()
    }
  }

  private func releaseResourcesForQueuedItems() {
    gaplessPreloadToken = nil
    gaplessPreloadSongID = nil
    player?.items().forEach { releaseResources(for: $0) }
  }

  private func releaseAllSecurityScopes() {
    itemSecurityScopedURLs.values.forEach { $0.stopAccessingSecurityScopedResource() }
    itemSecurityScopedURLs.removeAll()
  }

  /// Native queue handoff is used only when both items can stay on
  /// AVFoundation's unmodified playback path. Crossfade and live audio taps
  /// each own their own transition path and must not race a queued successor.
  private var usesNativeGaplessPlayback: Bool {
    (preferences?.gaplessPlayback ?? true)
      && !(preferences?.crossfadeEnabled ?? false)
      && !VocalIsolator.shared.requiresProcessing
  }

  private func shouldTrimGaplessEnding(at index: Int, songID: UUID?) -> Bool {
    guard usesNativeGaplessPlayback,
      repeatMode != .one,
      index >= 0,
      index < queue.count,
      queue[index].id == songID
    else { return false }
    return index < queue.count - 1 || repeatMode == .all
  }

  func setModelContext(_ context: ModelContext) {
    print("[DEBUG] PlaybackController.setModelContext: Setting context")
    self.isInitializing = true
    self.modelContext = context
    self.preferences = UserPreferences.getOrCreate(in: context)
    self.persistentState = PlaybackState.getOrCreate(in: context)

    print(
      "[DEBUG] PlaybackController.setModelContext: preferences: \(preferences != nil), persistentState: \(persistentState != nil)"
    )

    // Restore the user's active modes. Older PlaybackState records have empty
    // values, in which case their configured defaults remain the right choice.
    if let prefs = preferences {
      self.shuffleMode = persistentState.flatMap {
        ShuffleMode(rawValue: $0.shuffleModeRaw)
      } ?? prefs.defaultShuffleMode
      self.repeatMode = persistentState.flatMap {
        RepeatMode(rawValue: $0.repeatModeRaw)
      } ?? prefs.defaultRepeatMode
      print(
        "[DEBUG] PlaybackController.setModelContext: Applied defaults - Shuffle: \(shuffleMode), Repeat: \(repeatMode)"
      )
    }
    if let persistentState {
      self.currentVocalLevel = min(max(persistentState.vocalLevel, 0), 1)
      VocalIsolator.shared.vocalLevel = self.currentVocalLevel
    }

    self.isInitializing = false
  }

  /// Retries state restoration after library has finished loading songs
  func restoreStateAfterLoading() {
    print("[DEBUG] PlaybackController.restoreStateAfterLoading called")
    let restoredSongId = persistentState?.lastSongId
    if currentItem == nil || currentItem?.id != restoredSongId {
      restoreState()
    }
  }

  // MARK: - Mock for Previews

  func setupMockPlayback(
    song: LibrarySong,
    lyrics: SyncedLyric?,
    time: TimeInterval = 0
  ) {
    self.currentItem = song
    self.currentLyrics = lyrics
    self.currentTime = time
    self.lyricsClock.currentTime = time
    self.duration = song.duration
    self.isPlaying = false
    self.updateCurrentLyric()
  }

  private func setupAudioSession() {
    #if os(iOS)
      guard !audioSessionConfigured else { return }
      let session = AVAudioSession.sharedInstance()
      do {
        try session.setCategory(
          .playback,
          mode: .default,
          options: []
        )
        try session.setActive(true)
        audioSessionConfigured = true
      } catch {
        DiagnosticLog.shared.log("audio-session", "Activation failed: \(error)")
        print("Audio session error: \(error)")
      }
    #endif
  }

  private func setupNotifications() {
    NotificationCenter.default.addObserver(
      self,
      selector: #selector(handleLibraryDidLoad),
      name: Notification.Name("SongLibraryDidLoad"),
      object: nil
    )

    #if os(iOS)
      NotificationCenter.default.addObserver(
        self,
        selector: #selector(handleAudioSessionInterruption),
        name: AVAudioSession.interruptionNotification,
        object: nil
      )

      NotificationCenter.default.addObserver(
        self,
        selector: #selector(handleRouteChange),
        name: AVAudioSession.routeChangeNotification,
        object: nil
      )
    #endif

    // Handle item did play to end for manual queue management in AVQueuePlayer if needed
    NotificationCenter.default.addObserver(
      self,
      selector: #selector(playerItemDidReachEnd),
      name: .AVPlayerItemDidPlayToEndTime,
      object: nil
    )
    NotificationCenter.default.addObserver(
      self,
      selector: #selector(playerItemFailedToReachEnd(_:)),
      name: .AVPlayerItemFailedToPlayToEndTime,
      object: nil
    )
    NotificationCenter.default.addObserver(
      self,
      selector: #selector(playerItemPlaybackStalled(_:)),
      name: .AVPlayerItemPlaybackStalled,
      object: nil
    )

    // Must run *before* the model is deleted, so this uses the selector form
    // (synchronous on the posting thread) rather than a block on a queue.
    NotificationCenter.default.addObserver(
      self,
      selector: #selector(handleSongsDeleted(_:)),
      name: .songsWereDeleted,
      object: nil
    )

    // Lyrics can be fetched or edited from outside playback (the song editor,
    // a background pass). Without this the player keeps whatever it loaded at
    // track start and the views fall back to showing raw text.
    NotificationCenter.default.addObserver(
      self,
      selector: #selector(handleLyricsDidUpdate(_:)),
      name: .lyricsDidUpdate,
      object: nil
    )
    NotificationCenter.default.addObserver(
      self,
      selector: #selector(handleSonicAnalysisDidUpdate(_:)),
      name: .sonicAnalysisDidUpdate,
      object: nil
    )
  }

  @objc private func handleSonicAnalysisDidUpdate(_ notification: Notification) {
    guard let songID = notification.object as? UUID,
      let song = currentItem,
      song.id == songID,
      let activity = SonicRecommendationService.shared.instrumentActivity(for: song)
    else { return }

    currentInstrumentActivity = activity
    DiagnosticLog.shared.log(
      "audio-processing",
      "Current song Music Understanding became ready title=\(song.title) vocalPoints=\(activity.vocal.count)"
    )

    // If the fallback tap was installed while analysis was still running,
    // replace it in place so the current song benefits without a restart.
    guard let item = player?.currentItem, item.audioMix != nil,
      VocalIsolator.shared.requiresProcessing
    else { return }
    Task { @MainActor [weak self, weak item] in
      guard let self, let item, self.player?.currentItem === item,
        let track = try? await item.asset.loadTracks(withMediaType: .audio).first
      else { return }
      item.audioMix = VocalIsolator.shared.createAudioMix(
        for: track,
        instrumentActivity: activity
      )
      DiagnosticLog.shared.log(
        "audio-processing",
        "Upgraded active VocalSlider tap to Music Understanding title=\(song.title)"
      )
    }
  }

  @objc private func handleSongsDeleted(_ notification: Notification) {
    guard let ids = notification.object as? Set<UUID> else { return }
    MainActor.assumeIsolated { evictDeletedSongs(ids) }
  }

  /// Drops deleted songs from playback before SwiftData invalidates them.
  ///
  /// Holding a deleted `LibrarySong` in `currentItem` or the queue crashes the
  /// moment anything reads a property off it — which is instant, because the
  /// now-playing UI observes it. When the deleted song is the one playing, we
  /// skip to the next survivor rather than just stopping.
  private func evictDeletedSongs(_ ids: Set<UUID>) {
    guard !ids.isEmpty else { return }

    let currentWasDeleted = currentItem.map { ids.contains($0.id) } ?? false

    // Pick the successor while the queue still has its original ordering.
    var successor: LibrarySong?
    if currentWasDeleted, currentQueueIndex < queue.count {
      successor = queue[(currentQueueIndex + 1)...].first { !ids.contains($0.id) }
      if successor == nil {
        successor = queue[..<currentQueueIndex].last { !ids.contains($0.id) }
      }
    }

    queue.removeAll { ids.contains($0.id) }
    originalQueue.removeAll { ids.contains($0.id) }

    guard currentWasDeleted else {
      // Keep the index pointing at the same song after the queue shrank.
      if let currentItem, let index = queue.firstIndex(where: { $0.id == currentItem.id }) {
        currentQueueIndex = index
      }
      return
    }

    // Release every reference to the dying model first. `songEnded` would try
    // to write a play for it, so the history tracker gets the discard path.
    historyTracker.discardCurrentSong()
    currentItem = nil
    currentLyrics = nil
    currentLyricIndex = nil

    if let successor, let index = queue.firstIndex(where: { $0.id == successor.id }) {
      currentQueueIndex = index
      play(successor, from: currentSource, playlistId: currentPlaylistId)
    } else {
      // Nothing left to play.
      cleanupPlayer()
      isPlaying = false
      currentTime = 0
      duration = 0
      currentQueueIndex = 0
      lyricsClock.currentTime = 0
      updateNowPlaying()
      saveState()
    }
  }

  @objc private func handleLyricsDidUpdate(_ notification: Notification) {
    Task { @MainActor in
      guard let songId = notification.object as? UUID,
        let current = currentItem,
        current.id == songId
      else { return }

      currentLyrics = LyricsService.shared.getCachedLyrics(for: current)
      updateCurrentLyric()
      updateWidget(force: true)
    }
  }

  @objc private func handleLibraryDidLoad() {
    Task { @MainActor in
      print("[DEBUG] PlaybackController: SongLibraryDidLoad notification received")
      restoreStateAfterLoading()
    }
  }

  #if os(iOS)
    @objc private func handleAudioSessionInterruption(
      _ notification: Notification
    ) {
      guard let userInfo = notification.userInfo,
        let typeValue = userInfo[AVAudioSessionInterruptionTypeKey]
          as? UInt,
        let type = AVAudioSession.InterruptionType(rawValue: typeValue)
      else { return }

      switch type {
      case .began:
        let wasPlaying = isPlaying || (player?.rate ?? 0) > 0
        let alreadyWaitingToResume = shouldResumeAfterSystemInterruption
        DiagnosticLog.shared.log(
          "audio-session",
          "Interruption began wasPlaying=\(wasPlaying)"
        )
        if wasPlaying { pause() }
        shouldResumeAfterSystemInterruption = alreadyWaitingToResume || wasPlaying
      case .ended:
        DiagnosticLog.shared.log("audio-session", "Interruption ended userInfo=\(userInfo)")
        if shouldResumeAfterSystemInterruption {
          shouldResumeAfterSystemInterruption = false
          audioSessionConfigured = false
          play()
        }
      @unknown default:
        break
      }
    }

    /// Reconciles Ampwave's UI intent with the real player after Control
    /// Center, Notification Center, or another app temporarily owns audio.
    func applicationDidBecomeActive() {
      guard currentItem != nil, let player else { return }
      let playerIsActuallyPlaying =
        player.timeControlStatus == .playing && player.rate > 0
      let shouldRecover =
        shouldResumeAfterSystemInterruption || (isPlaying && !playerIsActuallyPlaying)

      if shouldRecover {
        DiagnosticLog.shared.log(
          "audio-session",
          "Recovering on activation intent=\(isPlaying) interrupted=\(shouldResumeAfterSystemInterruption) status=\(player.timeControlStatus.rawValue) rate=\(player.rate)"
        )
        shouldResumeAfterSystemInterruption = false
        audioSessionConfigured = false
        play()
      } else if !isPlaying, playerIsActuallyPlaying {
        // A user pause always wins over stale AVPlayer state.
        player.pause()
      }
    }

    @objc private func handleRouteChange(_ notification: Notification) {
      guard let userInfo = notification.userInfo,
        let reasonValue = userInfo[AVAudioSessionRouteChangeReasonKey]
          as? UInt,
        let reason = AVAudioSession.RouteChangeReason(rawValue: reasonValue)
      else { return }

      if reason == .oldDeviceUnavailable {
        DiagnosticLog.shared.log("audio-session", "Old audio route unavailable; pausing")
        pause()
      } else {
        DiagnosticLog.shared.log("audio-session", "Route changed reason=\(reason.rawValue)")
      }
    }
  #endif

  @objc private func playerItemDidReachEnd(notification: Notification) {
    guard let item = notification.object as? AVPlayerItem,
      let player = player
    else { return }

    let itemKey = ObjectIdentifier(item)
    guard itemSongIDs[itemKey] != nil else {
      // AVPlayerItemDidPlayToEndTime is process-wide. Animated artwork and any
      // other auxiliary AVPlayer post the same notification, so only items
      // created and registered by the audio player may alter the song queue.
      DiagnosticLog.shared.log(
        "transition",
        "Ignored end notification from non-audio player url=\((item.asset as? AVURLAsset)?.url.lastPathComponent ?? "unknown")"
      )
      return
    }
    let finishedSongID = itemSongIDs[itemKey]
    let finishedIndex = finishedSongID.flatMap { id in queue.firstIndex { $0.id == id } }
    DiagnosticLog.shared.log(
      "transition",
      "Item ended song=\(finishedSongID?.uuidString ?? "unknown") index=\(finishedIndex.map(String.init) ?? "unknown") currentIndex=\(currentQueueIndex) queuedItems=\(player.items().count)"
    )
    // If a crossfade is in progress and finished, it already advanced the queue
    if crossfadeStarted {
      completeCrossfade()
      return
    }

    if let finishedSongID,
      let finishedSong = queue.first(where: { $0.id == finishedSongID })
    {
      historyTracker.songFinished(finishedSong)
    }

    // Ensure we are talking about the currently playing item that actually finished
    // AVQueuePlayer may have already moved currentItem forward, but 'item' is what just finished

    let resolvedFinishedIndex = finishedIndex ?? currentQueueIndex
    let isEndOfQueue = resolvedFinishedIndex >= max(queue.count - 1, 0)
    if SleepTimerService.shared.handleTrackFinished(isEndOfQueue: isEndOfQueue) {
      stopForSleepTimer(resetPosition: false)
      return
    }

    // If repeat one, we should restart the item
    if repeatMode == .one {
      item.seek(to: .zero, completionHandler: nil)
      player.play()
      if let finishedSongID,
        let repeatedSong = queue.first(where: { $0.id == finishedSongID })
      {
        historyTracker.songStarted(
          repeatedSong,
          source: currentSource,
          playlistId: currentPlaylistId
        )
      }
    } else if queue.count > resolvedFinishedIndex + 1 {
      // Automatic advance is handled by KVO (observePlayerItemChange)
      if !usesNativeGaplessPlayback {
        releaseResources(for: item)
        playNext()
      } else {
        releaseResources(for: item)
        // AVQueuePlayer occasionally consumes the finished item without
        // promoting its preloaded successor (notably around Bluetooth route
        // changes or a stale preload). Reconcile after KVO has had a chance to
        // report a normal handoff; otherwise playback would stop indefinitely.
        recoverGaplessHandoffIfNeeded(after: item, finishedIndex: resolvedFinishedIndex)
      }
    } else if repeatMode == .all && !queue.isEmpty {
      releaseResources(for: item)
      // Repeat the whole queue by starting from 0
      currentQueueIndex = 0
      play(queue[0], from: currentSource, playlistId: currentPlaylistId)
    } else {
      releaseResources(for: item)
      isPlaying = false
      saveState()
    }
  }

  private func recoverGaplessHandoffIfNeeded(
    after finishedItem: AVPlayerItem,
    finishedIndex: Int
  ) {
    let expectedIndex = finishedIndex + 1
    guard expectedIndex < queue.count else { return }
    let expectedSongID = queue[expectedIndex].id

    Task { @MainActor [weak self] in
      try? await Task.sleep(for: .milliseconds(300))
      guard let self else { return }
      guard finishedIndex >= 0, finishedIndex < self.queue.count,
        expectedIndex < self.queue.count,
        self.queue[expectedIndex].id == expectedSongID
      else { return }

      // A normal AVQueuePlayer handoff may already have been reflected by KVO.
      if self.currentQueueIndex == expectedIndex,
        self.currentItem?.id == expectedSongID,
        self.player?.currentItem !== finishedItem
      {
        self.player?.play()
        self.isPlaying = true
        DiagnosticLog.shared.log("transition", "Native gapless handoff completed index=\(expectedIndex)")
        return
      }

      guard self.currentQueueIndex == finishedIndex,
        self.currentItem?.id == self.queue[finishedIndex].id
      else { return }

      let expectedSong = self.queue[expectedIndex]
      if let playingItem = self.player?.currentItem,
        playingItem !== finishedItem,
        let asset = playingItem.asset as? AVURLAsset,
        asset.url == self.library.getFileURL(for: expectedSong)
      {
        self.updateStateForAutoAdvancedSong(expectedSong, at: expectedIndex)
        self.player?.play()
        self.isPlaying = true
      } else {
        DiagnosticLog.shared.log("transition", "Gapless handoff recovery started index=\(expectedIndex)")
        print("[ERROR] PlaybackController: Recovering failed gapless handoff")
        self.currentQueueIndex = expectedIndex
        self.play(expectedSong, from: self.currentSource, playlistId: self.currentPlaylistId)
      }
    }
  }

  @objc nonisolated private func playerItemFailedToReachEnd(_ notification: Notification) {
    guard let failedItem = notification.object as? AVPlayerItem else { return }
    Task { @MainActor [weak self, weak failedItem] in
      guard let self, let failedItem,
        self.player?.currentItem === failedItem || self.player?.currentItem == nil
      else { return }
      print("[ERROR] PlaybackController: Current item failed to reach end; skipping")
      DiagnosticLog.shared.log(
        "error",
        "Item failed to reach end error=\(failedItem.error?.localizedDescription ?? "unknown") errorLog=\(failedItem.errorLog()?.events.count ?? 0)"
      )
      self.releaseResources(for: failedItem)
      self.playNext()
    }
  }

  @objc nonisolated private func playerItemPlaybackStalled(_ notification: Notification) {
    guard let stalledItem = notification.object as? AVPlayerItem else { return }
    Task { @MainActor [weak self, weak stalledItem] in
      guard let self, let stalledItem, self.player?.currentItem === stalledItem,
        self.isPlaying
      else { return }
      DiagnosticLog.shared.log(
        "stall",
        "Playback stalled at \(self.player?.currentTime().seconds ?? -1) status=\(stalledItem.status.rawValue) accessEvents=\(stalledItem.accessLog()?.events.count ?? 0)"
      )
      // Local/referenced files should recover as soon as their security scope
      // or Bluetooth route is available again.
      self.audioSessionConfigured = false
      self.setupAudioSession()
      self.player?.play()
    }
  }

  private func observePlayerItemChange() {
    guard let player = player else { return }
    let obs = player.observe(\.currentItem, options: [.new]) {
      [weak self] player, _ in
      Task { @MainActor in
        guard let self = self, let newItem = player.currentItem else {
          return
        }

        self.reconcileCurrentPlayerItem(newItem, source: "KVO")
      }
    }
    playerObservers.append(obs)

    let timeControlObserver = player.observe(\.timeControlStatus, options: [.new]) {
      [weak self] player, _ in
      Task { @MainActor in
        guard let self, self.player === player else { return }
        let reason = player.reasonForWaitingToPlay?.rawValue ?? "none"
        DiagnosticLog.shared.log(
          "player",
          "timeControlStatus=\(player.timeControlStatus.rawValue) rate=\(player.rate) reason=\(reason) current=\(self.currentItem?.title ?? "none")"
        )

        guard player.timeControlStatus == .waitingToPlayAtSpecifiedRate,
          self.isPlaying
        else { return }

        Task { @MainActor [weak self, weak player] in
          try? await Task.sleep(for: .seconds(2))
          guard let self, let player, self.player === player,
            self.isPlaying,
            player.timeControlStatus == .waitingToPlayAtSpecifiedRate
          else { return }

          DiagnosticLog.shared.log("stall", "Recovering player still waiting after 2 seconds")
          self.audioSessionConfigured = false
          self.setupAudioSession()
          if player.currentItem == nil {
            self.playNext()
          } else {
            player.play()
          }
        }
      }
    }
    playerObservers.append(timeControlObserver)
  }

  private func updateStateForAutoAdvancedSong(_ song: LibrarySong, at index: Int) {
    DiagnosticLog.shared.log("transition", "Player advanced to index=\(index) title=\(song.title)")
    print("[DEBUG] PlaybackController: Auto-advanced to \(song.title) at index \(index)")
    self.currentQueueIndex = index
    self.currentItem = song
    // Gapless hand-off doesn't go through play(), so the per-track
    // normalization gain has to be re-applied here too.
    self.applyPlayerOutputVolume()
    self.updateUIForNewItem()
    if let activeItem = player?.currentItem,
      let fixedDuration = authoritativeItemDurations[ObjectIdentifier(activeItem)]
    {
      applyResolvedDuration(fixedDuration, source: "handoff asset timeline")
    }
    self.historyTracker.songStarted(
      song, source: self.currentSource, playlistId: self.currentPlaylistId)
    self.saveState()
  }

  /// Reconciles Ampwave's model with the item AVQueuePlayer is actually
  /// decoding. KVO is normally immediate, but a seek near the end can race the
  /// queue's automatic promotion. The periodic observer also calls this so a
  /// missed/delayed callback cannot leave the old title and duration onscreen
  /// while the next track's clock and audio are already running.
  private func reconcileCurrentPlayerItem(_ playerItem: AVPlayerItem, source: String) {
    let key = ObjectIdentifier(playerItem)
    var resolvedIndex: Int?

    if let songID = itemSongIDs[key] {
      resolvedIndex = queue.firstIndex { $0.id == songID }
    }

    if resolvedIndex == nil, let asset = playerItem.asset as? AVURLAsset {
      resolvedIndex = queue.firstIndex {
        library.getFileURL(for: $0) == asset.url
      }
    }

    guard let index = resolvedIndex, index >= 0, index < queue.count else {
      DiagnosticLog.shared.log(
        "transition",
        "Could not map current player item source=\(source) url=\((playerItem.asset as? AVURLAsset)?.url.lastPathComponent ?? "unknown")"
      )
      return
    }

    let song = queue[index]
    if currentItem?.id != song.id || currentQueueIndex != index {
      DiagnosticLog.shared.log(
        "transition",
        "Reconciled missed handoff source=\(source) old=\(currentItem?.title ?? "none") new=\(song.title) oldIndex=\(currentQueueIndex) newIndex=\(index) playerTime=\(playerItem.currentTime().seconds)"
      )
      updateStateForAutoAdvancedSong(song, at: index)
    } else if let fixedDuration = authoritativeItemDurations[key] {
      applyResolvedDuration(fixedDuration, source: "reconciled asset timeline")
    }
  }

  func playArtist(_ artistName: String) {
    let artistSongs = library.songs.filter {
      $0.artist.localizedCaseInsensitiveCompare(artistName) == .orderedSame
    }
    guard !artistSongs.isEmpty else { return }
    playQueue(artistSongs, startingAt: 0)
  }

  private func setupRemoteCommands() {
    let commandCenter = MPRemoteCommandCenter.shared()

    commandCenter.playCommand.addTarget { [weak self] _ in
      self?.play()
      return .success
    }
    commandCenter.pauseCommand.addTarget { [weak self] _ in
      self?.pause()
      return .success
    }
    commandCenter.togglePlayPauseCommand.addTarget { [weak self] _ in
      self?.playPause()
      return .success
    }

    commandCenter.nextTrackCommand.addTarget { [weak self] _ in
      self?.playNext()
      return .success
    }
    commandCenter.previousTrackCommand.addTarget { [weak self] _ in
      self?.playPrevious()
      return .success
    }

    commandCenter.skipForwardCommand.preferredIntervals = [15]
    commandCenter.skipForwardCommand.addTarget { [weak self] _ in
      self?.skipForward()
      return .success
    }
    commandCenter.skipBackwardCommand.preferredIntervals = [15]
    commandCenter.skipBackwardCommand.addTarget { [weak self] _ in
      self?.skipBackward()
      return .success
    }

    commandCenter.changePlaybackPositionCommand.addTarget { [weak self] event in
      guard let self = self,
        let positionEvent = event as? MPChangePlaybackPositionCommandEvent
      else { return .commandFailed }
      self.seek(to: positionEvent.positionTime)
      return .success
    }

    commandCenter.likeCommand.addTarget { [weak self] _ in
      guard let self = self, let song = self.currentItem else {
        return .commandFailed
      }
      _ = PlaylistManager.shared.toggleLike(song: song)
      self.updateNowPlaying()
      return .success
    }

    // Enable all relevant commands
    commandCenter.playCommand.isEnabled = true
    commandCenter.pauseCommand.isEnabled = true
    commandCenter.togglePlayPauseCommand.isEnabled = true
    commandCenter.nextTrackCommand.isEnabled = true
    commandCenter.previousTrackCommand.isEnabled = true
    commandCenter.skipForwardCommand.isEnabled = false
    commandCenter.skipBackwardCommand.isEnabled = false
    commandCenter.changePlaybackPositionCommand.isEnabled = true
    commandCenter.likeCommand.isEnabled = true

    commandCenter.likeCommand.localizedTitle = "Like"
  }

  // MARK: - Playback Controls

  func play(
    _ song: LibrarySong,
    from source: PlaySource = .library,
    playlistId: UUID? = nil
  ) {
    DiagnosticLog.shared.log(
      "playback",
      "Play requested title=\(song.title) format=\(library.getFileURL(for: song).pathExtension.lowercased()) storage=\(song.storageMode) queueIndex=\(currentQueueIndex)/\(queue.count)"
    )
    print("[VALIDATION] PlaybackController: play triggered for \(song.title)")

    if let current = currentItem {
      // Record end of current song before starting new one
      // Count as skip if listened for less than 10 seconds
      let isSkip = currentTime < 10
      historyTracker.songEnded(skipped: isSkip)
    }

    isLoading = true
    currentSource = source
    currentPlaylistId = playlistId

    setupAudioSession()

    // Must go through the library: a referenced song (Copy Imported Music
    // off) lives outside the container and its file is invisible to a plain
    // FileManager check until security-scoped access is opened.
    guard library.fileExists(for: song) else {
      print(
        "[ERROR] PlaybackController: Audio file not found: \(library.getFileURL(for: song).path)")
      isLoading = false
      return
    }

    Task {
      let item = await createPlayerItem(
        for: song,
        trimTrailingSilence: shouldTrimGaplessEnding(
          at: currentQueueIndex,
          songID: song.id
        )
      )

      await MainActor.run {
        print(
          "[VALIDATION] PlaybackController: AVPlayerItem ready with audioMix: \(item.audioMix != nil)"
        )

        // A player that failed (e.g. its item pointed at a file that's since
        // been deleted) is stuck for good — AVQueuePlayer never recovers
        // from `.failed`, so reusing it here would silently no-op forever.
        // Tear it down and recreate instead of just checking for nil.
        if self.player?.status == .failed {
          self.cleanupPlayer()
        }
        if self.player == nil {
          self.player = AVQueuePlayer(items: [item])
          // Local files are already on disk, so letting the player hold back
          // to build a buffer only inserts a delay at each track transition —
          // which is exactly the gap gapless playback is meant to avoid.
          self.player?.automaticallyWaitsToMinimizeStalling = false
          self.applyEQPresetForPlayback()
          self.addTimeObserver()
          self.observePlayerItemChange()
        } else {
          self.player?.pause()
          self.releaseResourcesForQueuedItems()
          self.player?.removeAllItems()
          self.player?.insert(item, after: nil)
        }

        self.applyRepeatModeToPlayer()

        self.currentItem = song
        self.duration = song.duration > 0 ? song.duration : 0
        self.currentTime = 0
        self.lyricsClock.currentTime = 0

        // After `currentItem` is set: the normalization gain is per-track, so
        // applying it earlier used the *previous* song's tag. The reuse branch
        // above never applied it at all.
        self.applyPlayerOutputVolume()

        self.player?.play()
        self.isPlaying = true
        self.isLoading = false

        self.updateUIForNewItem()
        self.historyTracker.songStarted(song, source: source, playlistId: playlistId)

        self.saveState()
      }
    }
  }

  func prepareForExternalPlayback() {
    player?.pause()
    isPlaying = false
    isLoading = false
    audioSessionConfigured = false
    updateNowPlaying()
  }

  private func createPlayerItem(
    for song: LibrarySong,
    includeAudioProcessing: Bool? = nil,
    trimTrailingSilence: Bool = false
  ) async -> AVPlayerItem {
    let url = library.getFileURL(for: song)

    let secured = song.storageMode == .referenced && url.startAccessingSecurityScopedResource()

    // Several valid FLAC files omit an optional SEEKTABLE metadata block.
    // AVFoundation's default approximate-timing mode then reports that an
    // exact seek landed at the requested timestamp while decoding from an
    // earlier frame, and AVQueuePlayer can run past the advertised duration
    // without advancing. Precise timing makes AVFoundation build the timing
    // information it needs from the stream itself.
    let asset = AVURLAsset(
      url: url,
      options: [AVURLAssetPreferPreciseDurationAndTimingKey: true]
    )
    let item = AVPlayerItem(asset: asset)
    let itemKey = ObjectIdentifier(item)
    let songID = song.id
    let songTitle = song.title
    itemSongIDs[itemKey] = songID
    if secured { itemSecurityScopedURLs[itemKey] = url }

    if trimTrailingSilence {
      // This never delays playback. For the current item it runs alongside
      // playback; for a queued item it normally finishes long before handoff.
      Task { @MainActor [weak self, weak item] in
        guard let playbackEnd = await GaplessSilenceAnalyzer.trailingPlaybackEnd(for: url),
          let self,
          let item,
          self.itemSongIDs[itemKey] == songID,
          let queueIndex = self.queue.firstIndex(where: { $0.id == songID }),
          self.shouldTrimGaplessEnding(at: queueIndex, songID: songID)
        else { return }

        self.gaplessPlaybackEndTimes[itemKey] = playbackEnd
        item.forwardPlaybackEndTime = CMTime(seconds: playbackEnd, preferredTimescale: 600)
        DiagnosticLog.shared.log(
          "transition",
          "Smart gapless ending title=\(songTitle) playbackEnd=\(playbackEnd)"
        )
      }
    }

    // Resolve duration from both the asset and its audio-track time range.
    // Some FLAC containers initially report a tag-derived duration through
    // AVPlayerItem that is shorter than the actual playable timeline.
    Task { @MainActor [weak self, weak item] in
      guard let self, let item else { return }
      do {
        let assetDuration = try await asset.load(.duration).seconds
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        var trackDurations: [TimeInterval] = []
        for track in tracks {
          let range = try await track.load(.timeRange)
          trackDurations.append(range.end.seconds)
        }
        let resolved = ([assetDuration] + trackDurations)
          .filter { $0.isFinite && $0 > 0 }
          .max() ?? 0
        self.authoritativeItemDurations[itemKey] = resolved
        DiagnosticLog.shared.log(
          "duration",
          "Resolved asset=\(assetDuration) tracks=\(trackDurations) fixed=\(resolved) song=\(song.title)"
        )
        guard self.player?.currentItem === item else { return }
        self.applyResolvedDuration(resolved, source: "asset timeline")
      } catch {
        DiagnosticLog.shared.log("duration", "Resolution failed: \(error)")
      }
    }

    // A processing tap is expensive and has historically been the least
    // reliable part of long-running FLAC playback. Do not install a no-op tap,
    // and never analyze a native gapless preload.
    let shouldProcess = includeAudioProcessing ?? VocalIsolator.shared.requiresProcessing
    if shouldProcess {
      do {
      let tracks = try await asset.loadTracks(withMediaType: .audio)
      if let audioTrack = tracks.first {
        let instrumentActivity = SonicRecommendationService.shared.instrumentActivity(for: song)
        if let audioMix = VocalIsolator.shared.createAudioMix(
          for: audioTrack,
          instrumentActivity: instrumentActivity
        ) {
          item.audioMix = audioMix
          DiagnosticLog.shared.log(
            "audio-processing",
            "Created VocalSlider tap title=\(song.title) level=\(currentVocalLevel) "
              + "mode=\(instrumentActivity == nil ? "fallback" : "music-understanding") "
              + "vocalPoints=\(instrumentActivity?.vocal.count ?? 0)"
          )
          print(
            "[VALIDATION] PlaybackController: Assigned AVAudioMix to AVPlayerItem for \(song.title)"
          )
        } else {
          print("[ERROR] PlaybackController: Failed to create audioMix for \(song.title)")
        }
      } else {
        print("[ERROR] PlaybackController: No audio track found for \(song.title)")
      }
      } catch {
        DiagnosticLog.shared.log("error", "Audio processing setup failed title=\(song.title): \(error)")
        print("[ERROR] PlaybackController: Failed to load tracks: \(error)")
      }
    }

    DiagnosticLog.shared.log(
      "player-item",
      "Created title=\(song.title) preciseTiming=true processing=\(shouldProcess) referencedScope=\(secured)"
    )
    observePlayerItem(item)
    return item
  }

  private func observePlayerItem(_ item: AVPlayerItem) {
    let statusObs = item.observe(\.status, options: [.new]) {
      [weak self] item, _ in
      Task { @MainActor in
        if item.status == .readyToPlay {
          DiagnosticLog.shared.log("player-item", "Ready song=\(self?.itemSongIDs[ObjectIdentifier(item)]?.uuidString ?? "unknown")")
          print("[VALIDATION] PlaybackController: AVPlayerItem status .readyToPlay")
          // Only the item actually playing may set the duration. Gapless
          // preloads the *next* track while this one is still going, and it
          // becomes ready mid-playback — without this guard it overwrote the
          // current track's duration with the next one's, so the scrubber hit
          // the end early and playback appeared to run past it.
          guard self?.player?.currentItem === item else { return }
          self?.applyDurationReportedByPlayer(
            CMTimeGetSeconds(item.duration),
            for: item,
            source: "player item"
          )
        } else if item.status == .failed {
          DiagnosticLog.shared.log("error", "Player item failed: \(item.error?.localizedDescription ?? "unknown")")
          print(
            "[ERROR] PlaybackController: AVPlayerItem failed: \(String(describing: item.error))")
          // Only the actively-playing item failing needs a response — a
          // preloaded next-item failure just gets discovered fresh when
          // play() reaches it. Skip ahead rather than sitting on a dead item.
          if self?.player?.currentItem === item {
            self?.playNext()
          } else if let self, self.player?.items().contains(where: { $0 === item }) == true {
            self.player?.remove(item)
            self.releaseResources(for: item)
            self.prepareNextItem()
          }
        }
      }
    }
    let durationObs = item.observe(\.duration, options: [.new]) {
      [weak self] item, _ in
      Task { @MainActor in
        guard let self, self.player?.currentItem === item else { return }
        self.applyDurationReportedByPlayer(
          item.duration.seconds,
          for: item,
          source: "duration change"
        )
      }
    }
    itemObservers[ObjectIdentifier(item)] = [statusObs, durationObs]
  }

  private func applyResolvedDuration(_ candidate: TimeInterval, source: String) {
    guard candidate.isFinite, candidate > 0 else { return }
    // A duration behind the actual player clock is demonstrably stale.
    guard candidate + 0.25 >= currentTime else {
      DiagnosticLog.shared.log(
        "duration",
        "Rejected stale \(source)=\(candidate), playerTime=\(currentTime) title=\(currentItem?.title ?? "unknown")"
      )
      return
    }
    guard abs(candidate - duration) > 0.05 else { return }
    duration = candidate
    DiagnosticLog.shared.log(
      "duration",
      "Updated from \(source) value=\(candidate) title=\(currentItem?.title ?? "unknown")"
    )
    updateNowPlaying()
  }

  private func applyDurationReportedByPlayer(
    _ candidate: TimeInterval,
    for item: AVPlayerItem,
    source: String
  ) {
    let key = ObjectIdentifier(item)
    if let fixedDuration = authoritativeItemDurations[key] {
      if candidate.isFinite, abs(candidate - fixedDuration) > 0.1 {
        DiagnosticLog.shared.log(
          "duration",
          "Ignored changing \(source)=\(candidate); fixed=\(fixedDuration) playerTime=\(currentTime)"
        )
      }
      applyResolvedDuration(fixedDuration, source: "fixed asset timeline")
    } else {
      applyResolvedDuration(candidate, source: source)
    }
  }

  private func prepareNextItem() {
    guard repeatMode != .one,
      let player = player,
      usesNativeGaplessPlayback
    else {
      return
    }

    // Only queue the next item if it's not already queued
    guard player.items().count < 2 else { return }

    let nextIndex = currentQueueIndex + 1
    if nextIndex < queue.count {
      let nextSong = queue[nextIndex]
      let expectedCurrentItem = player.currentItem
      let expectedCurrentSongID = currentItem?.id
      let expectedNextSongID = nextSong.id
      if gaplessPreloadSongID == expectedNextSongID, gaplessPreloadToken != nil {
        return
      }
      let preloadToken = UUID()
      gaplessPreloadToken = preloadToken
      gaplessPreloadSongID = expectedNextSongID
      guard library.fileExists(for: nextSong) else {
        gaplessPreloadToken = nil
        gaplessPreloadSongID = nil
        print("[ERROR] PlaybackController: Skipping gapless preload, file missing for \(nextSong.title)")
        return
      }
      print("[VALIDATION] PlaybackController: preparing next item \(nextSong.title)")

      Task {
        let nextItem = await createPlayerItem(
          for: nextSong,
          includeAudioProcessing: false,
          trimTrailingSilence: nextIndex < queue.count - 1 || repeatMode == .all
        )
        await MainActor.run {
          guard self.gaplessPreloadToken == preloadToken else {
            self.releaseResources(for: nextItem)
            return
          }
          self.gaplessPreloadToken = nil
          self.gaplessPreloadSongID = nil

          // Item creation loads tracks asynchronously. Do not let an old task
          // insert its result after a skip, shuffle, or automatic handoff.
          guard self.player === player,
            self.repeatMode != .one,
            self.usesNativeGaplessPlayback,
            player.currentItem === expectedCurrentItem,
            self.currentItem?.id == expectedCurrentSongID,
            self.currentQueueIndex + 1 == nextIndex,
            nextIndex < self.queue.count,
            self.queue[nextIndex].id == expectedNextSongID
          else {
            self.releaseResources(for: nextItem)
            return
          }

          if player.items().count < 2 {
            player.insert(nextItem, after: player.currentItem)
            DiagnosticLog.shared.log("transition", "Preloaded next item index=\(nextIndex) title=\(nextSong.title)")
            print("[VALIDATION] PlaybackController: Inserted next item into player")
          } else {
            self.releaseResources(for: nextItem)
          }
        }
      }
    }
  }

  func jumpToQueueIndex(_ index: Int) {
    guard index >= 0 && index < queue.count else { return }
    currentQueueIndex = index
    play(
      queue[currentQueueIndex],
      from: currentSource,
      playlistId: currentPlaylistId
    )
  }

  func playQueue(
    _ songs: [LibrarySong],
    startingAt index: Int = 0,
    from source: PlaySource = .library,
    playlistId: UUID? = nil
  ) {
    guard index >= 0 && index < songs.count else { return }

    let selectedSong = songs[index]
    originalQueue = songs

    if shuffleMode == .on {
      var remaining = songs
      remaining.remove(at: index)
      remaining.shuffle()
      queue = [selectedSong] + remaining
      currentQueueIndex = 0
    } else {
      queue = songs
      currentQueueIndex = index
    }

    play(queue[currentQueueIndex], from: source, playlistId: playlistId)
  }

  func restoreSavedQueue(
    _ songs: [LibrarySong],
    currentIndex: Int,
    shuffleMode: ShuffleMode,
    repeatMode: RepeatMode
  ) {
    guard !songs.isEmpty else { return }

    originalQueue = songs
    queue = songs
    currentQueueIndex = min(max(currentIndex, 0), songs.count - 1)
    if self.shuffleMode != .off {
      self.shuffleMode = .off
    }
    self.repeatMode = repeatMode
    play(queue[currentQueueIndex], from: .library)
    _ = shuffleMode  // Preserved in presets for future UX, but restore keeps explicit queue order.
    saveState()
  }

  /// Starts a radio queue seeded by `song`.
  /// The seed plays first, followed by up to 25 similar tracks discovered by
  /// RecommendationEngine. Playback source is `.radio` so history/stats handle
  /// it correctly.
  func playRadio(from song: LibrarySong) {
    let similar = RecommendationEngine.shared.buildRadioQueue(seed: song, limit: 25)
    let radioQueue = [song] + similar
    playQueue(radioQueue, startingAt: 0, from: .radio)
  }

  func playAlbum(_ album: Album, startingAtTrack index: Int = 0) {
    // Must match the order AlbumView lists tracks in — the caller passes an
    // index into that list, so a divergent sort here plays the wrong song.
    let sortedSongs = album.songs.sorted(by: LibrarySong.albumTrackOrder)
    playQueue(sortedSongs, startingAt: index, from: .album)
  }

  func playPlaylist(_ playlist: Playlist, startingAt index: Int = 0) {
    playQueue(
      playlist.orderedSongs,
      startingAt: index,
      from: .playlist,
      playlistId: playlist.id
    )
  }

  func play() {
    setupAudioSession()
    guard let player = player else {
      if let song = currentItem {
        play(song, from: currentSource, playlistId: currentPlaylistId)
      }
      return
    }

    player.play()
    DiagnosticLog.shared.log("playback", "Resume title=\(currentItem?.title ?? "unknown") at=\(currentTime)")
    isPlaying = true
    historyTracker.songResumed()
    refreshAnimatedArtworkForCurrentSong()
    updateNowPlaying()
  }

  func pause() {
    #if os(iOS)
      // An explicit pause, including one from headphones or the Lock Screen,
      // cancels any pending automatic resume from an earlier interruption.
      shouldResumeAfterSystemInterruption = false
    #endif
    player?.pause()
    if let playerTime = player?.currentTime().seconds,
      playerTime.isFinite, playerTime >= 0
    {
      currentTime = playerTime
      lyricsClock.currentTime = playerTime
    }
    isPlaying = false
    DiagnosticLog.shared.log("playback", "Pause title=\(currentItem?.title ?? "unknown") at=\(currentTime)")
    historyTracker.songPaused()
    updateNowPlaying()
  }

  func stopForSleepTimer(resetPosition: Bool = false) {
    player?.pause()
    isPlaying = false
    historyTracker.songPaused()

    if resetPosition {
      seek(to: 0)
    } else {
      if let currentItem {
        currentTime = max(currentTime, currentItem.duration)
        lyricsClock.currentTime = currentTime
      }
      updateCurrentLyric()
      updateNowPlaying()
      saveState()
    }
  }

  func playPause() {
    guard currentItem != nil else { return }
    if isPlaying {
      pause()
    } else {
      play()
    }
  }

  /// Identifies the in-flight seek so a completion handler from a
  /// superseded seek (or the timeout fallback below) can't clobber state
  /// written by a newer one.
  private var seekToken = UUID()

  func seek(to time: TimeInterval) {
    guard time.isFinite, time >= 0 else { return }
    // Never target past the end: a stale or mis-read duration would otherwise
    // strand playback beyond the last sample.
    let target = duration > 0 ? min(time, duration) : time
    cleanupCrossfade()
    DiagnosticLog.shared.log(
      "seek",
      "Requested from=\(player?.currentTime().seconds ?? currentTime) to=\(target) duration=\(duration) playing=\(isPlaying)"
    )

    self.currentTime = target
    self.lyricsClock.currentTime = target
    self.updateNowPlaying()

    if isScrubbing {
      debouncedUpdateLyric()
      return
    }

    isSeeking = true
    let token = UUID()
    seekToken = token
    let cmTime = CMTime(seconds: target, preferredTimescale: 600)
    guard let seekingPlayer = player, let seekingItem = seekingPlayer.currentItem else {
      isSeeking = false
      return
    }
    let shouldResumeAfterSeek = isPlaying
    let itemKey = ObjectIdentifier(seekingItem)
    let fixedDuration = authoritativeItemDurations[itemKey]
    DiagnosticLog.shared.log(
      "seek",
      "State before seek itemDuration=\(seekingItem.duration.seconds) fixedDuration=\(fixedDuration.map { String($0) } ?? "pending") seekable=\(timeRangesDescription(seekingItem.seekableTimeRanges)) loaded=\(timeRangesDescription(seekingItem.loadedTimeRanges))"
    )
    seekingPlayer.pause()
    seekingItem.cancelPendingSeeks()

    // Watchdog for a seek completion that never arrives — AVPlayer drops it
    // when the item is swapped mid-seek (gapless hand-off, crossfade), and
    // `isSeeking` staying true would freeze lyric sync permanently: both time
    // observers refuse to run while it's set.
    //
    // Deliberately generous, and deliberately does NOT read the player's
    // clock. Sample-accurate seeking on lossless formats regularly takes over
    // a second, so a short fuse fired mid-seek and wrote back the player's
    // *pre-seek* position — which snapped the progress bar backwards and then
    // let the time observer hold it there.
    Task { @MainActor [weak self] in
      try? await Task.sleep(for: .seconds(5))
      guard let self, self.seekToken == token, self.isSeeking else { return }
      print("[DEBUG] PlaybackController: seek watchdog fired at \(Int(target))s")
      self.isSeeking = false
      self.currentTime = target
      self.lyricsClock.currentTime = target
      self.updateCurrentLyric(at: target)
      self.updateNowPlaying()
      if shouldResumeAfterSeek { seekingPlayer.play() }
      DiagnosticLog.shared.log("seek", "Watchdog resumed player at=\(seekingPlayer.currentTime().seconds)")
    }

    seekingPlayer.seek(to: cmTime, toleranceBefore: .zero, toleranceAfter: .zero) {
      [weak self] finished in
      Task { @MainActor in
        // A newer seek has superseded this one; its own handler owns the state.
        guard let self, self.seekToken == token else { return }
        guard self.player === seekingPlayer,
          seekingPlayer.currentItem === seekingItem
        else {
          self.isSeeking = false
          DiagnosticLog.shared.log("seek", "Ignored completion after player item changed")
          return
        }
        self.isSeeking = false

        // AVPlayer can land slightly away from the requested timestamp,
        // especially for lossless files. It can also report `finished == false`
        // after an internal seek cancellation. In either case the player clock,
        // not the requested target, is the source of truth once seeking ends.
        let playerTime = self.player?.currentTime().seconds
        let resolvedTime = if let playerTime,
          playerTime.isFinite,
          playerTime >= 0
        {
          playerTime
        } else {
          target
        }

        self.currentTime = resolvedTime
        self.lyricsClock.currentTime = resolvedTime
        self.updateCurrentLyric(at: resolvedTime)
        self.updateNowPlaying()
        self.saveState()
        if shouldResumeAfterSeek { seekingPlayer.play() }
        DiagnosticLog.shared.log(
          "seek",
          "Completed target=\(target) actual=\(resolvedTime) finished=\(finished)"
        )

        if !finished {
          print("[DEBUG] PlaybackController: seek reconciled after cancellation")
        }
        self.scheduleSeekProbes(
          token: token,
          player: seekingPlayer,
          item: seekingItem,
          target: target
        )
      }
    }
  }

  private func scheduleSeekProbes(
    token: UUID,
    player: AVQueuePlayer,
    item: AVPlayerItem,
    target: TimeInterval
  ) {
    Task<Void, Never> { @MainActor [weak self, weak player, weak item] in
      let probeDelays: [TimeInterval] = [0.25, 1.0, 3.0, 6.0]
      for delay in probeDelays {
        try? await Task.sleep(for: .seconds(delay))
        guard let self, let player, let item, self.player === player,
          player.currentItem === item, self.seekToken == token
        else { return }
        let fixed = self.authoritativeItemDurations[ObjectIdentifier(item)]
        DiagnosticLog.shared.log(
          "seek-probe",
          "after=\(delay)s target=\(target) playerTime=\(player.currentTime().seconds) modelTime=\(self.currentTime) displayedDuration=\(self.duration) itemDuration=\(item.duration.seconds) fixedDuration=\(fixed.map { String($0) } ?? "pending") rate=\(player.rate) status=\(player.timeControlStatus.rawValue) seekable=\(self.timeRangesDescription(item.seekableTimeRanges))"
        )
      }
    }
  }

  private func timeRangesDescription(_ values: [NSValue]) -> String {
    values.map { value in
      let range = value.timeRangeValue
      return "\(range.start.seconds)-\(range.end.seconds)"
    }.joined(separator: ",")
  }

  private var lyricUpdateTask: Task<Void, Never>?
  private func debouncedUpdateLyric() {
    lyricUpdateTask?.cancel()
    lyricUpdateTask = Task {
      try? await Task.sleep(for: .milliseconds(100))
      if !Task.isCancelled {
        updateCurrentLyric()
      }
    }
  }

  func skipForward() {
    seek(to: min(currentTime + 15, duration))
  }

  func skipBackward() {
    seek(to: max(0, currentTime - 15))
  }

  // MARK: - Queue Navigation

  func playPrevious() {
    if currentTime > 3 {
      seek(to: 0)
      // Same reasoning as skipping forward: pressing Previous while paused
      // should play, not silently rewind.
      if !isPlaying { play() }
      return
    }

    guard currentQueueIndex > 0 else {
      if repeatMode == .all && !queue.isEmpty {
        currentQueueIndex = queue.count - 1
        play(
          queue[currentQueueIndex],
          from: currentSource,
          playlistId: currentPlaylistId
        )
      }
      return
    }

    currentQueueIndex -= 1
    play(
      queue[currentQueueIndex],
      from: currentSource,
      playlistId: currentPlaylistId
    )
    updateWidget(force: true)
  }

  func playNext() {
    cleanupCrossfade()

    if let current = currentItem, currentTime < 10 {
      historyTracker.songEnded(skipped: true)
    } else {
      historyTracker.songEnded(skipped: false)
    }

    if repeatMode == .one {
      seek(to: 0)
      play()
      return
    }

    guard currentQueueIndex < queue.count - 1 else {
      if repeatMode == .all && !queue.isEmpty {
        currentQueueIndex = 0
        play(
          queue[currentQueueIndex],
          from: currentSource,
          playlistId: currentPlaylistId
        )
      } else {
        pause()
        seek(to: 0)
      }
      return
    }

    let nextIndex = currentQueueIndex + 1
    let nextSong = queue[nextIndex]

    // An explicit skip must build a fresh player item. Promoting the gapless
    // preload here can race its audio-processing tap/route setup: AVPlayer
    // reports the item as playing and advances time, but produces no audio.
    // Automatic end-of-track handoffs can still use the preload.
    currentQueueIndex = nextIndex
    play(nextSong, from: currentSource, playlistId: currentPlaylistId)
    saveState()
    updateWidget(force: true)
  }

  private func updateUIForNewItem() {
    guard let song = currentItem else { return }
    applyEQPresetForPlayback()
    applyPlayerOutputVolume()
    
    // Reset time immediately to prevent scrubber lag from previous track
    self.currentTime = 0
    self.lyricsClock.currentTime = 0
    self.duration = song.duration > 0 ? song.duration : 0
    self.currentLyrics = nil
    self.currentLyricIndex = nil
    
    // Force immediate remote command and lock screen update
    updateNowPlaying()
    
    prepareNextItem()
    refreshAnimatedArtworkForCurrentSong()
    Task {
      await loadLyrics(for: song)
    }
  }

  /// Re-evaluates the opt-in source without scanning the library. This is
  /// called by Settings and whenever playback moves to a different album.
  func refreshAnimatedArtworkFromSettings() {
    guard preferences?.animatedArtworkEnabled == true,
      isPlaying,
      let song = currentItem
    else {
      AnimatedArtworkService.shared.clearCurrent()
      updateNowPlaying()
      return
    }
    AnimatedArtworkService.shared.load(for: song)
  }

  private func refreshAnimatedArtworkForCurrentSong() {
    guard preferences?.animatedArtworkEnabled == true,
      isPlaying,
      let song = currentItem
    else {
      AnimatedArtworkService.shared.clearCurrent()
      return
    }
    AnimatedArtworkService.shared.load(for: song)
  }

  func animatedArtworkDidChange(for songID: UUID) {
    guard currentItem?.id == songID else { return }
    updateNowPlaying()
  }

  // MARK: - Queue Management

  func addToQueue(_ song: LibrarySong) {
    queue.append(song)
    if shuffleMode != .off {
      originalQueue.append(song)
    }
    prepareNextItem()
    saveState()
  }

  func addToQueue(_ songs: [LibrarySong]) {
    queue.append(contentsOf: songs)
    if shuffleMode != .off {
      originalQueue.append(contentsOf: songs)
    }
    prepareNextItem()
    saveState()
  }

  func playNext(_ song: LibrarySong) async {
    let insertIndex = min(currentQueueIndex + 1, queue.count)
    queue.insert(song, at: insertIndex)
    if shuffleMode != .off {
      originalQueue.append(song)
    }

    // Insert into AVQueuePlayer
    if let player = player {
      let item = await createPlayerItem(
        for: song,
        trimTrailingSilence: insertIndex < queue.count - 1 || repeatMode == .all
      )
      player.insert(item, after: player.currentItem)
    }
    saveState()
  }

  func removeFromQueue(at index: Int) {
    guard index >= 0 && index < queue.count else { return }

    let songId = queue[index].id
    queue.remove(at: index)

    if shuffleMode != .off {
      originalQueue.removeAll { $0.id == songId }
    }

    if index < currentQueueIndex {
      currentQueueIndex -= 1
    } else if index == currentQueueIndex {
      // If we removed the currently playing song, play what is now at the current index
      if queue.isEmpty {
        pause()
        currentItem = nil
        currentQueueIndex = 0
        cleanupPlayer()
      } else {
        // If we were at the last item, move to the new last item or wrap
        if currentQueueIndex >= queue.count {
          if repeatMode == .all {
            currentQueueIndex = 0
          } else {
            pause()
            currentItem = nil
            currentQueueIndex = 0
            releaseResourcesForQueuedItems()
            player?.removeAllItems()
            saveState()
            return
          }
        }

        let nextSong = queue[currentQueueIndex]
        play(
          nextSong,
          from: currentSource,
          playlistId: currentPlaylistId
        )
      }
    } else if index == currentQueueIndex + 1 {
      // If it was the next item in AVQueuePlayer, remove it
      if let player = player {
        let items = player.items()
        if items.count > 1 {
          releaseResources(for: items[1])
          player.remove(items[1])
          prepareNextItem()
        }
      }
    }
    saveState()
  }

  func clearQueue() {
    queue.removeAll()
    originalQueue.removeAll()
    currentQueueIndex = 0
    cleanupPlayer()
    saveState()
  }

  /// Clears every retained song reference before a destructive library reset.
  /// Unlike `clearQueue`, this intentionally does not persist playback state,
  /// because that state is about to be deleted as part of the same operation.
  func prepareForLibraryReset() {
    cleanupPlayer()
    isPlaying = false
    queue.removeAll()
    originalQueue.removeAll()
    currentItem = nil
    currentQueueIndex = 0
    currentTime = 0
    lyricsClock.currentTime = 0
    currentLyricIndex = 0
    historyTracker.discardCurrentSong()
    updateNowPlaying()
  }

  func moveSong(from sourceIndex: Int, to destinationIndex: Int) {
    guard sourceIndex >= 0 && sourceIndex < queue.count,
      destinationIndex >= 0 && destinationIndex < queue.count
    else { return }

    let song = queue.remove(at: sourceIndex)
    queue.insert(song, at: destinationIndex)

    if sourceIndex == currentQueueIndex {
      currentQueueIndex = destinationIndex
    } else if sourceIndex < currentQueueIndex
      && destinationIndex >= currentQueueIndex
    {
      currentQueueIndex -= 1
    } else if sourceIndex > currentQueueIndex
      && destinationIndex <= currentQueueIndex
    {
      currentQueueIndex += 1
    }

    // Re-sync AVQueuePlayer if necessary (e.g. if next item changed)
    if sourceIndex == currentQueueIndex + 1
      || destinationIndex == currentQueueIndex + 1
    {
      if let player = player {
        let items = player.items()
        if items.count > 1 {
          releaseResources(for: items[1])
          player.remove(items[1])
        }
        prepareNextItem()
      }
    }
    saveState()
  }

  // MARK: - Shuffle

  private func applyShuffleMode() {
    switch shuffleMode {
    case .off:
      if let currentSong = currentItem,
        let originalIndex = originalQueue.firstIndex(where: {
          $0.id == currentSong.id
        })
      {
        queue = originalQueue
        currentQueueIndex = originalIndex
      }

    case .on:
      originalQueue = queue

      if !queue.isEmpty {
        let currentSong = queue[currentQueueIndex]
        var remaining = queue
        remaining.remove(at: currentQueueIndex)
        remaining.shuffle()

        queue = [currentSong] + remaining
        currentQueueIndex = 0
      }
    }

    // After shuffle, we should update the next item in AVQueuePlayer
    if let player = player {
      let items = player.items()
      if items.count > 1 {
        releaseResources(for: items[1])
        player.remove(items[1])
      }
      prepareNextItem()
    }
  }

  func toggleShuffle() {
    shuffleMode = shuffleMode == .off ? .on : .off
  }

  // MARK: - Repeat

  func cycleRepeatMode() {
    switch repeatMode {
    case .off: repeatMode = .all
    case .all: repeatMode = .one
    case .one: repeatMode = .off
    }
  }

  // MARK: - Lyrics

  private func loadLyrics(for song: LibrarySong) async {
    let lyricsService = LyricsService.shared

    // Collects word-synced, line-synced and plain in one pass and caches all
    // of them; which one gets drawn is decided at render time from the
    // word-synced preference.
    let fetched = await lyricsService.fetchLyrics(for: song)
    guard currentItem?.id == song.id else { return }
    currentLyrics = fetched ?? lyricsService.getCachedLyrics(for: song)

    lyricsClock.currentTime = currentTime
    updateCurrentLyric()
    updateWidget(force: true)
  }

  func ensureWordSyncedLyricsForCurrentSong() {
    guard let song = currentItem else { return }

    Task {
      let lyricsService = LyricsService.shared
      if let wordSyncedLyrics = await lyricsService.fetchWordSyncedLyrics(for: song) {
        currentLyrics = wordSyncedLyrics
        updateCurrentLyric()
        updateWidget(force: true)
      }
    }
  }

  private func updateCurrentLyric(at playbackTime: TimeInterval? = nil) {
    guard !lyricLineTimestamps.isEmpty else {
      currentLyricIndex = nil
      return
    }

    let time = adjustedLyricsTime(for: playbackTime ?? lyricsClock.currentTime)
    let newIndex: Int?
    if time < lyricLineTimestamps[0] {
      newIndex = nil
    } else {
      var lowerBound = 0
      var upperBound = lyricLineTimestamps.count
      while lowerBound < upperBound {
        let midpoint = lowerBound + (upperBound - lowerBound) / 2
        if lyricLineTimestamps[midpoint] <= time {
          lowerBound = midpoint + 1
        } else {
          upperBound = midpoint
        }
      }
      newIndex = lowerBound - 1
    }

    if newIndex != currentLyricIndex {
      currentLyricIndex = newIndex
      updateWidget(force: true)
    }
  }

  var currentLyricLine: LyricLine? {
    guard let index = currentLyricIndex,
      let lyrics = currentLyrics,
      index >= 0, index < lyrics.lines.count
    else { return nil }
    return lyrics.lines[index]
  }

  func refreshLyrics() async {
    guard let song = currentItem else { return }
    currentLyrics = await LyricsService.shared.refreshLyrics(for: song)
    updateCurrentLyric()
    updateWidget()
  }

  // MARK: - Now Playing Info

  private func updateNowPlaying() {
    guard let song = currentItem else {
      MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
      return
    }

    var nowPlayingInfo: [String: Any] = [
      MPMediaItemPropertyTitle: song.title,
      MPMediaItemPropertyArtist: song.artist,
      MPMediaItemPropertyAlbumTitle: song.album ?? "",
      MPMediaItemPropertyPlaybackDuration: duration,
      MPNowPlayingInfoPropertyElapsedPlaybackTime: currentTime,
      MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? 1.0 : 0.0,
      MPNowPlayingInfoPropertyDefaultPlaybackRate: 1.0,
      MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.audio.rawValue,
    ]

    #if os(iOS)
      if let url = PathManager.resolve(song.effectiveArtworkPath),
        let imageData = try? Data(contentsOf: url),
        let image = UIImage(data: imageData)
      {
        let artwork = MPMediaItemArtwork(boundsSize: image.size) { _ in
          image
        }
        nowPlayingInfo[MPMediaItemPropertyArtwork] = artwork

        if #available(iOS 26.0, *),
          preferences?.animatedArtworkEnabled == true,
          let animated = AnimatedArtworkService.shared.artwork(for: song.id)
        {
          let supportedKeys = MPNowPlayingInfoCenter.supportedAnimatedArtworkKeys
          if supportedKeys.contains(MPNowPlayingInfoProperty1x1AnimatedArtwork) {
            nowPlayingInfo[MPNowPlayingInfoProperty1x1AnimatedArtwork] =
              AnimatedArtworkService.shared.lockScreenArtwork(
                remoteURL: animated.squareURL,
                previewImage: image,
                title: "\(animated.artist) — \(animated.album)",
                songID: song.id
              )
          }
          if let tallURL = animated.tallURL,
            supportedKeys.contains(MPNowPlayingInfoProperty3x4AnimatedArtwork)
          {
            nowPlayingInfo[MPNowPlayingInfoProperty3x4AnimatedArtwork] =
              AnimatedArtworkService.shared.lockScreenArtwork(
                remoteURL: tallURL,
                previewImage: image,
                title: "\(animated.artist) — \(animated.album)",
                songID: song.id
              )
          }
        }
      }
    #endif

    MPNowPlayingInfoCenter.default().nowPlayingInfo = nowPlayingInfo
    MPNowPlayingInfoCenter.default().playbackState = isPlaying ? .playing : .paused

    // Update remote command state
    MPRemoteCommandCenter.shared().likeCommand.isActive = PlaylistManager.shared.isLiked(song: song)

    WatchSyncService.shared.updatePlaybackStatus(
      song: song,
      isPlaying: isPlaying,
      currentTime: currentTime,
      duration: duration
    )

    updateWidget(force: true)
  }

  private var lastWidgetSongId: UUID?
  private var lastWidgetIsPlaying: Bool?
  private var lastWidgetUpdateTime: Date = .distantPast

  private func updateWidget(force: Bool = false) {
    let now = Date()
    let songId = currentItem?.id

    if force || isPlaying != lastWidgetIsPlaying
      || songId != lastWidgetSongId
      || now.timeIntervalSince(lastWidgetUpdateTime) > 10
    {

      lastWidgetIsPlaying = isPlaying
      lastWidgetSongId = songId
      lastWidgetUpdateTime = now

      WidgetSyncService.shared.updatePlaybackStatus(
        song: currentItem,
        upcomingSongs: Array(queue.dropFirst(min(currentQueueIndex + 1, queue.count)).prefix(3)),
        isPlaying: isPlaying,
        currentTime: currentTime,
        duration: duration,
        lyrics: currentLyrics
      )
    }
  }

  // MARK: - Persistence

  private func saveState() {
    guard !isInitializing else { return }
    guard let state = persistentState, let context = modelContext else {
      print(
        "[DEBUG] PlaybackController.saveState: FAILED - state or context nil"
      )
      return
    }

    let songId = currentItem?.id
    state.lastSongId = songId
    state.lastTime = currentTime
    state.lastQueueIds = queue.map { $0.id }
    state.lastQueueIndex = currentQueueIndex
    state.lastSourceRaw = currentSource.rawValue
    state.lastPlaylistId = currentPlaylistId
    state.shuffleModeRaw = shuffleMode.rawValue
    state.repeatModeRaw = repeatMode.rawValue
    state.vocalLevel = currentVocalLevel

    do {
      try context.save()
    } catch {
      print(
        "[DEBUG] PlaybackController.saveState: ERROR saving context: \(error)"
      )
    }
  }

  /// Finds the closest index in `songs` (searching outward from
  /// `startingAt`) whose audio file actually exists on disk, so a stale
  /// saved index pointing at a deleted file doesn't get handed to the player.
  /// Returns `nil` if nothing in `songs` is playable.
  private func nearestPlayableIndex(in songs: [LibrarySong], startingAt: Int) -> Int? {
    guard !songs.isEmpty else { return nil }
    let start = min(max(startingAt, 0), songs.count - 1)
    if library.fileExists(for: songs[start]) { return start }
    var offset = 1
    while start - offset >= 0 || start + offset < songs.count {
      if start + offset < songs.count, library.fileExists(for: songs[start + offset]) {
        return start + offset
      }
      if start - offset >= 0, library.fileExists(for: songs[start - offset]) {
        return start - offset
      }
      offset += 1
    }
    return nil
  }

  private func restoreState() {
    print("[DEBUG] PlaybackController.restoreState: Starting restoration")
    guard let state = persistentState else {
      print(
        "[DEBUG] PlaybackController.restoreState: FAILED - persistentState is nil"
      )
      return
    }

    guard let songId = state.lastSongId else {
      print(
        "[DEBUG] PlaybackController.restoreState: No lastSongId found in state"
      )
      return
    }

    print(
      "[DEBUG] PlaybackController.restoreState: Found lastSongId \(songId). Queue count in state: \(state.lastQueueIds.count)"
    )

    guard let restoredSong = library.songs.first(where: { $0.id == songId }) else {
      print(
        "[DEBUG] PlaybackController.restoreState: FAILED - lastSongId \(songId) not found in library"
      )
      return
    }

    // Fetch the songs for the queue
    let songIds = state.lastQueueIds
    var restoredQueue: [LibrarySong] = []

    for id in songIds {
      if let song = library.songs.first(where: { $0.id == id }) {
        restoredQueue.append(song)
      }
    }

    if restoredQueue.isEmpty {
      restoredQueue = [restoredSong]
    } else if !restoredQueue.contains(where: { $0.id == restoredSong.id }) {
      restoredQueue.insert(restoredSong, at: min(max(state.lastQueueIndex, 0), restoredQueue.count))
    }

    // Files can vanish out from under the library (e.g. deleted via the
    // Files app) between app launches. Restoring a player against a song
    // whose file is gone poisons the AVQueuePlayer for good — every future
    // play() call reuses that dead player and silently no-ops — so pick the
    // nearest song that still has a readable file instead of trusting the
    // saved index blindly.
    let preferredIndex =
      restoredQueue.firstIndex(where: { $0.id == restoredSong.id })
      ?? min(max(state.lastQueueIndex, 0), max(restoredQueue.count - 1, 0))
    let resolvedQueueIndex =
      nearestPlayableIndex(in: restoredQueue, startingAt: preferredIndex) ?? preferredIndex

    if !restoredQueue.isEmpty {
      Task { @MainActor in
        print(
          "[DEBUG] PlaybackController.restoreState.MainActor: Setting up UI"
        )

        // Clean up any existing player before creating a new one
        self.cleanupPlayer()

        self.queue = restoredQueue
        self.originalQueue = restoredQueue
        self.currentQueueIndex = resolvedQueueIndex
        self.currentSource =
          PlaySource(rawValue: state.lastSourceRaw ?? "library")
          ?? .library
        self.currentPlaylistId = state.lastPlaylistId

        if currentQueueIndex < queue.count, library.fileExists(for: queue[currentQueueIndex]) {
          let song = queue[currentQueueIndex]
          print(
            "[DEBUG] PlaybackController.restoreState.MainActor: Current song: \(song.title)"
          )
          self.currentItem = song
          self.currentTime = state.lastTime
          self.lyricsClock.currentTime = state.lastTime
          self.isPlaying = false

          // Prepare player but don't play
          let item = await createPlayerItem(
            for: song,
            trimTrailingSilence: shouldTrimGaplessEnding(
              at: currentQueueIndex,
              songID: song.id
            )
          )
          self.player = AVQueuePlayer(items: [item])
          self.player?.automaticallyWaitsToMinimizeStalling = false
          self.applyRepeatModeToPlayer()
          self.applyEQPresetForPlayback()
          self.applyPlayerOutputVolume()
          item.seek(
            to: CMTime(
              seconds: state.lastTime,
              preferredTimescale: 600
            ),
            completionHandler: nil
          )
          self.addTimeObserver()
          self.observePlayerItemChange()

          // Setup initial UI
          self.duration = song.duration > 0 ? song.duration : 0
          self.updateNowPlaying()
          self.prepareNextItem()

          print(
            "[DEBUG] PlaybackController.restoreState.MainActor: UI updated successfully at \(self.currentTime)s"
          )

          Task {
            await loadLyrics(for: song)
          }
        } else {
          print(
            "[DEBUG] PlaybackController.restoreState.MainActor: SKIPPED - no restorable song with a readable file at index \(currentQueueIndex)"
          )
        }
      }
    } else {
      print(
        "[DEBUG] PlaybackController.restoreState: FAILED - restored queue is empty"
      )
    }
  }
  // MARK: - Crossfade

  private var crossfadePlayer: AVPlayer?
  private var crossfadeNextSong: LibrarySong?
  private var crossfadeStarted = false

  private func startCrossfade(to nextSong: LibrarySong) {
    guard repeatMode != .one, !crossfadeStarted else { return }
    crossfadeStarted = true
    crossfadeNextSong = nextSong

    Task {
      let item = await createPlayerItem(for: nextSong)
      await MainActor.run {
        guard self.repeatMode != .one, self.crossfadeStarted,
          self.crossfadeNextSong?.id == nextSong.id
        else { return }
        let cf = AVPlayer(playerItem: item)
        cf.volume = 0
        self.crossfadePlayer = cf
        cf.play()
        print("[CROSSFADE] Started crossfade to \(nextSong.title)")
      }
    }
  }

  private func tickCrossfade() {
    guard crossfadeStarted,
      let cf = crossfadePlayer,
      duration > 0,
      let prefs = preferences,
      prefs.crossfadeEnabled
    else { return }

    let remaining = max(0, duration - currentTime)
    let fadeDuration = max(0.1, prefs.crossfadeDuration)
    let progress = Float(max(0, min(1, 1 - (remaining / fadeDuration))))

    player?.volume = (1 - progress) * effectiveOutputVolume
    cf.volume = progress * effectiveOutputVolume

    if progress >= 1.0 {
      completeCrossfade()
    }
  }

  private func completeCrossfade() {
    guard let cf = crossfadePlayer,
      let cfItem = cf.currentItem,
      let nextSong = crossfadeNextSong
    else {
      cleanupCrossfade()
      return
    }

    guard currentQueueIndex + 1 < queue.count else {
      cleanupCrossfade()
      return
    }

    cf.pause()
    let nextIndex = currentQueueIndex + 1

    cleanupPlayer()

    let newPlayer = AVQueuePlayer(items: [cfItem])
    newPlayer.automaticallyWaitsToMinimizeStalling = false
    newPlayer.volume = effectiveOutputVolume
    self.player = newPlayer
    applyRepeatModeToPlayer()
    self.addTimeObserver()
    self.observePlayerItemChange()
    newPlayer.play()

    currentQueueIndex = nextIndex
    currentItem = nextSong
    isPlaying = true

    prepareNextItem()
    updateUIForNewItem()
    historyTracker.songStarted(nextSong, source: currentSource, playlistId: currentPlaylistId)
    saveState()

    cleanupCrossfade()
    print("[CROSSFADE] Completed crossfade — now playing \(nextSong.title)")
  }

  private func cleanupCrossfade() {
    crossfadePlayer?.pause()
    crossfadePlayer = nil
    crossfadeNextSong = nil
    crossfadeStarted = false
  }

  // MARK: - Observers

  private var lastStateSaveTime: TimeInterval = -999
  private var lastDiagnosticHeartbeat = Date.distantPast

  private func addTimeObserver() {
    guard let player = player else { return }

    if let (observer, obsPlayer) = timeObserver {
      obsPlayer.removeTimeObserver(observer)
      timeObserver = nil
    }
    if let (observer, obsPlayer) = lyricTimeObserver {
      obsPlayer.removeTimeObserver(observer)
      lyricTimeObserver = nil
    }

    // Word timing is isolated from the general playback model so this higher
    // cadence only refreshes the active karaoke line.
    let lyricInterval = CMTime(seconds: 1.0 / 30.0, preferredTimescale: 600)
    let lyricObserver = player.addPeriodicTimeObserver(
      forInterval: lyricInterval,
      queue: .main
    ) {
      [weak self] time in
      MainActor.assumeIsolated {
        guard let self, !self.isScrubbing, !self.isSeeking else { return }
        guard !self.lyricLineTimestamps.isEmpty else { return }
        let seconds = time.seconds
        guard seconds.isFinite else { return }
        self.lyricsClock.currentTime = seconds
        self.updateCurrentLyric(at: seconds)
      }
    }
    lyricTimeObserver = (lyricObserver, player)

    // 0.5 s is enough for lyric sync and progress display while keeping the
    // main-thread update rate low. 0.1 s was causing every screen that embeds
    // the mini player (Home, Search, Album, Artist) to redraw 10×/second.
    let interval = CMTime(seconds: 0.5, preferredTimescale: 600)
    let observer = player.addPeriodicTimeObserver(
      forInterval: interval,
      queue: .main
    ) {
      [weak self] time in
      MainActor.assumeIsolated {
        guard let self = self, !self.isScrubbing, !self.isSeeking else { return }
        if let activeItem = player.currentItem {
          self.reconcileCurrentPlayerItem(activeItem, source: "periodic clock")
        }
        self.currentTime = time.seconds

        // Keep duration tied to whatever is actually playing. A gapless
        // hand-off reuses an item that became ready while it was still
        // queued, so its status observer never fires again — and stored tag
        // durations are unreliable on some formats.
        if let activeItem = self.player?.currentItem {
          self.applyDurationReportedByPlayer(
            activeItem.duration.seconds,
            for: activeItem,
            source: "periodic player item"
          )
        }

        // Crossfade tick
        if self.repeatMode != .one,
          let prefs = self.preferences, prefs.crossfadeEnabled,
          prefs.crossfadeDuration > 0, self.isPlaying, self.duration > 0
        {
          let remaining = self.duration - self.currentTime
          let fadeDuration = prefs.crossfadeDuration

          if !self.crossfadeStarted && remaining <= fadeDuration && remaining > 0 {
            let nextIndex = self.currentQueueIndex + 1
            if nextIndex < self.queue.count {
              self.startCrossfade(to: self.queue[nextIndex])
            }
          }

          if self.crossfadeStarted {
            self.tickCrossfade()
          }
        }

        // Save at most once every 5 seconds.
        if self.currentTime - self.lastStateSaveTime >= 5 {
          self.lastStateSaveTime = self.currentTime
          self.saveState()
        }


        let now = Date()
        if now.timeIntervalSince(self.lastDiagnosticHeartbeat) >= 30 {
          self.lastDiagnosticHeartbeat = now
          DiagnosticLog.shared.log(
            "heartbeat",
            "title=\(self.currentItem?.title ?? "none") time=\(self.currentTime)/\(self.duration) rate=\(player.rate) status=\(player.timeControlStatus.rawValue) queuedItems=\(player.items().count)"
          )
        }
      }
    }
    timeObserver = (observer, player)
  }
}
