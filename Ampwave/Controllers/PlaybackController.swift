//
//  PlaybackController.swift
//  Ampwave
//
//  Enhanced playback controller with AVQueuePlayer for gapless playback,
//  volume normalization, and persistence.
//

import AVFoundation
import Combine
import Foundation
import MediaPlayer
import SwiftData
internal import SwiftUI

#if os(iOS)
  import UIKit
#elseif os(macOS)
  import AppKit
#endif

@Observable
@MainActor
final class PlaybackController {
  static let shared = PlaybackController()

  private var player: AVQueuePlayer?
  private var timeObserver: Any?
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
  private(set) var currentTime: TimeInterval = 0
  private(set) var duration: TimeInterval = 0
  private(set) var isPlaying: Bool = false
  private(set) var isLoading: Bool = false

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

  private(set) var currentLyrics: SyncedLyric?
  private(set) var currentLyricIndex: Int?

  var hasLyrics: Bool {
    currentLyrics?.hasLyrics ?? false
  }

  // MARK: - Source Tracking

  private var currentSource: PlaySource = .library
  private var currentPlaylistId: UUID?

  private init() {
    setupRemoteCommands()
    setupNotifications()
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

    // Restore state
    restoreState()
    self.isInitializing = false
  }

  // MARK: - Mock for Previews

  func setupMockPlayback(song: LibrarySong, lyrics: SyncedLyric?, time: TimeInterval = 0) {
    self.currentItem = song
    self.currentLyrics = lyrics
    self.currentTime = time
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
          .playback, mode: .default, options: [.allowBluetooth, .allowAirPlay])
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

