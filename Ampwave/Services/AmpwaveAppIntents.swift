//
//  AmpwaveAppIntents.swift
//  Ampwave
//

import AppIntents
import Foundation

#if canImport(UIKit)
  import UIKit
#endif
#if os(macOS)
  import AppKit
#endif

@available(iOS 17.0, macOS 14.0, *)
enum AmpwaveShortcutURLs {
  static let scheme = "ampwave"
  static func open(_ path: String) -> URL {
    URL(string: "\(scheme)://\(path)")!
  }

  static func openInApp(_ path: String) {
    let url = open(path)
    #if os(iOS)
      UIApplication.shared.open(url, options: [:], completionHandler: nil)
    #elseif os(macOS)
      NSWorkspace.shared.open(url)
    #endif
  }
}

@available(iOS 17.0, macOS 14.0, *)
struct PlayLikedSongsIntent: AppIntent {
  static var title: LocalizedStringResource = "Play Liked Songs"
  static var description = IntentDescription(
    "Starts playback of your Liked Songs playlist in Ampwave.")
  static var openAppWhenRun: Bool = true

  func perform() async throws -> some IntentResult {
    await MainActor.run {
      AmpwaveShortcutURLs.openInApp("play/liked")
    }
    return .result()
  }
}

@available(iOS 17.0, macOS 14.0, *)
struct ResumePlaybackIntent: AppIntent {
  static var title: LocalizedStringResource = "Resume Ampwave"
  static var description = IntentDescription(
    "Opens Ampwave and resumes the last queue if possible.")
  static var openAppWhenRun: Bool = true

  func perform() async throws -> some IntentResult {
    await MainActor.run {
      AmpwaveShortcutURLs.openInApp("resume")
    }
    return .result()
  }
}

@available(iOS 17.0, macOS 14.0, *)
struct AmpwaveShortcuts: AppShortcutsProvider {
  @AppShortcutsBuilder
  static var appShortcuts: [AppShortcut] {
    AppShortcut(
      intent: PlayLikedSongsIntent(),
      phrases: [
        "Play liked songs in \(.applicationName)",
        "Start liked songs in \(.applicationName)",
      ],
      shortTitle: "Play Liked",
      systemImageName: "heart.fill"
    )
    AppShortcut(
      intent: ResumePlaybackIntent(),
      phrases: [
        "Resume music in \(.applicationName)",
        "Continue in \(.applicationName)",
      ],
      shortTitle: "Resume",
      systemImageName: "play.fill"
    )
  }
}
