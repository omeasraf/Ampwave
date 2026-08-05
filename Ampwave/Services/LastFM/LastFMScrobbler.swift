//
//  LastFMScrobbler.swift
//  Ampwave
//
//  Owns the Last.fm session and turns plays into scrobbles.
//
//  Eligibility follows Last.fm's published rules, which every scrobbling client
//  implements the same way:
//    • the track must be longer than 30 seconds
//    • it must have been played for at least half its length, or 4 minutes,
//      whichever comes first
//    • the scrobble timestamp is when the track *started*
//

import Foundation
import Observation
import SwiftData

@MainActor
@Observable
final class LastFMScrobbler {
  static let shared = LastFMScrobbler()

  enum SignInState: Equatable {
    case signedOut
    case awaitingAuthorization
    case signedIn(username: String)
  }

  private(set) var state: SignInState = .signedOut
  private(set) var profile: LastFMProfile?
  private(set) var lastError: String?
  private(set) var pendingCount: Int = 0
  private(set) var isBusy = false

  /// Scrobbling can be switched off without signing out.
  var isScrobblingEnabled: Bool {
    get { UserDefaults.standard.object(forKey: Keys.enabled) as? Bool ?? true }
    set {
      UserDefaults.standard.set(newValue, forKey: Keys.enabled)
      // The property is UserDefaults-backed, so nudge observers explicitly.
      withMutation(keyPath: \.isScrobblingEnabled) {}
    }
  }

  var isConfigured: Bool { LastFMSecrets.isConfigured }

  var isSignedIn: Bool {
    if case .signedIn = state { return true }
    return false
  }

  private enum Keys {
    static let enabled = "lastfm.scrobblingEnabled"
    static let loveSync = "lastfm.syncLovedTracks"
    static let thresholdPercent = "lastfm.scrobbleThresholdPercent"
  }

  var modelContext: ModelContext?
  private let client = LastFMClient.shared
  private var pendingToken: String?
  private var credentials: LastFMCredentialStore.Credentials?
  /// Guards against two flushes racing and double-submitting the queue.
  private var isFlushing = false

  // Threshold tracking for the currently playing track.
  private var trackingSong: LibrarySong?
  private var trackStartedAt: Date?
  /// Start of the current unpaused stretch; nil while paused.
  private var segmentStartedAt: Date?
  private var accumulatedPlayTime: TimeInterval = 0
  private var hasScrobbledCurrentTrack = false
  private var thresholdTask: Task<Void, Never>?

  private init() {
    restoreSession()
  }

  func setModelContext(_ context: ModelContext) {
    self.modelContext = context
    refreshPendingCount()
    Task { await flushQueue() }
  }

  // MARK: - Session

  private func restoreSession() {
    guard let stored = LastFMCredentialStore.load() else { return }
    credentials = stored
    state = .signedIn(username: stored.username)
    Task { await refreshProfile() }
  }

  /// Step 1 of sign-in: fetches a request token and returns the page the user
  /// has to approve it on. Call `completeSignIn()` once they come back.
  func beginSignIn() async -> URL? {
    guard isConfigured else {
      lastError = LastFMError.notConfigured.localizedDescription
      return nil
    }

    isBusy = true
    defer { isBusy = false }
    lastError = nil

    do {
      let token = try await client.requestToken()
      pendingToken = token
      state = .awaitingAuthorization
      return client.authorizationURL(token: token)
    } catch {
      lastError = error.localizedDescription
      return nil
    }
  }

  /// Step 2: exchanges the approved token for a session key.
  func completeSignIn() async {
    guard let token = pendingToken else { return }

    isBusy = true
    defer { isBusy = false }
    lastError = nil

    do {
      let result = try await client.session(token: token)
      let stored = LastFMCredentialStore.Credentials(
        sessionKey: result.key, username: result.username)
      LastFMCredentialStore.save(stored)
      credentials = stored
      pendingToken = nil
      state = .signedIn(username: result.username)
      await refreshProfile()
      await flushQueue()
    } catch let error as LastFMError where error.isPendingAuthorization {
      // The user hasn't finished approving yet — stay in the waiting state so
      // they can hit the button again rather than restarting the whole flow.
      lastError = "Approve Ampwave in the browser, then tap Complete Sign In."
    } catch {
      lastError = error.localizedDescription
    }
  }

