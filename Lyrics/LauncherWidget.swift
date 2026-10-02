internal import SwiftUI
import WidgetKit

private struct AmpwaveLauncherEntry: TimelineEntry {
  let date: Date
}

private struct AmpwaveLauncherProvider: TimelineProvider {
  func placeholder(in context: Context) -> AmpwaveLauncherEntry {
    AmpwaveLauncherEntry(date: .now)
  }

  func getSnapshot(
    in context: Context,
    completion: @escaping (AmpwaveLauncherEntry) -> Void
  ) {
    completion(AmpwaveLauncherEntry(date: .now))
  }

  func getTimeline(
    in context: Context,
    completion: @escaping (Timeline<AmpwaveLauncherEntry>) -> Void
  ) {
    completion(Timeline(entries: [AmpwaveLauncherEntry(date: .now)], policy: .never))
  }
}

private struct AmpwaveLauncherView: View {
  var body: some View {
    AmpwaveLauncherMark()
      .frame(width: 31, height: 22)
      // This is a static brand mark, not private playback information. Keep it
      // visible when WidgetKit redacts Lock Screen content.
      .unredacted()
      .privacySensitive(false)
      .widgetURL(URL(string: "ampwave://open"))
      .accessibilityLabel("Open Ampwave")
  }
}

private struct AmpwaveLauncherMark: View {
  private let heights: [CGFloat] = [0.40, 0.64, 0.85, 1.00, 0.75, 0.55, 0.80, 0.60, 0.35]

  var body: some View {
    GeometryReader { geometry in
      let gap = max(geometry.size.width * 0.025, 0.5)
      let barWidth = (geometry.size.width - gap * CGFloat(heights.count - 1))
        / CGFloat(heights.count)

      HStack(alignment: .center, spacing: gap) {
        ForEach(heights.indices, id: \.self) { index in
          Capsule(style: .continuous)
            .fill(Color.primary)
            .frame(width: barWidth, height: geometry.size.height * heights[index])
        }
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
  }
}

struct AmpwaveLauncherWidget: Widget {
  let kind = "AmpwaveLauncher"

  var body: some WidgetConfiguration {
    StaticConfiguration(kind: kind, provider: AmpwaveLauncherProvider()) { _ in
      AmpwaveLauncherView()
        .containerBackground(.clear, for: .widget)
    }
    .configurationDisplayName("Open Ampwave")
    .description("Open Ampwave quickly from your Lock Screen.")
    .supportedFamilies([.accessoryCircular])
  }
}
