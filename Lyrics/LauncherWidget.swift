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
    ZStack {
      AccessoryWidgetBackground()
      Image(systemName: "waveform")
        .font(.system(size: 20, weight: .bold, design: .rounded))
        .symbolRenderingMode(.monochrome)
    }
    .widgetURL(URL(string: "ampwave://open"))
    .accessibilityLabel("Open Ampwave")
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
