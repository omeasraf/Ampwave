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
      if family == .systemSmall {
        smallWidget(info)
      } else {
        mediumWidget(info)
      }
    } else {
      emptyWidget
    }
  }

  private func smallWidget(_ info: SharedPlaybackInfo) -> some View {
    GeometryReader { geometry in
      ZStack(alignment: .bottom) {
        artwork(width: geometry.size.width, height: geometry.size.height, cornerRadius: 0)

        LinearGradient(
          colors: [.clear, .black.opacity(0.2), .black.opacity(0.9)],
          startPoint: .center,
          endPoint: .bottom
        )
        .accessibilityHidden(true)

        HStack(alignment: .bottom, spacing: 6) {
          VStack(alignment: .leading, spacing: 1) {
            Text(info.title)
              .font(.system(size: 14, weight: .semibold))
              .lineLimit(2)
              .minimumScaleFactor(0.75)
            Text(info.artist)
              .font(.system(size: 11, weight: .medium))
              .lineLimit(1)
              .opacity(0.82)
          }
          .frame(maxWidth: .infinity, alignment: .leading)

          Image(systemName: info.isPlaying ? "play.fill" : "pause.fill")
            .font(.system(size: 9, weight: .bold))
            .frame(width: 22, height: 22)
            .background(.black.opacity(0.42), in: Circle())
            .accessibilityLabel(info.isPlaying ? "Playing" : "Paused")
        }
        .foregroundStyle(.white)
        .shadow(color: .black.opacity(0.45), radius: 2, y: 1)
        .padding(11)
      }
      .clipped()
    }
  }

  private func mediumWidget(_ info: SharedPlaybackInfo) -> some View {
      HStack(alignment: .center, spacing: 10) {
        artwork(width: 64, height: 64, cornerRadius: 8)

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
  }

  @ViewBuilder
  private func artwork(width: CGFloat, height: CGFloat, cornerRadius: CGFloat) -> some View {
    #if os(iOS)
      if let url = artURL, let data = try? Data(contentsOf: url), let image = UIImage(data: data) {
        Image(uiImage: image)
          .resizable()
          .aspectRatio(contentMode: .fill)
          .frame(width: width, height: height)
          .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
          .accessibilityHidden(true)
      } else {
        artworkPlaceholder(width: width, height: height, cornerRadius: cornerRadius)
      }
    #else
      if let url = artURL, let data = try? Data(contentsOf: url), let image = NSImage(data: data) {
        Image(nsImage: image)
          .resizable()
          .aspectRatio(contentMode: .fill)
          .frame(width: width, height: height)
          .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
          .accessibilityHidden(true)
      } else {
        artworkPlaceholder(width: width, height: height, cornerRadius: cornerRadius)
      }
    #endif
  }

  private func artworkPlaceholder(width: CGFloat, height: CGFloat, cornerRadius: CGFloat) -> some View {
    ZStack {
      LinearGradient(
        colors: [Color.accentColor.opacity(0.75), Color.black.opacity(0.9)],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
      )
      Image(systemName: "music.note")
        .font(.system(size: min(width, height) * 0.3, weight: .medium))
        .foregroundStyle(.white.opacity(0.9))
    }
    .frame(width: width, height: height)
    .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    .accessibilityHidden(true)
  }

  private var emptyWidget: some View {
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
    .contentMarginsDisabled()
  }
}
