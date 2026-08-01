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
  private var itemObservers: [NSKeyValueObservation] = []
  private let library = SongLibrary.shared
  private let historyTracker = ListeningHistoryTracker.shared
  private var audioSessionConfigured = false

  private var modelContext: ModelContext?
  private var preferences: UserPreferences?
  private var persistentState: PlaybackState?
  private var isInitializing = false

  // MARK: - Playback State

  private(set) var currentItem: LibrarySong?
  var currentTime: TimeInterval = 0
  private(set) var duration: TimeInterval = 0
  private(set) var isPlaying: Bool = false
  private(set) var isLoading: Bool = false
  var isScrubbing: Bool = false
  private(set) var isSeeking: Bool = false

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
    let soundCheck: Float = (preferences?.normalizeVolume ?? false) ? 0.94 : 1.0
    return min(1, volume * gain * soundCheck)
  }

  func refreshAudioEnhancementsFromSettings() {
    applyEQPresetForPlayback()
    applyPlayerOutputVolume()
  }

  private func applyEQPresetForPlayback() {
    let preset = UserDefaults.standard.string(forKey: "com.ampwave.audioEQPreset") ?? "flat"
    switch preset {
    case "voice":
      vocalLevel = 0.72
    default:
      vocalLevel = 1.0
    }
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
      currentVocalLevel = newValue
      VocalIsolator.shared.vocalLevel = newValue

      if isVocalSliderVisible {
        resetVocalSliderTimer()
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
      saveState()
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

  // MARK: - Source Tracking

  private(set) var currentSource: PlaySource = .library
  private var currentPlaylistId: UUID?

  private init() {
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
    itemObservers.forEach { $0.invalidate() }
    itemObservers.removeAll()
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

    // Apply defaults from preferences if not already set
    if let prefs = preferences {
      self.shuffleMode = prefs.defaultShuffleMode
      self.repeatMode = prefs.defaultRepeatMode
      print(
        "[DEBUG] PlaybackController.setModelContext: Applied defaults - Shuffle: \(shuffleMode), Repeat: \(repeatMode)"
      )
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
        pause()
      case .ended:
        if let optionsValue = userInfo[AVAudioSessionInterruptionOptionKey]
          as? UInt
        {
          let options = AVAudioSession.InterruptionOptions(
            rawValue: optionsValue
          )
          if options.contains(.shouldResume) {
            play()
          }
        }
      @unknown default:
        break
      }
    }

    @objc private func handleRouteChange(_ notification: Notification) {
      guard let userInfo = notification.userInfo,
        let reasonValue = userInfo[AVAudioSessionRouteChangeReasonKey]
          as? UInt,
        let reason = AVAudioSession.RouteChangeReason(rawValue: reasonValue)
      else { return }

      if reason == .oldDeviceUnavailable {
        pause()
      }
    }
  #endif

  @objc private func playerItemDidReachEnd(notification: Notification) {
    guard let item = notification.object as? AVPlayerItem,
      let player = player
    else { return }

    // If a crossfade is in progress and finished, it already advanced the queue
    if crossfadeStarted {
      completeCrossfade()
      return
    }

    // Ensure we are talking about the currently playing item that actually finished
    // AVQueuePlayer may have already moved currentItem forward, but 'item' is what just finished

    let isEndOfQueue = currentQueueIndex >= max(queue.count - 1, 0)
    if SleepTimerService.shared.handleTrackFinished(isEndOfQueue: isEndOfQueue) {
      stopForSleepTimer(resetPosition: false)
      return
    }

    // If repeat one, we should restart the item
    if repeatMode == .one {
      item.seek(to: .zero, completionHandler: nil)
      player.play()
    } else if queue.count > currentQueueIndex + 1 {
      // Automatic advance is handled by KVO (observePlayerItemChange)
      if !(preferences?.gaplessPlayback ?? true) {
        playNext()
      }
    } else if repeatMode == .all && !queue.isEmpty {
      // Repeat the whole queue by starting from 0
      currentQueueIndex = 0
      play(queue[0], from: currentSource, playlistId: currentPlaylistId)
    } else {
      isPlaying = false
      saveState()
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

        // Get the URL of the item currently playing in the AVPlayer
        guard let asset = newItem.asset as? AVURLAsset else { return }
        let playingURL = asset.url

        // Find which song in our queue matches this URL
        // First check the most likely candidate: the next song
        if self.currentQueueIndex + 1 < self.queue.count {
          let nextIndex = self.currentQueueIndex + 1
          let nextSong = self.queue[nextIndex]
          if self.library.getFileURL(for: nextSong) == playingURL {
            self.updateStateForAutoAdvancedSong(nextSong, at: nextIndex)
            return
          }
        }

        // If not the next song, search the whole queue (handles unexpected skips/shuffles)
        if let index = self.queue.firstIndex(where: {
          self.library.getFileURL(for: $0) == playingURL
        }) {
          self.updateStateForAutoAdvancedSong(self.queue[index], at: index)
        }
      }
    }
    itemObservers.append(obs)
  }

  private func updateStateForAutoAdvancedSong(_ song: LibrarySong, at index: Int) {
    print("[DEBUG] PlaybackController: Auto-advanced to \(song.title) at index \(index)")
    self.currentQueueIndex = index
    self.currentItem = song
    self.updateUIForNewItem()
    self.historyTracker.songStarted(
      song, source: self.currentSource, playlistId: self.currentPlaylistId)
    self.saveState()
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
      let item = await createPlayerItem(for: song)

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
          self.applyEQPresetForPlayback()
          self.applyPlayerOutputVolume()
          self.addTimeObserver()
          self.observePlayerItemChange()
        } else {
          self.player?.pause()
          self.player?.removeAllItems()
          self.player?.insert(item, after: nil)
        }

        self.currentItem = song
        self.duration = song.duration > 0 ? song.duration : 0
        self.currentTime = 0
        self.lyricsClock.currentTime = 0

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

  private func createPlayerItem(for song: LibrarySong) async -> AVPlayerItem {
    let url = library.getFileURL(for: song)

    if song.storageMode == .referenced {
      _ = url.startAccessingSecurityScopedResource()
    }

    let asset = AVURLAsset(url: url)
    let item = AVPlayerItem(asset: asset)

    // Vocal Isolation - Attach tap synchronously once tracks are loaded
    do {
      let tracks = try await asset.loadTracks(withMediaType: .audio)
      if let audioTrack = tracks.first {
        if let audioMix = VocalIsolator.shared.createAudioMix(for: audioTrack) {
          item.audioMix = audioMix
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
      print("[ERROR] PlaybackController: Failed to load tracks: \(error)")
    }

    observePlayerItem(item)
    return item
  }

  private func observePlayerItem(_ item: AVPlayerItem) {
    let statusObs = item.observe(\.status, options: [.new]) {
      [weak self] item, _ in
      Task { @MainActor in
        if item.status == .readyToPlay {
          print("[VALIDATION] PlaybackController: AVPlayerItem status .readyToPlay")
          let itemDuration = CMTimeGetSeconds(item.duration)
          if itemDuration.isFinite, itemDuration > 0 {
            self?.duration = itemDuration
            self?.updateNowPlaying()
          }
        } else if item.status == .failed {
          print(
            "[ERROR] PlaybackController: AVPlayerItem failed: \(String(describing: item.error))")
          // Only the actively-playing item failing needs a response — a
          // preloaded next-item failure just gets discovered fresh when
          // play() reaches it. Skip ahead rather than sitting on a dead item.
          if self?.player?.currentItem === item {
            self?.playNext()
          }
        }
      }
    }
    itemObservers.append(statusObs)
  }

  private func prepareNextItem() {
    guard let player = player, preferences?.gaplessPlayback ?? true else {
      return
    }

    // Only queue the next item if it's not already queued
    guard player.items().count < 2 else { return }

    let nextIndex = currentQueueIndex + 1
    if nextIndex < queue.count {
      let nextSong = queue[nextIndex]
      guard library.fileExists(for: nextSong) else {
        print("[ERROR] PlaybackController: Skipping gapless preload, file missing for \(nextSong.title)")
        return
      }
      print("[VALIDATION] PlaybackController: preparing next item \(nextSong.title)")

      Task {
        let nextItem = await createPlayerItem(for: nextSong)
        await MainActor.run {
          if player.items().count < 2 {
            player.insert(nextItem, after: player.currentItem)
            print("[VALIDATION] PlaybackController: Inserted next item into player")
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
    isPlaying = true
    historyTracker.songResumed()
    updateNowPlaying()
  }

  func pause() {
    player?.pause()
    isPlaying = false
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
    self.currentTime = time
    self.lyricsClock.currentTime = time

    if isScrubbing {
      debouncedUpdateLyric()
      return
    }

    isSeeking = true
    let token = UUID()
    seekToken = token
    let cmTime = CMTime(seconds: time, preferredTimescale: 600)

    // AVPlayer's seek completion handler can be dropped entirely if the
    // player item gets swapped out mid-seek (gapless auto-advance /
    // crossfade). Without a fallback, `isSeeking` would stay true forever,
    // which permanently freezes lyric sync: both periodic time observers
    // refuse to run while it's set, and the karaoke clock keeps
    // extrapolating from its last (now stale) anchor with nothing to ever
    // re-anchor it.
    Task { @MainActor [weak self] in
      try? await Task.sleep(for: .seconds(1.5))
      guard let self, self.seekToken == token, self.isSeeking else { return }
      self.isSeeking = false
      let playerSeconds = self.player?.currentTime().seconds
      let resolvedTime = (playerSeconds?.isFinite == true) ? playerSeconds! : time
      self.currentTime = resolvedTime
      self.lyricsClock.currentTime = resolvedTime
      self.updateCurrentLyric(at: resolvedTime)
      self.updateNowPlaying()
    }

    player?.seek(to: cmTime, toleranceBefore: .zero, toleranceAfter: .zero) {
      [weak self] finished in
      Task { @MainActor in
        guard let self, self.seekToken == token else { return }
        self.isSeeking = false
        if finished {
          self.currentTime = time
          self.lyricsClock.currentTime = time
          self.updateCurrentLyric(at: time)
          self.updateNowPlaying()
          self.saveState()
        }
      }
    }
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

    // For AVQueuePlayer, if we have advanceToNextItem and the next item matches, use it
    if let player = player, player.items().count > 1 {
      let nextPlayerItem = player.items()[1]
      if let asset = nextPlayerItem.asset as? AVURLAsset,
        asset.url == library.getFileURL(for: nextSong)
      {
        player.advanceToNextItem()
        // currentItem and UI will be updated by KVO (observePlayerItemChange)
        return
      }
    }

    // Fallback: manually play the next song
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
    Task {
      await loadLyrics(for: song)
    }
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
      let item = await createPlayerItem(for: song)
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

    // 1. Try full fetch (respects caching + word-sync upgrade inside fetchLyrics)
    let fetched = await lyricsService.fetchLyrics(for: song)
    guard currentItem?.id == song.id else { return }
    currentLyrics = fetched ?? lyricsService.getCachedLyrics(for: song)

    // 2. If word-sync is enabled but what we have is only line-synced, upgrade now.
    if let mc = modelContext {
      let prefs = UserPreferences.getOrCreate(in: mc)
      let hasWordSync = currentLyrics?.lines.contains { ($0.wordOffsets?.count ?? 0) > 1 } ?? false
      if prefs.wordSyncedLyricsEnabled && !hasWordSync
          && NetworkMonitor.shared.isOnline && !prefs.isOfflineMode {
        if let upgraded = await lyricsService.fetchWordSyncedLyrics(for: song) {
          guard currentItem?.id == song.id else { return }
          currentLyrics = upgraded
        }
      }
    }

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

    let time = playbackTime ?? lyricsClock.currentTime
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
          let item = await createPlayerItem(for: song)
          self.player = AVQueuePlayer(items: [item])
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
    guard !crossfadeStarted else { return }
    crossfadeStarted = true
    crossfadeNextSong = nextSong

    Task {
      let item = await createPlayerItem(for: nextSong)
      await MainActor.run {
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
    newPlayer.volume = effectiveOutputVolume
    self.player = newPlayer
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
        self.currentTime = time.seconds

        // Crossfade tick
        if let prefs = self.preferences, prefs.crossfadeEnabled,
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
      }
    }
    timeObserver = (observer, player)
  }
}
