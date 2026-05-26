//
//  SleepTimerService.swift
//  Ampwave
//
//  Manages sleep timer state for timed playback stops.
//

import Foundation
import Observation

@MainActor
@Observable
final class SleepTimerService {
  static let shared = SleepTimerService()

  enum Mode: Equatable {
    case off
    case countdown(until: Date)
    case endOfSong
    case endOfQueue
  }

  private(set) var mode: Mode = .off
  private(set) var remainingText: String?

  private var countdownTimer: Timer?

  private init() {}

  var isActive: Bool {
    mode != .off
  }

  var statusText: String {
    switch mode {
    case .off:
      return "Sleep timer off"
    case .countdown:
      return remainingText.map { "Sleep in \($0)" } ?? "Sleep timer active"
    case .endOfSong:
      return "Stops after this song"
    case .endOfQueue:
      return "Stops after this queue"
    }
  }

  func startCountdown(minutes: Int) {
    guard minutes > 0 else { return }

    let endDate = Date().addingTimeInterval(TimeInterval(minutes * 60))
    mode = .countdown(until: endDate)
    startTicker(until: endDate)
  }

  func startEndOfSong() {
    cancelTicker()
    remainingText = nil
    mode = .endOfSong
  }

  func startEndOfQueue() {
    cancelTicker()
    remainingText = nil
    mode = .endOfQueue
  }

  func cancel() {
    cancelTicker()
    remainingText = nil
    mode = .off
  }

  func handleTrackFinished(isEndOfQueue: Bool) -> Bool {
    switch mode {
    case .endOfSong:
      cancel()
      return true
    case .endOfQueue where isEndOfQueue:
      cancel()
      return true
    default:
      return false
    }
  }

  private func startTicker(until endDate: Date) {
    cancelTicker()
    updateRemaining(until: endDate)

    countdownTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) {
      [weak self] _ in
      Task { @MainActor in
        self?.updateRemaining(until: endDate)
      }
    }
  }

  private func updateRemaining(until endDate: Date) {
    let interval = max(0, endDate.timeIntervalSinceNow)

    guard interval > 0 else {
      cancel()
      PlaybackController.shared.stopForSleepTimer()
      return
    }

    let totalSeconds = Int(interval.rounded(.up))
    let hours = totalSeconds / 3600
    let minutes = (totalSeconds % 3600) / 60
    let seconds = totalSeconds % 60

    if hours > 0 {
      remainingText = String(format: "%d:%02d:%02d", hours, minutes, seconds)
    } else {
      remainingText = String(format: "%d:%02d", minutes, seconds)
    }
  }

  private func cancelTicker() {
    countdownTimer?.invalidate()
    countdownTimer = nil
  }
}
