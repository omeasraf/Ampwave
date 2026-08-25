//
//  WidgetSyncService.swift
//  Ampwave
//

import Foundation
import WidgetKit

#if canImport(UIKit)
  import UIKit
#endif

@MainActor
public class WidgetSyncService {
  public static let shared = WidgetSyncService()
  private let appGroup = "group.com.ome.ampwave"
  private let fileName = "playback.json"

  private init() {}

  private var sharedContainer: URL? {
    FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup)
  }

  func updatePlaybackStatus(
    song: LibrarySong?,
    upcomingSongs: [LibrarySong] = [],
    isPlaying: Bool,
    currentTime: TimeInterval,
    duration: TimeInterval,
    lyrics: SyncedLyric? = nil
  ) {
    // Sync playback status directly to shared container
    self.performSync(
      song: song,
      upcomingSongs: upcomingSongs,
      isPlaying: isPlaying,
      currentTime: currentTime,
      duration: duration,
      lyrics: lyrics
    )
  }

  /// Updates only the widget palette, preserving the current song, artwork,
  /// playback position, and lyrics. Theme changes should not have to wait for
  /// the next playback event before appearing on the Home Screen.
  func refreshTheme() {
    var info = getPlaybackStatus() ?? SharedPlaybackInfo()
    applyCurrentTheme(to: &info)
    save(info)
    WidgetCenter.shared.reloadAllTimelines()
  }

  private static let widgetArtFileName = "widget_now_playing_art.jpg"

  private func performSync(
    song: LibrarySong?,
    upcomingSongs: [LibrarySong],
    isPlaying: Bool,
    currentTime: TimeInterval,
    duration: TimeInterval,
    lyrics: SyncedLyric? = nil
  ) {
    var artName: String?
    var widgetArtworkData: Data?
    if let song = song, let rel = song.effectiveArtworkPath, let src = PathManager.resolve(rel),
      let container = sharedContainer
    {
      let dest = container.appendingPathComponent(Self.widgetArtFileName)
      // Replace artwork atomically as well. Removing it before copying left a
      // window where the newly-reloaded now-playing widget had no background.
      if let data = try? Data(contentsOf: src) {
        widgetArtworkData = Self.widgetSizedArtwork(from: data)
        let dataToWrite = widgetArtworkData ?? data
        if (try? dataToWrite.write(to: dest, options: .atomic)) != nil {
          try? FileManager.default.setAttributes(
            [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
            ofItemAtPath: dest.path
          )
          artName = Self.widgetArtFileName
        }
      } else if FileManager.default.fileExists(atPath: dest.path) {
        artName = Self.widgetArtFileName
        widgetArtworkData = (try? Data(contentsOf: dest)).flatMap {
          Self.widgetSizedArtwork(from: $0)
        }
      }
    } else if let container = sharedContainer {
      let dest = container.appendingPathComponent(Self.widgetArtFileName)
      try? FileManager.default.removeItem(at: dest)
    }

    let upcomingArtworkData = upcomingSongs.prefix(3).compactMap { upcomingSong -> Data? in
      guard let relativePath = upcomingSong.effectiveArtworkPath,
        let artworkURL = PathManager.resolve(relativePath),
        let data = try? Data(contentsOf: artworkURL)
      else { return nil }
      return Self.widgetSizedArtwork(
        from: data,
        maximumDimension: 220,
        compressionQuality: 0.72
      )
    }

    // Widgets always use line-synced display (no word-by-word karaoke).
    // Derive clean plain text from wordOffsets so cached lines with squished
    // text are corrected, and strip the wordOffsets themselves to keep the
    // shared payload small.
    let widgetLines = lyrics?.lines.map { line -> LyricLine in
      let text: String
      if let offsets = line.wordOffsets, !offsets.isEmpty {
        text = LRCParser.mergeSyllables(offsets).map(\.text).joined(separator: " ")
      } else {
        text = line.text
      }
      return LyricLine(
        timestamp: line.timestamp,
        text: text,
        translation: line.translation,
        wordOffsets: nil
      )
    }

    var info = SharedPlaybackInfo(
      songId: song?.id,
      title: song?.title ?? "Not Playing",
      artist: song?.artist ?? "No Artist",
      album: song?.album,
      artworkRelativePath: artName,
      artworkData: widgetArtworkData,
      upcomingArtworkData: upcomingArtworkData,
      isPlaying: isPlaying,
      currentTime: currentTime,
      duration: duration,
      lastUpdated: Date(),
      lyrics: widgetLines
    )
    applyCurrentTheme(to: &info)

    save(info)
    WidgetCenter.shared.reloadAllTimelines()
  }

  private func applyCurrentTheme(to info: inout SharedPlaybackInfo) {
    let theme = ThemeManager.shared.themeConfig
    info.themeBackgroundHex = theme.background.toHexString()
    info.themeAccentHex = theme.accent.toHexString()
    info.themePrimaryTextHex = theme.primaryText.toHexString()
    info.themeSecondaryTextHex = theme.secondaryText.toHexString()
    info.themeIsDark = theme.isDark
  }

  private static func widgetSizedArtwork(
    from data: Data,
    maximumDimension: CGFloat = 720,
    compressionQuality: CGFloat = 0.82
  ) -> Data? {
    #if canImport(UIKit)
      guard let image = UIImage(data: data) else { return nil }
      let largestSide = max(image.size.width, image.size.height)
      let scale = largestSide > maximumDimension ? maximumDimension / largestSide : 1
      let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)

      let format = UIGraphicsImageRendererFormat()
      format.scale = 1
      format.opaque = true
      let rendered = UIGraphicsImageRenderer(size: size, format: format).image { _ in
        image.draw(in: CGRect(origin: .zero, size: size))
      }
      return rendered.jpegData(compressionQuality: compressionQuality)
    #else
      // The iOS widget is the primary consumer. Keep already-reasonable files
      // available to other supported platforms without embedding huge images.
      return data.count <= 1_500_000 ? data : nil
    #endif
  }

  private func save(_ info: SharedPlaybackInfo) {
    guard let container = sharedContainer else { return }
    let url = container.appendingPathComponent(fileName)

    do {
      let data = try JSONEncoder().encode(info)
      // WidgetKit may read immediately after reloadTimelines. Atomic replace
      // prevents either widget from observing a partially-written JSON file.
      try data.write(to: url, options: .atomic)
    } catch {
      print("Failed to save shared playback info: \(error)")
    }
  }

  func getPlaybackStatus() -> SharedPlaybackInfo? {
    guard let container = sharedContainer else { return nil }
    let url = container.appendingPathComponent(fileName)

    guard FileManager.default.fileExists(atPath: url.path) else { return nil }

    do {
      let data = try Data(contentsOf: url)
      return try JSONDecoder().decode(SharedPlaybackInfo.self, from: data)
    } catch {
      print("Failed to load shared playback info: \(error)")
      return nil
    }
  }
}
