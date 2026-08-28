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

enum WidgetPalette {
  static func background(_ info: SharedPlaybackInfo?) -> Color {
    info?.themeBackgroundHex.map(Color.init(hex:))
      ?? Color(red: 0.027, green: 0.008, blue: 0.051)
  }

  static func accent(_ info: SharedPlaybackInfo?) -> Color {
    info?.themeAccentHex.map(Color.init(hex:))
      ?? Color(red: 0.91, green: 0.24, blue: 0.54)
  }

  static func primary(_ info: SharedPlaybackInfo?) -> Color {
    info?.themePrimaryTextHex.map(Color.init(hex:))
      ?? ((info?.themeIsDark ?? true) ? .white : .black)
  }

  static func secondary(_ info: SharedPlaybackInfo?) -> Color {
    info?.themeSecondaryTextHex.map(Color.init(hex:))
      ?? primary(info).opacity(0.68)
  }

  static func colorScheme(_ info: SharedPlaybackInfo?) -> ColorScheme {
    (info?.themeIsDark ?? true) ? .dark : .light
  }
}

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
  @Environment(\.widgetRenderingMode) private var renderingMode

  private var usesClearAppearance: Bool {
    renderingMode == .accented
  }

  private var artURL: URL? {
    guard let name = entry.playbackInfo?.artworkRelativePath,
      let container = FileManager.default.containerURL(
        forSecurityApplicationGroupIdentifier: "group.com.ome.ampwave")
    else { return nil }
    let url = container.appendingPathComponent(name)
    return FileManager.default.fileExists(atPath: url.path) ? url : nil
  }

  var body: some View {
    Group {
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
    .containerBackground(for: .widget) {
      if let info = entry.playbackInfo {
        if family == .systemSmall {
          ZStack {
            fullArtworkBackground(info)
            artworkContrastScrim
              .opacity(usesClearAppearance ? 0.55 : 1)
          }
        } else {
          usesClearAppearance ? Color.clear : WidgetPalette.background(info)
        }
      } else {
        WidgetPalette.background(nil)
      }
    }
  }

  private func smallWidget(_ info: SharedPlaybackInfo) -> some View {
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
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
    .clipped()
  }

  @ViewBuilder
  private func fullArtworkBackground(_ info: SharedPlaybackInfo) -> some View {
    #if os(iOS)
      if let image = artworkUIImage {
        Image(uiImage: image)
          .resizable()
          .widgetAccentedRenderingMode(.fullColor)
          .scaledToFill()
          .opacity(usesClearAppearance ? 0.9 : 1)
          .frame(maxWidth: .infinity, maxHeight: .infinity)
          .clipped()
          .accessibilityHidden(true)
      } else {
        artworkBackgroundPlaceholder(info)
      }
    #else
      if let image = artworkNSImage {
        Image(nsImage: image)
          .resizable()
          .scaledToFill()
          .frame(maxWidth: .infinity, maxHeight: .infinity)
          .clipped()
          .accessibilityHidden(true)
      } else {
        artworkBackgroundPlaceholder(info)
      }
    #endif
  }

  private func artworkBackgroundPlaceholder(_ info: SharedPlaybackInfo) -> some View {
    ZStack {
      LinearGradient(
        colors: [WidgetPalette.accent(info).opacity(0.72), WidgetPalette.background(info)],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
      )
      WidgetAmpwaveMark(color: .white.opacity(0.9))
        .frame(width: 64, height: 42)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .accessibilityHidden(true)
  }

  private func mediumWidget(_ info: SharedPlaybackInfo) -> some View {
    GeometryReader { geometry in
      let controlWidth = min(104, geometry.size.width * 0.31)

      HStack(spacing: 8) {
        VStack(alignment: .leading, spacing: 0) {
          HStack(spacing: 6) {
            artworkThumbnail(info, size: 47)
            upcomingArtworkStrip(size: 47)
            Spacer(minLength: 0)
          }

          Spacer(minLength: 7)

          VStack(alignment: .leading, spacing: 1) {
            Text(info.artist)
              .font(.system(size: 10, weight: .medium, design: .rounded))
              .foregroundStyle(.secondary)
              .lineLimit(1)

            Text(info.title)
              .font(.system(size: 15, weight: .bold, design: .rounded))
              .lineLimit(1)
              .minimumScaleFactor(0.72)
          }

          playbackProgressLine(info)
            .padding(.top, 6)

          HStack {
            Text(formattedTime(displayedCurrentTime(info)))
            Spacer()
            Text(formattedTime(info.duration))
          }
          .font(.system(size: 10, weight: .semibold, design: .rounded))
          .monospacedDigit()
          .foregroundStyle(.secondary)
          .padding(.top, 3)
        }
        .padding(10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .background(
          .white.opacity(usesClearAppearance ? 0.025 : 0.065),
          in: RoundedRectangle(cornerRadius: 18, style: .continuous)
        )

        controlPad(info)
          .frame(width: controlWidth)
      }
      .padding(8)
      .foregroundStyle(WidgetPalette.primary(info))
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }

  @ViewBuilder
  private func artworkThumbnail(_ info: SharedPlaybackInfo, size: CGFloat) -> some View {
    #if os(iOS)
      if let image = artworkUIImage {
        Image(uiImage: image)
          .resizable()
          .widgetAccentedRenderingMode(.fullColor)
          .scaledToFit()
          .frame(width: size, height: size)
          .background(.black.opacity(0.16))
          .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
          .accessibilityLabel("Album artwork")
      } else {
        artworkThumbnailPlaceholder(info, size: size)
      }
    #else
      if let image = artworkNSImage {
        Image(nsImage: image)
          .resizable()
          .scaledToFit()
          .frame(width: size, height: size)
          .background(.black.opacity(0.16))
          .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
          .accessibilityLabel("Album artwork")
      } else {
        artworkThumbnailPlaceholder(info, size: size)
      }
    #endif
  }

  private func artworkThumbnailPlaceholder(_ info: SharedPlaybackInfo, size: CGFloat) -> some View {
    ZStack {
      WidgetPalette.accent(info).opacity(0.3)
      WidgetAmpwaveMark(color: .primary.opacity(0.82))
        .frame(width: size * 0.54, height: size * 0.34)
    }
    .frame(width: size, height: size)
    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
  }

  @ViewBuilder
  private func upcomingArtworkStrip(size: CGFloat) -> some View {
    #if os(iOS)
      ForEach(Array(upcomingArtworkUIImages.prefix(2).enumerated()), id: \.offset) { index, image in
        Image(uiImage: image)
          .resizable()
          .widgetAccentedRenderingMode(.fullColor)
          .scaledToFit()
          .frame(width: size, height: size)
          .background(.black.opacity(0.12))
          .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
          .opacity(index == 0 ? 0.48 : 0.3)
          .overlay {
            Image(systemName: "play.fill")
              .font(.system(size: 12, weight: .bold))
              .foregroundStyle(.white.opacity(0.72))
          }
          .accessibilityLabel("Upcoming song artwork")
      }
    #else
      ForEach(Array(upcomingArtworkNSImages.prefix(2).enumerated()), id: \.offset) { index, image in
        Image(nsImage: image)
          .resizable()
          .scaledToFit()
          .frame(width: size, height: size)
          .background(.black.opacity(0.12))
          .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
          .opacity(index == 0 ? 0.48 : 0.3)
          .overlay {
            Image(systemName: "play.fill")
              .font(.system(size: 12, weight: .bold))
              .foregroundStyle(.white.opacity(0.72))
          }
          .accessibilityLabel("Upcoming song artwork")
      }
    #endif
  }

  private func controlPad(_ info: SharedPlaybackInfo) -> some View {
    VStack(spacing: 7) {
      HStack(spacing: 7) {
        widgetControl(
          systemName: "plus.circle", label: "Like current song", route: "control/like")
        widgetControl(
          systemName: info.isPlaying ? "pause.fill" : "play.fill",
          label: info.isPlaying ? "Pause" : "Play",
          route: "control/toggle"
        )
      }

      HStack(spacing: 7) {
        widgetControl(
          systemName: "backward.end.fill", label: "Previous song", route: "control/previous")
        widgetControl(
          systemName: "forward.end.fill", label: "Next song", route: "control/next")
      }
    }
  }

  private func widgetControl(systemName: String, label: String, route: String) -> some View {
    Link(destination: URL(string: "ampwave://\(route)")!) {
      Image(systemName: systemName)
        .font(.system(size: 19, weight: .semibold))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
          .white.opacity(usesClearAppearance ? 0.02 : 0.065),
          in: RoundedRectangle(cornerRadius: 15, style: .continuous)
        )
        .overlay {
          RoundedRectangle(cornerRadius: 15, style: .continuous)
            .stroke(.white.opacity(usesClearAppearance ? 0.52 : 0.22), lineWidth: 1.15)
        }
        .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .accessibilityLabel(label)
  }

  @ViewBuilder
  private var artworkContrastScrim: some View {
    #if os(iOS)
      // Clear and Tinted Home Screen appearances remap ordinary SwiftUI
      // gradients into the white accented group. Treating this translucent
      // scrim as a full-color image preserves the dark contrast behind text.
      Image(uiImage: Self.mediumArtworkScrimImage)
        .resizable()
        .widgetAccentedRenderingMode(.fullColor)
        .accessibilityHidden(true)
    #else
      LinearGradient(
        colors: [
          .black.opacity(0.16),
          .clear,
          .black.opacity(0.48),
          .black.opacity(0.94),
        ],
        startPoint: .top,
        endPoint: .bottom
      )
      .accessibilityHidden(true)
    #endif
  }

  private func playbackProgressLine(_ info: SharedPlaybackInfo) -> some View {
    Group {
      if info.duration > 0 {
        if info.isPlaying {
          animatedWidgetWavyProgress(info)
        } else {
          staticWidgetProgress(info)
        }
      }
    }
    .frame(height: 8)
    .accessibilityLabel("Playback progress")
  }

  private func animatedWidgetWavyProgress(_ info: SharedPlaybackInfo) -> some View {
    GeometryReader { geometry in
      TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: false)) { timeline in
        let progress = min(
          max(displayedCurrentTime(info, at: timeline.date) / max(info.duration, 1), 0),
          1
        )
        let endX = geometry.size.width * progress
        let phase = timeline.date.timeIntervalSinceReferenceDate * 5.5

        ZStack {
          Path { path in
            path.move(to: CGPoint(x: endX, y: geometry.size.height / 2))
            path.addLine(to: CGPoint(x: geometry.size.width, y: geometry.size.height / 2))
          }
          .stroke(
            WidgetPalette.primary(info).opacity(0.28),
            style: StrokeStyle(lineWidth: 2, lineCap: .round)
          )

          WidgetWavyProgressShape(endX: endX, phase: phase)
            .stroke(
              WidgetPalette.accent(info),
              style: StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round)
            )
            .blur(radius: 3)
            .opacity(0.9)

          WidgetWavyProgressShape(endX: endX, phase: phase)
            .stroke(
              .white,
              style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round)
            )

          Circle()
            .fill(.white)
            .frame(width: 6, height: 6)
            .position(x: endX, y: geometry.size.height / 2)
        }
      }
    }
  }

  private func staticWidgetProgress(_ info: SharedPlaybackInfo) -> some View {
    GeometryReader { geometry in
      let progress = min(
        max(displayedCurrentTime(info) / max(info.duration, 1), 0),
        1
      )
      let endX = geometry.size.width * progress
      let midY = geometry.size.height / 2

      ZStack {
        Path { path in
          path.move(to: CGPoint(x: endX, y: midY))
          path.addLine(to: CGPoint(x: geometry.size.width, y: midY))
        }
        .stroke(
          WidgetPalette.primary(info).opacity(0.28),
          style: StrokeStyle(lineWidth: 2, lineCap: .round)
        )

        Path { path in
          path.move(to: CGPoint(x: 0, y: midY))
          path.addLine(to: CGPoint(x: endX, y: midY))
        }
        .stroke(
          WidgetPalette.accent(info),
          style: StrokeStyle(lineWidth: 2.5, lineCap: .round)
        )
        .blur(radius: 3)
        .opacity(0.45)

        Path { path in
          path.move(to: CGPoint(x: 0, y: midY))
          path.addLine(to: CGPoint(x: endX, y: midY))
        }
        .stroke(.white, style: StrokeStyle(lineWidth: 2, lineCap: .round))

        Circle()
          .fill(.white)
          .frame(width: 6, height: 6)
          .position(x: endX, y: midY)
      }
    }
  }

  private func displayedCurrentTime(_ info: SharedPlaybackInfo) -> TimeInterval {
    displayedCurrentTime(info, at: entry.date)
  }

  private func displayedCurrentTime(_ info: SharedPlaybackInfo, at date: Date) -> TimeInterval {
    let elapsed = info.isPlaying ? max(0, date.timeIntervalSince(info.lastUpdated)) : 0
    return min(max(info.currentTime + elapsed, 0), max(info.duration, 0))
  }

  private func formattedTime(_ time: TimeInterval) -> String {
    guard time.isFinite, time > 0 else { return "0:00" }
    let totalSeconds = Int(time.rounded(.down))
    return String(format: "%d:%02d", totalSeconds / 60, totalSeconds % 60)
  }

  private var emptyWidget: some View {
      VStack(spacing: 6) {
        Image(systemName: "waveform")
          .font(.title)
        Text("Not Playing")
          .font(.headline)
        Text("Open Ampwave")
          .font(.caption)
          .foregroundStyle(WidgetPalette.secondary(nil))
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .foregroundStyle(WidgetPalette.primary(nil))
  }

  #if os(iOS)
    private static let mediumArtworkScrimImage: UIImage = {
      let size = CGSize(width: 8, height: 320)
      let format = UIGraphicsImageRendererFormat()
      format.scale = 1
      format.opaque = false

      return UIGraphicsImageRenderer(size: size, format: format).image { context in
        let colors = [
          UIColor.black.withAlphaComponent(0.16).cgColor,
          UIColor.black.withAlphaComponent(0).cgColor,
          UIColor.black.withAlphaComponent(0.48).cgColor,
          UIColor.black.withAlphaComponent(0.94).cgColor,
        ] as CFArray
        let locations: [CGFloat] = [0, 0.34, 0.63, 1]
        guard
          let gradient = CGGradient(
            colorsSpace: CGColorSpaceCreateDeviceRGB(),
            colors: colors,
            locations: locations
          )
        else { return }

        context.cgContext.drawLinearGradient(
          gradient,
          start: CGPoint(x: size.width / 2, y: 0),
          end: CGPoint(x: size.width / 2, y: size.height),
          options: []
        )
      }
    }()

    private var artworkUIImage: UIImage? {
      if let data = entry.playbackInfo?.artworkData, let image = UIImage(data: data) {
        return image
      }
      guard let url = artURL, let data = try? Data(contentsOf: url) else { return nil }
      return UIImage(data: data)
    }

    private var upcomingArtworkUIImages: [UIImage] {
      entry.playbackInfo?.upcomingArtworkData?.compactMap(UIImage.init(data:)) ?? []
    }
  #else
    private var artworkNSImage: NSImage? {
      if let data = entry.playbackInfo?.artworkData, let image = NSImage(data: data) {
        return image
      }
      guard let url = artURL, let data = try? Data(contentsOf: url) else { return nil }
      return NSImage(data: data)
    }


    private var upcomingArtworkNSImages: [NSImage] {
      entry.playbackInfo?.upcomingArtworkData?.compactMap(NSImage.init(data:)) ?? []
    }
  #endif
}