  func cancelSignIn() {
    pendingToken = nil
    lastError = nil
    if !isSignedIn { state = .signedOut }
  }

  func signOut() {
    LastFMCredentialStore.clear()
    credentials = nil
    pendingToken = nil
    profile = nil
    lastError = nil
    state = .signedOut
  }

  func refreshProfile() async {
    guard let username = credentials?.username else { return }
    do {
      profile = try await client.profile(username: username)
    } catch {
      // A profile fetch failing shouldn't look like a broken session.
      print("[DEBUG] LastFMScrobbler: profile refresh failed: \(error)")
    }
  }

  // MARK: - Playback hooks

  /// Tells Last.fm what's playing right now, and starts tracking the play so
  /// it can be scrobbled as soon as it qualifies.
  func nowPlaying(_ song: LibrarySong) {
    beginTracking(song)

    guard shouldScrobble, let sessionKey = credentials?.sessionKey else { return }
    let item = Self.item(for: song, timestamp: Int(Date().timeIntervalSince1970))

    Task {
      do {
        try await client.updateNowPlaying(item, sessionKey: sessionKey)
      } catch {
        print("[DEBUG] LastFMScrobbler: now playing failed: \(error)")
      }
    }
  }

  /// Queues a finished play if it meets Last.fm's thresholds.
  ///
  /// Acts as a safety net — most plays are already submitted mid-track by the
  /// threshold timer, and `hasScrobbledCurrentTrack` stops this double-sending.
  ///
  /// - Parameters:
  ///   - playedDuration: seconds actually listened to, excluding pauses.
  ///   - startedAt: when playback of this track began.
  func recordPlay(_ song: LibrarySong, playedDuration: TimeInterval, startedAt: Date) {
    defer { endTracking() }
    guard !hasScrobbledCurrentTrack || trackingSong?.id != song.id else { return }
    submitScrobble(song, playedDuration: playedDuration, startedAt: startedAt)
  }

  /// Called when playback pauses, so paused time isn't counted toward the
  /// scrobble threshold.
  func playbackPaused() {
    accumulatePlayTime()
    thresholdTask?.cancel()
    thresholdTask = nil
  }

  /// Called when playback resumes.
  func playbackResumed() {
    guard trackingSong != nil else { return }
    segmentStartedAt = Date()
    scheduleThresholdScrobble()
  }

  private func submitScrobble(_ song: LibrarySong, playedDuration: TimeInterval, startedAt: Date) {
    guard shouldScrobble else { return }

    let duration = effectiveDuration(for: song)
    guard
      Self.isEligible(
        duration: duration, played: playedDuration, percent: scrobbleThresholdPercent)
    else {
      print(
        "[DEBUG] LastFMScrobbler: '\(song.title)' not eligible "
          + "(played \(Int(playedDuration))s of \(Int(duration))s)")
      return
    }

    print("[DEBUG] LastFMScrobbler: queueing scrobble for '\(song.title)'")
    enqueue(Self.item(for: song, timestamp: Int(startedAt.timeIntervalSince1970)))
    Task { await flushQueue() }
  }

  /// Track length to judge eligibility against.
  ///
  /// Stored tag durations are wrong often enough (FLAC especially) that
  /// trusting them alone silently blocks scrobbles, so the live player's
  /// duration wins whenever this is the track currently playing.
  private func effectiveDuration(for song: LibrarySong) -> TimeInterval {
    let playback = PlaybackController.shared
    if playback.currentItem?.id == song.id, playback.duration > 0 {
      return playback.duration
    }
    return song.duration
  }

  // MARK: - Threshold tracking

  private func beginTracking(_ song: LibrarySong) {
    thresholdTask?.cancel()
    trackingSong = song
    trackStartedAt = Date()
    segmentStartedAt = Date()
    accumulatedPlayTime = 0
    hasScrobbledCurrentTrack = false
    scheduleThresholdScrobble()
  }

