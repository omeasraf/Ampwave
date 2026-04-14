//
//  WidgetSyncService.swift
//  Ampwave
//

import Foundation
import WidgetKit

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
    isPlaying: Bool,
    currentTime: TimeInterval,
    duration: TimeInterval,
    lyrics: SyncedLyric? = nil
  ) {
    let info = SharedPlaybackInfo(
      songId: song?.id,
      title: song?.title ?? "Not Playing",
      artist: song?.artist ?? "No Artist",
      album: song?.album,
      artworkPath: song?.artworkPath,
      isPlaying: isPlaying,
      currentTime: currentTime,
      duration: duration,
      lastUpdated: Date(),
      lyrics: lyrics?.lines
    )

    save(info)
    WidgetCenter.shared.reloadAllTimelines()
  }

  private func save(_ info: SharedPlaybackInfo) {
    guard let container = sharedContainer else { return }
    let url = container.appendingPathComponent(fileName)

    do {
      let data = try JSONEncoder().encode(info)
      try data.write(to: url)
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
