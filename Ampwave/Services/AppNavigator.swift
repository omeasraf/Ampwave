//
//  AppNavigator.swift
//  Ampwave
//
//  Routes navigation that has to escape the full-screen player.
//
//  The player is presented as a `fullScreenCover` with its own NavigationStack,
//  so pushing from inside it covers the player *and* the mini player, leaving
//  no way back to playback. Anything that should behave like normal library
//  browsing has to collapse the player first and then push onto the tab's own
//  stack — that's what this coordinates.
//

import Foundation
import Observation

internal import SwiftUI

@MainActor
@Observable
final class AppNavigator {
  static let shared = AppNavigator()

  /// Destinations reachable from the player.
  enum Destination: Hashable {
    case artist(Artist)
    case album(Album)
  }

  /// Navigation stack for the Library tab, driven by `OpenTabView`.
  var libraryPath = NavigationPath()

  /// Set when the player needs to collapse before navigating; `OpenPlayerView`
  /// watches it and dismisses itself.
  private(set) var shouldCollapsePlayer = false

  /// Queued while the player is still on screen — pushing during the dismiss
  /// transition drops the navigation.
  private var pendingDestination: Destination?

  private init() {}

  /// Collapses the player (if open) and shows `destination` in the Library tab.
  func show(_ destination: Destination, collapsingPlayer: Bool) {
    guard collapsingPlayer else {
      libraryPath.append(destination)
      return
    }

    pendingDestination = destination
    shouldCollapsePlayer = true
  }

  /// Called by the player once it has actually dismissed.
  func playerDidCollapse() {
    shouldCollapsePlayer = false
    guard let destination = pendingDestination else { return }
    pendingDestination = nil
    libraryPath.append(destination)
  }

  /// Clears navigation state, e.g. after a library reset.
  func reset() {
    libraryPath = NavigationPath()
    pendingDestination = nil
    shouldCollapsePlayer = false
  }
}
