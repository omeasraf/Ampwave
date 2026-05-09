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
    // Check if any widgets are active before syncing
    WidgetCenter.shared.getCurrentConfigurations { result in
      switch result {
      case .success(let info):
        if !info.isEmpty {
          self.performSync(
            song: song,
            isPlaying: isPlaying,
            currentTime: currentTime,
            duration: duration,
            lyrics: lyrics
          )
        }
      case .failure:
        break
      }
    }
  }

  private static let widgetArtFileName = "widget_now_playing_art.jpg"

  private func performSync(
    song: LibrarySong?,
    isPlaying: Bool,
    currentTime: TimeInterval,
    duration: TimeInterval,
    lyrics: SyncedLyric? = nil
  ) {
    var artName: String?
    if let song = song, let rel = song.effectiveArtworkPath, let src = PathManager.resolve(rel),
      let container = sharedContainer
    {
      let dest = container.appendingPathComponent(Self.widgetArtFileName)
      try? FileManager.default.removeItem(at: dest)
      try? FileManager.default.copyItem(at: src, to: dest)
      artName = Self.widgetArtFileName
    } else if let container = sharedContainer {
      let dest = container.appendingPathComponent(Self.widgetArtFileName)
      try? FileManager.default.removeItem(at: dest)
    }

    let info = SharedPlaybackInfo(
      songId: song?.id,
      title: song?.title ?? "Not Playing",
      artist: song?.artist ?? "No Artist",
      album: song?.album,
      artworkRelativePath: artName,
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
