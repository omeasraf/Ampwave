//
//  HapticManager.swift
//  Ampwave
//
//  Centralised haptic feedback for all tappable interactions.
//  iOS-only; all methods are no-ops on macOS.
//

import Foundation

#if canImport(UIKit)
  import UIKit

  @MainActor
  final class HapticManager {
    static let shared = HapticManager()

    // Pre-allocated generators to avoid first-tap latency.
    private let light = UIImpactFeedbackGenerator(style: .light)
    private let medium = UIImpactFeedbackGenerator(style: .medium)
    private let rigid = UIImpactFeedbackGenerator(style: .rigid)
    private let notification = UINotificationFeedbackGenerator()
    private let selection = UISelectionFeedbackGenerator()

    private init() {
      // Pre-warm all generators so the first tap doesn't stutter.
      light.prepare()
      medium.prepare()
      rigid.prepare()
      notification.prepare()
      selection.prepare()
    }

    // MARK: - Playback

    /// Play / Pause toggle — medium thud, matches the weight of the action.
    func playPause() {
      medium.impactOccurred()
      medium.prepare()
    }

    /// Skip forward or backward — rigid click, snappy and directional.
    func skip() {
      rigid.impactOccurred()
      rigid.prepare()
    }

    // MARK: - Library Actions

    /// Like / favourite a song — success notification, rewarding.
    func like() {
      notification.notificationOccurred(.success)
      notification.prepare()
    }

    /// Dislike / unlike a song — light impact, understated.
    func dislike() {
      light.impactOccurred()
      light.prepare()
    }

    /// Generic selection (tab switch, filter pill, etc.)
    func select() {
      selection.selectionChanged()
      selection.prepare()
    }

    /// Radio start — medium impact to signal a new queue starting.
    func radioStart() {
      medium.impactOccurred(intensity: 0.7)
      medium.prepare()
    }

    /// Warning / error — error notification.
    func error() {
      notification.notificationOccurred(.error)
      notification.prepare()
    }
  }

#else

  // macOS stub — keeps call sites clean with no #if guards scattered everywhere.
  @MainActor
  final class HapticManager {
    static let shared = HapticManager()
    private init() {}

    func playPause() {}
    func skip() {}
    func like() {}
    func dislike() {}
    func select() {}
    func radioStart() {}
    func error() {}
  }

#endif