    // Handle item did play to end for manual queue management in AVQueuePlayer if needed
    NotificationCenter.default.addObserver(
      self,
      selector: #selector(playerItemDidReachEnd),
      name: .AVPlayerItemDidPlayToEndTime,
      object: nil
    )
  }

  @objc private func handleAudioSessionInterruption(_ notification: Notification) {
    guard let userInfo = notification.userInfo,
      let typeValue = userInfo[AVAudioSessionInterruptionTypeKey] as? UInt,
      let type = AVAudioSession.InterruptionType(rawValue: typeValue)
    else { return }

    switch type {
    case .began:
      pause()
    case .ended:
      if let optionsValue = userInfo[AVAudioSessionInterruptionOptionKey] as? UInt {
        let options = AVAudioSession.InterruptionOptions(rawValue: optionsValue)
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
      let reasonValue = userInfo[AVAudioSessionRouteChangeReasonKey] as? UInt,
      let reason = AVAudioSession.RouteChangeReason(rawValue: reasonValue)
    else { return }

    if reason == .oldDeviceUnavailable {
      pause()
    }
  }

  @objc private func playerItemDidReachEnd(notification: Notification) {
    guard let item = notification.object as? AVPlayerItem,
      let player = player
    else { return }

    // Ensure we are talking about the currently playing item that actually finished
    // AVQueuePlayer may have already moved currentItem forward, but 'item' is what just finished

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
    let obs = player.observe(\.currentItem, options: [.new]) { [weak self] player, _ in
      Task { @MainActor in
        guard let self = self, let newItem = player.currentItem else { return }

        // Get the URL of the item currently playing in the AVPlayer
        guard let asset = newItem.asset as? AVURLAsset else { return }
        let playingURL = asset.url

        // Find if this new item matches the next song in our queue
        // We look ahead to see if AVQueuePlayer advanced itself
        if self.currentQueueIndex + 1 < self.queue.count {
          let nextIndex = self.currentQueueIndex + 1
          let nextSong = self.queue[nextIndex]
          let nextSongURL = self.library.getFileURL(for: nextSong)

          if playingURL == nextSongURL {
            print("[DEBUG] AVQueuePlayer advanced automatically to \(nextSong.title)")
            self.currentQueueIndex = nextIndex
            self.currentItem = nextSong
            self.updateUIForNewItem()
            
            // Notify history tracker of the new song
            self.historyTracker.songStarted(nextSong, source: self.currentSource, playlistId: self.currentPlaylistId)
            
            self.saveState()
          }
        }
      }
    }
    itemObservers.append(obs)
  }

  private func setupRemoteCommands() {
    let commandCenter = MPRemoteCommandCenter.shared()

    // Play/pause handlers (keep if needed, but disable UI button)
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

    // Next/previous handlers (always enable these)
    commandCenter.nextTrackCommand.addTarget { [weak self] _ in
      self?.playNext()
      return .success
    }
    commandCenter.previousTrackCommand.addTarget { [weak self] _ in
      self?.playPrevious()
      return .success
    }

    // Skip handlers (disable to hide)
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
      guard let self = self, let song = self.currentItem else { return .commandFailed }
      PlaylistManager.shared.toggleLike(song: song)
      return .success
    }

    commandCenter.playCommand.isEnabled = true
    commandCenter.pauseCommand.isEnabled = true
    commandCenter.likeCommand.isEnabled = true

    // Disable unwanted buttons in Control Center
    commandCenter.togglePlayPauseCommand.isEnabled = false
    commandCenter.skipForwardCommand.isEnabled = false
    commandCenter.skipBackwardCommand.isEnabled = false
    commandCenter.changePlaybackPositionCommand.isEnabled = false

    // Enable only next/previous (conditionally if desired)
    //        commandCenter.nextTrackCommand.isEnabled = hasNextTrack()  // Implement your check
    //        commandCenter.previousTrackCommand.isEnabled = hasPreviousTrack()  // Implement your check
  }

  // MARK: - Playback Controls

  func play(_ song: LibrarySong, from source: PlaySource = .library, playlistId: UUID? = nil) {
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

    let url = library.getFileURL(for: song)
    guard FileManager.default.fileExists(atPath: url.path) else {
      print("Audio file not found: \(url.path)")
      isLoading = false
      return
    }

    let item = createPlayerItem(for: song)

    if player == nil {
      player = AVQueuePlayer(items: [item])
      addTimeObserver()
      observePlayerItemChange()
    } else {
      player?.removeAllItems()
      player?.insert(item, after: nil)
    }

    currentItem = song
    duration = song.duration > 0 ? song.duration : 0
    currentTime = 0

    // Prepare next item for gapless
    prepareNextItem()

    player?.play()
    isPlaying = true
    isLoading = false

    updateUIForNewItem()
    historyTracker.songStarted(song, source: source, playlistId: playlistId)

    Task {
      await loadLyrics(for: song)
    }

    saveState()
  }

  private func createPlayerItem(for song: LibrarySong) -> AVPlayerItem {
    let url = library.getFileURL(for: song)
    let asset = AVURLAsset(url: url)
    let item = AVPlayerItem(asset: asset)

    // Normalization logic
    if let prefs = preferences, prefs.normalizeVolume {
      applyNormalization(to: item)
    }

    observePlayerItem(item)
    return item
  }

  private func applyNormalization(to item: AVPlayerItem) {
    // Basic normalization using audio mix to target -14 LUFS roughly
    // In a real app, we would have pre-calculated ReplayGain values.
    // Here we can at least ensure peak isn't clipping or apply a slight gain correction if we had metadata.
    // For now, let's just ensure we have a mix that could be adjusted.
    let audioParams = AVMutableAudioMixInputParameters(
      track: item.asset.tracks(withMediaType: .audio).first)
    // Example: slightly reduce volume to avoid clipping in mixed environments
    audioParams.setVolume(0.9, at: .zero)
    let audioMix = AVMutableAudioMix()
    audioMix.inputParameters = [audioParams]
    item.audioMix = audioMix
  }

  private func observePlayerItem(_ item: AVPlayerItem) {
    let statusObs = item.observe(\.status, options: [.new]) { [weak self] item, _ in
      Task { @MainActor in
        if item.status == .readyToPlay {
          let itemDuration = CMTimeGetSeconds(item.duration)
          if itemDuration.isFinite, itemDuration > 0 {
            self?.duration = itemDuration
            self?.updateNowPlaying()
          }
        }
      }
    }
    itemObservers.append(statusObs)
  }

  private func prepareNextItem() {
    guard let player = player, preferences?.gaplessPlayback ?? true else { return }

    // Only queue the next item if it's not already queued
    guard player.items().count < 2 else { return }

    let nextIndex = currentQueueIndex + 1
    if nextIndex < queue.count {
      let nextSong = queue[nextIndex]
      let nextItem = createPlayerItem(for: nextSong)
      player.insert(nextItem, after: player.currentItem)
    }
  }

  func jumpToQueueIndex(_ index: Int) {
    guard index >= 0 && index < queue.count else { return }
    currentQueueIndex = index
    play(queue[currentQueueIndex], from: currentSource, playlistId: currentPlaylistId)
  }

  func playQueue(
    _ songs: [LibrarySong], startingAt index: Int = 0, from source: PlaySource = .library,
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

  func playAlbum(_ album: Album, startingAtTrack index: Int = 0) {
    let sortedSongs = album.songs.sorted { ($0.trackNumber ?? 0) < ($1.trackNumber ?? 0) }
    playQueue(sortedSongs, startingAt: index, from: .album)
  }

  func playPlaylist(_ playlist: Playlist, startingAt index: Int = 0) {
    playQueue(playlist.songs, startingAt: index, from: .playlist, playlistId: playlist.id)
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

  func playPause() {
    guard currentItem != nil else { return }
    if isPlaying {
      pause()
    } else {
      play()
    }
  }

  func seek(to time: TimeInterval) {
    guard time.isFinite, time >= 0 else { return }
    let cmTime = CMTime(seconds: time, preferredTimescale: 600)
    player?.seek(to: cmTime, toleranceBefore: .zero, toleranceAfter: .zero) {
      [weak self] finished in
      if finished {
        Task { @MainActor in
          self?.currentTime = time
          self?.updateNowPlaying()
          self?.saveState()
        }
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
        play(queue[currentQueueIndex], from: currentSource, playlistId: currentPlaylistId)
      }
      return
    }

    currentQueueIndex -= 1
    play(queue[currentQueueIndex], from: currentSource, playlistId: currentPlaylistId)
  }

  func playNext() {
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
        play(queue[currentQueueIndex], from: currentSource, playlistId: currentPlaylistId)
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
  }

  private func updateUIForNewItem() {
    guard let song = currentItem else { return }
    duration = song.duration > 0 ? song.duration : 0
    currentTime = 0
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

  func playNext(_ song: LibrarySong) {
    let insertIndex = min(currentQueueIndex + 1, queue.count)
    queue.insert(song, at: insertIndex)
    if shuffleMode != .off {
      originalQueue.append(song)
    }

    // Insert into AVQueuePlayer
    if let player = player {
      let item = createPlayerItem(for: song)
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
        player?.removeAllItems()
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
        play(nextSong, from: currentSource, playlistId: currentPlaylistId)
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
    player?.removeAllItems()
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
    } else if sourceIndex < currentQueueIndex && destinationIndex >= currentQueueIndex {
      currentQueueIndex -= 1
    } else if sourceIndex > currentQueueIndex && destinationIndex <= currentQueueIndex {
      currentQueueIndex += 1
    }

    // Re-sync AVQueuePlayer if necessary (e.g. if next item changed)
    if sourceIndex == currentQueueIndex + 1 || destinationIndex == currentQueueIndex + 1 {
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
        let originalIndex = originalQueue.firstIndex(where: { $0.id == currentSong.id })
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
    currentLyrics = lyricsService.getCachedLyrics(for: song)
    if currentLyrics == nil {
      currentLyrics = await lyricsService.fetchLyrics(for: song)
    }
  }

  private func updateCurrentLyric() {
    guard let lyrics = currentLyrics else {
      currentLyricIndex = nil
      return
    }
    currentLyricIndex = try? lyrics.lineIndex(at: currentTime)
  }

  var currentLyricLine: LyricLine? {
    guard let index = currentLyricIndex,
      let lyrics = currentLyrics,
      index >= 0, index < (try? lyrics.lines.count) ?? 0
    else { return nil }
    return lyrics.lines[index]
  }

  func refreshLyrics() async {
    guard let song = currentItem else { return }
    currentLyrics = await LyricsService.shared.refreshLyrics(for: song)
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
      MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.audio.rawValue,
    ]

    #if os(iOS)
      if let url = PathManager.resolve(song.artworkPath),
        let imageData = try? Data(contentsOf: url),
        let image = UIImage(data: imageData)
      {
        let artwork = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
        nowPlayingInfo[MPMediaItemPropertyArtwork] = artwork
      }
    #endif

    MPNowPlayingInfoCenter.default().nowPlayingInfo = nowPlayingInfo
  }

  // MARK: - Persistence

  private func saveState() {
    guard !isInitializing else { return }
    guard let state = persistentState, let context = modelContext else {
      print("[DEBUG] PlaybackController.saveState: FAILED - state or context nil")
      return
    }

    let songId = currentItem?.id
    print(
      "[DEBUG] PlaybackController.saveState: Saving state. Song: \(songId?.uuidString ?? "nil"), Time: \(currentTime), Queue Count: \(queue.count)"
    )

    state.lastSongId = songId
    state.lastTime = currentTime
    state.lastQueueIds = queue.map { $0.id }
    state.lastQueueIndex = currentQueueIndex
    state.lastSourceRaw = currentSource.rawValue
    state.lastPlaylistId = currentPlaylistId

    do {
      try context.save()
      print("[DEBUG] PlaybackController.saveState: SUCCESS")
    } catch {
      print("[DEBUG] PlaybackController.saveState: ERROR saving context: \(error)")
    }
  }

  private func restoreState() {
    print("[DEBUG] PlaybackController.restoreState: Starting restoration")
    guard let state = persistentState else {
      print("[DEBUG] PlaybackController.restoreState: FAILED - persistentState is nil")
      return
    }

    guard let songId = state.lastSongId else {
      print("[DEBUG] PlaybackController.restoreState: No lastSongId found in state")
      return
    }

    print(
      "[DEBUG] PlaybackController.restoreState: Found lastSongId \(songId). Queue count in state: \(state.lastQueueIds.count)"
    )

    // Fetch the songs for the queue
    let songIds = state.lastQueueIds
    var restoredQueue: [LibrarySong] = []

    for id in songIds {
      if let song = library.songs.first(where: { $0.id == id }) {
        restoredQueue.append(song)
      }
    }

    if !restoredQueue.isEmpty {
      Task { @MainActor in
        print("[DEBUG] PlaybackController.restoreState.MainActor: Setting up UI")
        self.queue = restoredQueue
        self.originalQueue = restoredQueue
        self.currentQueueIndex = state.lastQueueIndex
        self.currentSource = PlaySource(rawValue: state.lastSourceRaw ?? "library") ?? .library
        self.currentPlaylistId = state.lastPlaylistId

        if currentQueueIndex < queue.count {
          let song = queue[currentQueueIndex]
          print("[DEBUG] PlaybackController.restoreState.MainActor: Current song: \(song.title)")
          self.currentItem = song
          self.currentTime = state.lastTime
          self.isPlaying = false

          // Prepare player but don't play
          let item = createPlayerItem(for: song)
          self.player = AVQueuePlayer(items: [item])
          item.seek(
            to: CMTime(seconds: state.lastTime, preferredTimescale: 600), completionHandler: nil)
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
            "[DEBUG] PlaybackController.restoreState.MainActor: FAILED - index \(currentQueueIndex) out of bounds"
          )
        }
      }
    } else {
      print("[DEBUG] PlaybackController.restoreState: FAILED - restored queue is empty")
    }
  }
  // MARK: - Observers

  private func addTimeObserver() {
    if let observer = timeObserver {
      player?.removeTimeObserver(observer)
    }

    let interval = CMTime(seconds: 0.1, preferredTimescale: 600)
    timeObserver = player?.addPeriodicTimeObserver(forInterval: interval, queue: .main) {
      [weak self] time in
      guard let self = self else { return }
      self.currentTime = time.seconds
      self.updateCurrentLyric()

      // Periodically save time (every 5 seconds)
      if Int(self.currentTime) % 5 == 0 {
        self.saveState()
      }
    }
  }
}
