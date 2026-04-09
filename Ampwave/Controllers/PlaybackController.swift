//
//  PlaybackController.swift
//  Ampwave
//
//  Enhanced playback controller with queue, shuffle, repeat, and lyrics support.
//  Fixed playback reliability and state management.
//

import AVFoundation
import Combine
import Foundation
import MediaPlayer
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

  private var player: AVPlayer?
  private var timeObserver: Any?
  private var endObserver: NSObjectProtocol?
  private var itemObserver: NSKeyValueObservation?
  private let library = SongLibrary.shared
  private let historyTracker = ListeningHistoryTracker.shared
  private var audioSessionConfigured = false

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
    }
  }

  var repeatMode: RepeatMode = .off

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

  private func setupAudioSession() {
    #if os(iOS)
      guard !audioSessionConfigured else { return }
      let session = AVAudioSession.sharedInstance()
      do {
        try session.setCategory(.playback, mode: .default)
        try session.setActive(true)
        audioSessionConfigured = true
      } catch {
        print("Audio session warning: \(error)")
      }
    #endif
  }

  private func setupNotifications() {
    // Handle audio session interruptions
    NotificationCenter.default.addObserver(
      self,
      selector: #selector(handleAudioSessionInterruption),
      name: AVAudioSession.interruptionNotification,
      object: nil
    )

    // Handle route changes (headphones connected/disconnected)
    NotificationCenter.default.addObserver(
      self,
      selector: #selector(handleRouteChange),
      name: AVAudioSession.routeChangeNotification,
      object: nil
    )
  }

  @objc private func handleAudioSessionInterruption(_ notification: Notification) {
    guard let userInfo = notification.userInfo,
      let typeValue = userInfo[AVAudioSessionInterruptionTypeKey] as? UInt,
      let type = AVAudioSession.InterruptionType(rawValue: typeValue)
    else {
      return
    }

    switch type {
    case .began:
      // Audio session was interrupted (e.g., phone call)
      pause()
    case .ended:
      // Interruption ended
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
    else {
      return
    }

    switch reason {
    case .oldDeviceUnavailable:
      // Headphones unplugged - pause playback
      pause()
    default:
      break
    }
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
      else {
        return .commandFailed
      }
      self.seek(to: positionEvent.positionTime)
      return .success
    }

    commandCenter.likeCommand.addTarget { [weak self] _ in
      guard let self = self, let song = self.currentItem else { return .commandFailed }
      PlaylistManager.shared.toggleLike(song: song)
      return .success
    }
  }

  // MARK: - Playback Controls

  func play(_ song: LibrarySong, from source: PlaySource = .library, playlistId: UUID? = nil) {
    // Track previous song in history
    if let current = currentItem {
      historyTracker.songEnded(skipped: false)
    }

    isLoading = true
    currentSource = source
    currentPlaylistId = playlistId

    // Configure audio session for playback
    setupAudioSession()

    // Get the file URL
    let url = library.getFileURL(for: song)

    // Verify file exists
    guard FileManager.default.fileExists(atPath: url.path) else {
      print("Audio file not found: \(url.path)")
      isLoading = false
      return
    }

    // Create player item
    let item = AVPlayerItem(url: url)

    // Configure player
    if player == nil {
      player = AVPlayer(playerItem: item)
      addTimeObserver()
    } else {
      player?.replaceCurrentItem(with: item)
    }

    // Observe item status for reliable playback
    observePlayerItem(item)

    // Re-register end of playback observer for the new item
    addEndOfPlaybackObserver()

    // Update state
    currentItem = song
    duration = song.duration > 0 ? song.duration : 0
    currentTime = 0

    // Start playback
    player?.play()
    isPlaying = true
    isLoading = false

    // Load duration from the player item to ensure accuracy
    loadDuration(from: item)

    updateNowPlaying()
    historyTracker.songStarted(song, source: source, playlistId: playlistId)

    // Load lyrics
    Task {
      await loadLyrics(for: song)
    }
  }

  private func observePlayerItem(_ item: AVPlayerItem) {
    // Remove previous observer
    itemObserver?.invalidate()

    // Observe status changes for reliable playback
    itemObserver = item.observe(\.status, options: [.new]) { [weak self] item, _ in
      Task { @MainActor in
        switch item.status {
        case .readyToPlay:
          self?.isLoading = false
          self?.player?.play()
          self?.isPlaying = true
          
          // Ensure we have the most accurate duration from the player item
          let itemDuration = CMTimeGetSeconds(item.duration)
          if itemDuration.isFinite, itemDuration > 0 {
            self?.duration = itemDuration
            self?.updateNowPlaying()
          }
        case .failed:
          self?.isLoading = false
          self?.isPlaying = false
          print("Player item failed: \(item.error?.localizedDescription ?? "Unknown error")")
        case .unknown:
          break
        @unknown default:
          break
        }
      }
    }
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
    guard player != nil else {
      // If no player but we have a current item, recreate the player
      if let song = currentItem {
        play(song, from: currentSource, playlistId: currentPlaylistId)
      }
      return
    }

    player?.play()
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
        }
      }
    }
  }

  func skipForward() {
    let newTime = min(currentTime + 15, duration)
    seek(to: newTime)
  }

  func skipBackward() {
    let newTime = max(0, currentTime - 15)
    seek(to: newTime)
  }

  // MARK: - Queue Navigation

  func playPrevious() {
    if currentTime > 3 {
      seek(to: 0)
      return
    }

    guard currentQueueIndex > 0 else {
      if repeatMode == .all {
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

    switch repeatMode {
    case .one:
      seek(to: 0)
      play()
      return

    case .off, .all:
      guard currentQueueIndex < queue.count - 1 else {
        if repeatMode == .all {
          currentQueueIndex = 0
          play(queue[currentQueueIndex], from: currentSource, playlistId: currentPlaylistId)
        } else {
          pause()
          seek(to: 0)
        }
        return
      }

      currentQueueIndex += 1
      play(queue[currentQueueIndex], from: currentSource, playlistId: currentPlaylistId)
    }
  }

  // MARK: - Queue Management

  func addToQueue(_ song: LibrarySong) {
    queue.append(song)
    if shuffleMode != .off {
      originalQueue.append(song)
    }
  }

  func addToQueue(_ songs: [LibrarySong]) {
    queue.append(contentsOf: songs)
    if shuffleMode != .off {
      originalQueue.append(contentsOf: songs)
    }
  }

  func playNext(_ song: LibrarySong) {
    let insertIndex = min(currentQueueIndex + 1, queue.count)
    queue.insert(song, at: insertIndex)
    if shuffleMode != .off {
      originalQueue.append(song)
    }
  }

  func removeFromQueue(at index: Int) {
    guard index >= 0 && index < queue.count else { return }

    queue.remove(at: index)

    if shuffleMode != .off {
      if let originalIndex = originalQueue.firstIndex(where: { $0.id == queue[index].id }) {
        originalQueue.remove(at: originalIndex)
      }
    }

    if index < currentQueueIndex {
      currentQueueIndex -= 1
    }
  }

  func clearQueue() {
    queue.removeAll()
    originalQueue.removeAll()
    currentQueueIndex = 0
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
  }

  func toggleShuffle() {
    shuffleMode = shuffleMode == .off ? .on : .off
  }

  // MARK: - Repeat

  func cycleRepeatMode() {
    switch repeatMode {
    case .off:
      repeatMode = .all
    case .all:
      repeatMode = .one
    case .one:
      repeatMode = .off
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
    guard let song = currentItem, 
          let lyrics = currentLyrics, 
          lyrics.songId == song.id else {
      currentLyricIndex = nil
      return
    }

    // Defensive check for potential detachment/deallocation
    do {
      currentLyricIndex = lyrics.lineIndex(at: currentTime)
    } catch {
      print("Warning: Failed to update lyric index (likely detached context)")
      currentLyricIndex = nil
    }
  }

  var currentLyricLine: LyricLine? {
    guard let song = currentItem,
          let index = currentLyricIndex,
          let lyrics = currentLyrics,
          lyrics.songId == song.id,
          index >= 0
    else { return nil }
    
    // Safely check lines count
    let linesCount = (try? lyrics.lines.count) ?? 0
    if index < linesCount {
      return lyrics.lines[index]
    }
    return nil
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

    if let trackNumber = song.trackNumber {
      nowPlayingInfo[MPMediaItemPropertyAlbumTrackNumber] = trackNumber
    }

    nowPlayingInfo[MPMediaItemPropertyAlbumTrackCount] = queue.count

    MPNowPlayingInfoCenter.default().nowPlayingInfo = nowPlayingInfo
  }

  // MARK: - Observers

  private func addTimeObserver() {
    if let observer = timeObserver {
      player?.removeTimeObserver(observer)
    }

    let interval = CMTime(seconds: 0.1, preferredTimescale: 600)
    timeObserver = player?.addPeriodicTimeObserver(forInterval: interval, queue: .main) {
      [weak self] time in
      self?.currentTime = time.seconds
      self?.updateCurrentLyric()
    }

    // Add end of playback observer
    addEndOfPlaybackObserver()
  }

  private func loadDuration(from item: AVPlayerItem) {
    Task { @MainActor in
      do {
        let loadedDuration = try await item.asset.load(.duration)
        let seconds = CMTimeGetSeconds(loadedDuration)
        if seconds.isFinite, seconds > 0 {
          self.duration = seconds
          self.updateNowPlaying()
        }
      } catch {
        print("Failed to load duration: \(error)")
      }
    }
  }

  private func addEndOfPlaybackObserver() {
    // Remove previous observer
    if let observer = endObserver {
      NotificationCenter.default.removeObserver(observer)
    }

    endObserver = NotificationCenter.default.addObserver(
      forName: .AVPlayerItemDidPlayToEndTime,
      object: player?.currentItem,
      queue: .main
    ) { [weak self] _ in
      Task { @MainActor in
        self?.playNext()
      }
    }
  }
}

// MARK: - Supporting Types
