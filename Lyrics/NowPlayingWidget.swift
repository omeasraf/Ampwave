//
//  NowPlayingWidget.swift
//  Lyrics
//

internal import SwiftUI
import WidgetKit

#if os(macOS)
  import AppKit
#else
  import UIKit
#endif

struct NowPlayingEntry: TimelineEntry {
  let date: Date
  let playbackInfo: SharedPlaybackInfo?
}

struct NowPlayingProvider: TimelineProvider {
  private let appGroup = "group.com.ome.ampwave"
  private let fileName = "playback.json"

  private func loadInfo() -> SharedPlaybackInfo? {
    guard
      let container = FileManager.default.containerURL(
        forSecurityApplicationGroupIdentifier: appGroup)
    else { return nil }
    let url = container.appendingPathComponent(fileName)
    guard FileManager.default.fileExists(atPath: url.path) else { return nil }
    do {
      let data = try Data(contentsOf: url)
      return try JSONDecoder().decode(SharedPlaybackInfo.self, from: data)
    } catch {
      return nil
    }
  }

  func placeholder(in context: Context) -> NowPlayingEntry {
    NowPlayingEntry(date: Date(), playbackInfo: nil)
  }

  func getSnapshot(in context: Context, completion: @escaping (NowPlayingEntry) -> Void) {
    completion(NowPlayingEntry(date: Date(), playbackInfo: loadInfo()))
  }

  func getTimeline(in context: Context, completion: @escaping (Timeline<NowPlayingEntry>) -> Void) {
    let entry = NowPlayingEntry(date: Date(), playbackInfo: loadInfo())
    completion(
      Timeline(entries: [entry], policy: .after(Date().addingTimeInterval(30)))
    )
  }
}

struct NowPlayingWidgetView: View {
  var entry: NowPlayingEntry
  @Environment(\.widgetFamily) private var family

  #if os(iOS)
    @State private var image: UIImage?
  #else
    @State private var image: NSImage?
  #endif

  private var artURL: URL? {
    guard let name = entry.playbackInfo?.artworkRelativePath,
      let container = FileManager.default.containerURL(
        forSecurityApplicationGroupIdentifier: "group.com.ome.ampwave")
    else { return nil }
    let url = container.appendingPathComponent(name)
    return FileManager.default.fileExists(atPath: url.path) ? url : nil
  }

  var body: some View {
    if let info = entry.playbackInfo {
      HStack(alignment: .center, spacing: 10) {
        #if os(iOS)
          if let url = artURL, let data = try? Data(contentsOf: url), let img = UIImage(data: data)
          {
            Image(uiImage: img)
              .resizable()
              .aspectRatio(contentMode: .fill)
              .frame(
                width: family == .systemSmall ? 52 : 64, height: family == .systemSmall ? 52 : 64
              )
              .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
              .accessibilityHidden(true)
          } else {
            Image(systemName: "music.note")
              .font(.title2)
              .frame(width: 52, height: 52)
              .background(.quaternary)
              .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
          }
        #else
          if let url = artURL, let data = try? Data(contentsOf: url), let img = NSImage(data: data)
          {
            Image(nsImage: img)
              .resizable()
              .aspectRatio(contentMode: .fill)
              .frame(
                width: family == .systemSmall ? 52 : 64, height: family == .systemSmall ? 52 : 64
              )
              .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
              .accessibilityHidden(true)
          } else {
            Image(systemName: "music.note")
              .font(.title2)
              .frame(width: 52, height: 52)
              .background(.quaternary)
              .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
          }
        #endif

        VStack(alignment: .leading, spacing: 4) {
          Text(info.title)
            .font(.headline)
            .lineLimit(2)
            .minimumScaleFactor(0.8)
          Text(info.artist)
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .lineLimit(1)
          Label(
            info.isPlaying ? "Playing" : "Paused",
            systemImage: info.isPlaying ? "play.fill" : "pause.fill"
          )
          .font(.caption2)
          .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
      }
      .padding(8)
    } else {
      VStack(spacing: 6) {
        Image(systemName: "waveform")
          .font(.title)
        Text("Not Playing")
          .font(.headline)
        Text("Open Ampwave")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
  }
}

struct NowPlayingWidget: Widget {
  let kind: String = "NowPlaying"

  var body: some WidgetConfiguration {
    StaticConfiguration(kind: kind, provider: NowPlayingProvider()) { entry in
      NowPlayingWidgetView(entry: entry)
        .containerBackground(.fill.tertiary, for: .widget)
    }
    .configurationDisplayName("Now Playing")
    .description("Current track and artwork from Ampwave.")
    .supportedFamilies([.systemSmall, .systemMedium])
  }
}