private struct WidgetAmpwaveMark: View {
  let color: Color
  private let heights: [CGFloat] = [0.40, 0.64, 0.85, 1.00, 0.75, 0.55, 0.80, 0.60, 0.35]

  var body: some View {
    GeometryReader { geometry in
      let gap = max(geometry.size.width * 0.025, 0.5)
      let barWidth = (geometry.size.width - gap * CGFloat(heights.count - 1))
        / CGFloat(heights.count)
      HStack(alignment: .center, spacing: gap) {
        ForEach(heights.indices, id: \.self) { index in
          Capsule(style: .continuous)
            .fill(color)
            .frame(width: barWidth, height: geometry.size.height * heights[index])
        }
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
  }
}

private struct WidgetWavyProgressShape: Shape {
  let endX: CGFloat
  let phase: TimeInterval

  func path(in rect: CGRect) -> Path {
    var path = Path()
    let length = max(endX, 0)
    let centerY = rect.midY

    guard length > 2 else {
      path.move(to: CGPoint(x: 0, y: centerY))
      path.addLine(to: CGPoint(x: endX, y: centerY))
      return path
    }

    let wavelength: CGFloat = 14
    let amplitude: CGFloat = 2.5
    let step: CGFloat = 0.5
    let initialPhase = CGFloat(phase)

    path.move(to: CGPoint(x: 0, y: centerY + sin(initialPhase) * amplitude))
    var x: CGFloat = 0
    while x < endX {
      let wavePhase = (x / wavelength) * 2 * CGFloat.pi + initialPhase
      path.addLine(to: CGPoint(x: x, y: centerY + sin(wavePhase) * amplitude))
      x += step
    }
    let endPhase = (length / wavelength) * 2 * CGFloat.pi + initialPhase
    path.addLine(to: CGPoint(x: endX, y: centerY + sin(endPhase) * amplitude))
    return path
  }
}

struct NowPlayingWidget: Widget {
  let kind: String = "NowPlaying"

  var body: some WidgetConfiguration {
    StaticConfiguration(kind: kind, provider: NowPlayingProvider()) { entry in
      NowPlayingWidgetView(entry: entry)
        .environment(\.colorScheme, WidgetPalette.colorScheme(entry.playbackInfo))
    }
    .configurationDisplayName("Now Playing")
    .description("Current track and artwork from Ampwave.")
    .supportedFamilies([.systemSmall, .systemMedium])
    .contentMarginsDisabled()
    .containerBackgroundRemovable(false)
  }
}