  private func endTracking() {
    thresholdTask?.cancel()
    thresholdTask = nil
    trackingSong = nil
    trackStartedAt = nil
    segmentStartedAt = nil
    accumulatedPlayTime = 0
    hasScrobbledCurrentTrack = false
  }

  /// Re-arms the threshold timer against a changed percentage, so adjusting
  /// the setting applies to the track already playing rather than the next one.
  private func rescheduleThresholdForCurrentTrack() {
    guard trackingSong != nil, !hasScrobbledCurrentTrack else { return }
    // Bank the time played so far before recomputing what's left to wait.
    accumulatePlayTime()
    segmentStartedAt = Date()
    scheduleThresholdScrobble()
  }

  private func accumulatePlayTime() {
    guard let segmentStartedAt else { return }
    accumulatedPlayTime += Date().timeIntervalSince(segmentStartedAt)
    self.segmentStartedAt = nil
  }

  /// Waits out however much listening time is still needed, then scrobbles
  /// without waiting for the track to finish. Submitting at the threshold
  /// rather than at track end is what every Last.fm client does — it also
  /// means a play survives the app being killed mid-track.
  private func scheduleThresholdScrobble() {
    guard let song = trackingSong, !hasScrobbledCurrentTrack else { return }
    let duration = effectiveDuration(for: song)
    guard duration > 30 else { return }

    let target = Self.threshold(duration: duration, percent: scrobbleThresholdPercent)
    let alreadyPlayed = accumulatedPlayTime
    let remaining = max(target - alreadyPlayed, 0)

    thresholdTask?.cancel()
    thresholdTask = Task { [weak self] in
      try? await Task.sleep(for: .seconds(remaining))
      guard !Task.isCancelled else { return }
      await MainActor.run {
        guard let self,
          let song = self.trackingSong,
          let startedAt = self.trackStartedAt,
          !self.hasScrobbledCurrentTrack
        else { return }

        self.accumulatePlayTime()
        self.segmentStartedAt = Date()
        self.hasScrobbledCurrentTrack = true
        self.submitScrobble(
          song, playedDuration: self.accumulatedPlayTime, startedAt: startedAt)
      }
    }
  }

  private var shouldScrobble: Bool {
    isConfigured && isSignedIn && isScrobblingEnabled
  }

  /// Mirrors a favourite to Last.fm's loved tracks.
  ///
  /// Separate from the scrobble toggle: someone may want their plays private
  /// but still keep loved tracks in sync, so this has its own preference.
  func setLoved(_ loved: Bool, song: LibrarySong) {
    guard isConfigured, isSignedIn, syncLovedTracks,
      let sessionKey = credentials?.sessionKey
    else { return }

    let artist = song.artist
    let title = song.title

    Task {
      do {
        try await client.setLoved(loved, artist: artist, track: title, sessionKey: sessionKey)
        print("[DEBUG] LastFMScrobbler: \(loved ? "loved" : "unloved") '\(title)'")
      } catch {
        // Not queued for retry — a love is idempotent and low-stakes, and the
        // user can simply toggle it again.
        print("[DEBUG] LastFMScrobbler: love failed: \(error)")
      }
    }
  }

  /// Whether favouriting a song also loves it on Last.fm.
  var syncLovedTracks: Bool {
    get { UserDefaults.standard.object(forKey: Keys.loveSync) as? Bool ?? true }
    set {
      UserDefaults.standard.set(newValue, forKey: Keys.loveSync)
      withMutation(keyPath: \.syncLovedTracks) {}
    }
  }

  /// How much of a track must be played before it scrobbles, as a percentage.
  ///
  /// Last.fm's own rule is 50%, which stays the default. The four-minute cap
  /// still applies on top — that's the "or 4 minutes, whichever comes first"
  /// half of the rule, and without it a long track at a high percentage would
  /// never scrobble.
  var scrobbleThresholdPercent: Int {
    get {
      let stored = UserDefaults.standard.object(forKey: Keys.thresholdPercent) as? Int
      return min(max(stored ?? Self.defaultThresholdPercent, 1), 100)
    }
    set {
      UserDefaults.standard.set(min(max(newValue, 1), 100), forKey: Keys.thresholdPercent)
      withMutation(keyPath: \.scrobbleThresholdPercent) {}
      // A shorter threshold may already be satisfied by the track in progress.
      rescheduleThresholdForCurrentTrack()
    }
  }

