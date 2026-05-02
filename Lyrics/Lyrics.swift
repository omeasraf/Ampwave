//
//  Lyrics.swift
//  Lyrics
//

internal import SwiftUI
import WidgetKit

struct LyricsEntry: TimelineEntry {
  let date: Date
  let playbackInfo: SharedPlaybackInfo?
  let configuration: ConfigurationAppIntent
}

struct LyricsProvider: AppIntentTimelineProvider {
  private let appGroup = "group.com.ome.ampwave"
  private let fileName = "playback.json"

  private func getPlaybackStatus() -> SharedPlaybackInfo? {
    guard
      let container = FileManager.default.containerURL(
        forSecurityApplicationGroupIdentifier: appGroup
      )
    else {
      return nil
    }
    let url = container.appendingPathComponent(fileName)
    guard FileManager.default.fileExists(atPath: url.path) else {
      return nil
    }
    do {
      let data = try Data(contentsOf: url)
      return try JSONDecoder().decode(SharedPlaybackInfo.self, from: data)
    } catch {
      return nil
    }
  }

  func placeholder(in context: Context) -> LyricsEntry {
    LyricsEntry(date: Date(), playbackInfo: nil, configuration: ConfigurationAppIntent())
  }

  func snapshot(
    for configuration: ConfigurationAppIntent,
    in context: Context
  ) async -> LyricsEntry {
    LyricsEntry(date: Date(), playbackInfo: getPlaybackStatus(), configuration: configuration)
  }

  func timeline(
    for configuration: ConfigurationAppIntent,
    in context: Context
  ) async -> Timeline<
    LyricsEntry
  > {
    let playbackInfo = getPlaybackStatus()
    var entries: [LyricsEntry] = []
    let now = Date()

    guard let info = playbackInfo, info.isPlaying else {
      // Not playing - just one entry
      entries.append(
        LyricsEntry(date: now, playbackInfo: playbackInfo, configuration: configuration))
      return Timeline(entries: entries, policy: .atEnd)
    }

    guard let lyrics = info.lyrics else {
      entries.append(LyricsEntry(date: now, playbackInfo: info, configuration: configuration))
      return Timeline(entries: entries, policy: .atEnd)
    }

    // Generate timeline entries for each lyric line
    let songStartTime = info.lastUpdated.addingTimeInterval(
      -info.currentTime
    )

    // Find current and future lines
    let futureLines = lyrics.filter { line in
      let lineDate = songStartTime.addingTimeInterval(line.timestamp)
      return lineDate >= now
    }

    if futureLines.isEmpty {
      entries.append(LyricsEntry(date: now, playbackInfo: info, configuration: configuration))
    } else {
      // Create an entry for each future line
      for line in futureLines.prefix(50) {  // Limit to 50 entries
        let lineDate = songStartTime.addingTimeInterval(line.timestamp)
        entries.append(
          LyricsEntry(date: lineDate, playbackInfo: info, configuration: configuration))
      }
    }

    return Timeline(entries: entries, policy: .atEnd)
  }
}

struct LyricsEntryView: View {
  var entry: LyricsEntry
  @Environment(\.widgetFamily) var family

  var body: some View {
    if let info = entry.playbackInfo {
      VStack(alignment: .leading, spacing: 4) {
        HStack(alignment: .center, spacing: 8) {
          VStack(alignment: .leading) {
            Text(info.title)
              .font(.system(size: 10, weight: .bold))
              .lineLimit(1)
            Text(info.artist)
              .font(.system(size: 8))
              .lineLimit(1)
              .foregroundStyle(.secondary)
          }
        }
        .padding(.bottom, 4)

        if let lyrics = info.lyrics, !lyrics.isEmpty {
          lyricsView(for: lyrics, at: entry.date, info: info)
        } else {
          Spacer()
          Text("No synced lyrics available")
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .center)
          Spacer()
        }
      }
      .frame(
        maxWidth: .infinity,
        maxHeight: .infinity,
        alignment: .topLeading
      )

    } else {
      VStack {
        Text("Not Playing")
          .font(.headline)
        Text("Open Ampwave")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
    }
  }

  @ViewBuilder
  private func lyricsView(
    for lines: [LyricLine],
    at date: Date,
    info: SharedPlaybackInfo
  )
    -> some View
  {
    // Calculate the elapsed time in the song at the exact moment this timeline entry was intended for
    let timeSinceUpdate = max(0, date.timeIntervalSince(info.lastUpdated))
    let playbackProgress = info.isPlaying ? timeSinceUpdate : 0
    let effectiveTime = info.currentTime + playbackProgress

    let currentIndex = lines.lastIndex { $0.timestamp <= effectiveTime } ?? 0

    switch family {
    case .systemSmall:
      Text(lines[currentIndex].text)
        .font(.system(size: 14, weight: .semibold, design: .rounded))
        .lineLimit(3)
        .minimumScaleFactor(0.8)
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity, maxHeight: .infinity)

    case .systemMedium, .systemLarge:
      VStack(alignment: .leading, spacing: 6) {
        ForEach(0..<maxLines(), id: \.self) { offset in
          let index = currentIndex + offset
          if index < lines.count {
            Text(lines[index].text)
              .font(.system(size: 16, weight: offset == 0 ? .bold : .medium, design: .rounded))
              .foregroundStyle(offset == 0 ? .primary : .secondary)
              .lineLimit(family == .systemMedium ? 1 : 2)
              .opacity(offset == 0 ? 1.0 : 0.6)
          }
        }
        Spacer(minLength: 0)
      }
    default:
      Text(lines[currentIndex].text)
        .font(.system(size: 12, design: .rounded))
    }
  }

  private func maxLines() -> Int {
    family == .systemLarge ? 6 : 3
  }
}

struct Lyrics: Widget {
  let kind: String = "Lyrics"

  var body: some WidgetConfiguration {
    AppIntentConfiguration(
      kind: kind,
      intent: ConfigurationAppIntent.self,
      provider: LyricsProvider()
    ) { entry in
      LyricsEntryView(entry: entry)
        .containerBackground(.fill.tertiary, for: .widget)
    }
    .configurationDisplayName("Synced Lyrics")
    .description("See real-time lyrics for the current song.")
    #if os(macOS)
      .supportedFamilies([
        .systemSmall, .systemMedium, .systemLarge,
      ])
    #else
      .supportedFamilies([
        .systemSmall, .systemMedium, .systemLarge, .accessoryCircular,
        .accessoryRectangular,
      ])
    #endif
  }
}

#Preview(as: .systemMedium) {
  Lyrics()
} timeline: {
  LyricsEntry(
    date: .now,
    playbackInfo: SharedPlaybackInfo(
      title: "Song Title",
      artist: "Artist Name",
      isPlaying: true,
      currentTime: 10,
      lyrics: [
        LyricLine(timestamp: 0, text: "First line of the song"),
        LyricLine(timestamp: 5, text: "Second line comes here"),
        LyricLine(timestamp: 12, text: "Third line is current"),
        LyricLine(timestamp: 20, text: "Fourth line is next"),
      ]
    ),
    configuration: ConfigurationAppIntent()
  )
}
