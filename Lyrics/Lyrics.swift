//
//  Lyrics.swift
//  Lyrics
//

internal import SwiftUI
import WidgetKit

struct LyricsEntry: TimelineEntry {
    let date: Date
    let playbackInfo: SharedPlaybackInfo?
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
        LyricsEntry(date: Date(), playbackInfo: nil)
    }

    func snapshot(
        for configuration: ConfigurationAppIntent,
        in context: Context
    ) async -> LyricsEntry {
        LyricsEntry(date: Date(), playbackInfo: getPlaybackStatus())
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

        guard let info = playbackInfo, info.isPlaying, let lyrics = info.lyrics,
            !lyrics.isEmpty
        else {
            // Not playing or no lyrics - just one entry
            entries.append(LyricsEntry(date: now, playbackInfo: playbackInfo))
            return Timeline(entries: entries, policy: .atEnd)
        }

        // Generate timeline entries for each lyric line
        // We only generate for the next 5-10 minutes or until end of song to avoid huge timelines
        let songStartTime = info.lastUpdated.addingTimeInterval(
            -info.currentTime
        )

        // Find current and future lines
        let futureLines = lyrics.filter { line in
            let lineDate = songStartTime.addingTimeInterval(line.timestamp)
            return lineDate >= now
        }

        if futureLines.isEmpty {
            // All lyrics passed? Show last one or just current state
            entries.append(LyricsEntry(date: now, playbackInfo: info))
        } else {
            // Create an entry for each future line
            for line in futureLines.prefix(50) {  // Limit to 50 entries
                let lineDate = songStartTime.addingTimeInterval(line.timestamp)
                entries.append(LyricsEntry(date: lineDate, playbackInfo: info))
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
                    if let artworkPath = info.artworkPath,
                        let artworkURL = resolveArtwork(path: artworkPath)
                    {
                        Image(
                            uiImage: UIImage(contentsOfFile: artworkURL.path)
                                ?? UIImage()
                        )
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: 20, height: 20)
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                    }

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
                Text("Open Ampwave to start music")
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
        let songStartTime = info.lastUpdated.addingTimeInterval(
            -info.currentTime
        )
        let relativeTime = date.timeIntervalSince(songStartTime)

        let currentIndex = lines.lastIndex { $0.timestamp <= relativeTime } ?? 0

        switch family {
        case .systemSmall:
            // Just the current line
            Text(lines[currentIndex].text)
                .font(.system(size: 14, weight: .semibold, design: .rounded))
                .lineLimit(3)
                .minimumScaleFactor(0.8)
                .fixedSize(horizontal: false, vertical: true)
                .frame(
                    maxWidth: .infinity,
                    maxHeight: .infinity,
                    alignment: .center
                )
                .multilineTextAlignment(.center)

        case .systemMedium, .systemLarge:
            // Current and next lines
            VStack(alignment: .leading, spacing: 8) {
                ForEach(0..<maxLines(), id: \.self) { offset in
                    let index = currentIndex + offset
                    if index < lines.count {
                        Text(lines[index].text)
                            .font(
                                .system(
                                    size: 16,
                                    weight: offset == 0 ? .bold : .medium,
                                    design: .rounded
                                )
                            )
                            .foregroundStyle(
                                offset == 0 ? .primary : .secondary
                            )
                            .fixedSize(horizontal: false, vertical: true)
                            .lineLimit(family == .systemMedium ? 1 : 3)
                            .opacity(offset == 0 ? 1.0 : 0.6)
                    }
                }
                Spacer()
            }
        default:
            Text(lines[currentIndex].text)
                .font(
                    .system(
                        size: 12,
                        design: .rounded
                    )
                )
                .foregroundStyle(
                    .primary
                )
                .fixedSize(horizontal: false, vertical: true)
                .lineLimit(family == .systemMedium ? 1 : 3)
                .opacity(0.6)
        }
    }

    private func maxLines() -> Int {
        family == .systemLarge ? 7 : family == .systemMedium ? 4 : family == .accessoryCircular || family ==
            .accessoryRectangular ? 2 :  3
    }

    private func resolveArtwork(path: String) -> URL? {
        // Since we are in an extension, documents directory is different.
        // We should have shared artwork in the app group if we want to show it in widget.
        // For now, we'll try to resolve it from the main app's documents via path if possible,
        // but typically that's not allowed.
        // If the path is relative to the documents directory, we can't reach it.
        // Let's assume for now artwork might not show unless we move it to app group.
        return nil
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
        .supportedFamilies([
            .systemSmall, .systemMedium, .systemLarge, .accessoryCircular,
            .accessoryRectangular,
        ])
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
        )
    )
}