  static let defaultThresholdPercent = 50

  /// Last.fm's rules: longer than 30s, and played for at least `percent` of
  /// its length or 4 minutes — whichever is reached first.
  static func isEligible(
    duration: TimeInterval,
    played: TimeInterval,
    percent: Int = defaultThresholdPercent
  ) -> Bool {
    // Duration can be missing when tag extraction failed. Treating that as
    // "too short" silently blocked those tracks from ever scrobbling, so fall
    // back to judging on listened time alone.
    guard duration > 0 else { return played >= 30 }
    guard duration > 30 else { return false }
    return played >= threshold(duration: duration, percent: percent)
  }

  /// Seconds of listening required before a track qualifies.
  static func threshold(duration: TimeInterval, percent: Int) -> TimeInterval {
    let fraction = Double(min(max(percent, 1), 100)) / 100
    return min(duration * fraction, 4 * 60)
  }

  private static func item(for song: LibrarySong, timestamp: Int) -> LastFMScrobbleItem {
    LastFMScrobbleItem(
      // Track artist, not album artist — Last.fm matches on the performing
      // artist and takes album artist as a separate field.
      artist: song.artist,
      track: song.title,
      album: song.album,
      albumArtist: song.albumArtist,
      duration: song.duration > 0 ? Int(song.duration) : nil,
      trackNumber: song.trackNumber,
      timestamp: timestamp
    )
  }

  // MARK: - Queue

  private func enqueue(_ item: LastFMScrobbleItem) {
    guard let modelContext else { return }
    let pending = PendingScrobble(
      artist: item.artist,
      track: item.track,
      album: item.album,
      albumArtist: item.albumArtist,
      durationSeconds: item.duration,
      trackNumber: item.trackNumber,
      timestamp: item.timestamp
    )
    modelContext.insert(pending)
    try? modelContext.save()
    refreshPendingCount()
  }

  /// Sends everything queued, oldest first, and clears what Last.fm accepts.
  func flushQueue() async {
    guard shouldScrobble, let sessionKey = credentials?.sessionKey else { return }
    guard let modelContext else { return }
    guard !isFlushing else { return }

    isFlushing = true
    defer { isFlushing = false }

    // Give up on individual scrobbles Last.fm keeps rejecting so one bad
    // entry can't wedge the queue forever.
    let maxFailures = 5
    var descriptor = FetchDescriptor<PendingScrobble>(
      sortBy: [SortDescriptor(\.timestamp, order: .forward)]
    )
    descriptor.fetchLimit = 50

    guard let queued = try? modelContext.fetch(descriptor), !queued.isEmpty else {
      refreshPendingCount()
      return
    }

    let sendable = queued.filter { $0.failureCount < maxFailures }
    guard !sendable.isEmpty else {
      for expired in queued { modelContext.delete(expired) }
      try? modelContext.save()
      refreshPendingCount()
      return
    }

    let items = sendable.map {
      LastFMScrobbleItem(
        artist: $0.artist,
        track: $0.track,
        album: $0.album,
        albumArtist: $0.albumArtist,
        duration: $0.durationSeconds,
        trackNumber: $0.trackNumber,
        timestamp: $0.timestamp
      )
    }

    do {
      _ = try await client.scrobble(items, sessionKey: sessionKey)
      for sent in sendable { modelContext.delete(sent) }
      try? modelContext.save()
      lastError = nil
    } catch {
      for failed in sendable { failed.failureCount += 1 }
      try? modelContext.save()
      print("[DEBUG] LastFMScrobbler: flush failed: \(error)")
    }

    refreshPendingCount()
  }

  private func refreshPendingCount() {
    guard let modelContext else {
      pendingCount = 0
      return
    }
    let descriptor = FetchDescriptor<PendingScrobble>()
    pendingCount = (try? modelContext.fetchCount(descriptor)) ?? 0
  }
}
