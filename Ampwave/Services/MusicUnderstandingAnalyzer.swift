import AVFoundation
import Foundation

#if canImport(MusicUnderstanding)
  import MusicUnderstanding
#endif

/// Uses Apple's on-device model when the app is built with the iOS 27 SDK.
/// Every public entry point still exists in iOS 26 builds and simply reports
/// that the richer analysis is unavailable.
nonisolated enum MusicUnderstandingAnalyzer {
  static let analysisVersion = 1

  static var isFrameworkCompiled: Bool {
    #if canImport(MusicUnderstanding)
      return true
    #else
      return false
    #endif
  }

  static var isAvailable: Bool {
    #if canImport(MusicUnderstanding)
      if #available(iOS 27.0, macOS 27.0, tvOS 27.0, watchOS 27.0, visionOS 27.0, *) {
        return true
      }
    #endif
    return false
  }

  static func analyze(_ track: SonicTrackSnapshot) async -> SonicInstrumentActivity? {
    #if canImport(MusicUnderstanding)
      if #available(iOS 27.0, macOS 27.0, tvOS 27.0, watchOS 27.0, visionOS 27.0, *) {
        let secured = track.requiresSecurityScope
          && track.url.startAccessingSecurityScopedResource()
        defer { if secured { track.url.stopAccessingSecurityScopedResource() } }

        do {
          await DiagnosticLog.shared.log(
            "sonic",
            "Music Understanding started file=\(track.url.lastPathComponent)"
          )
          let asset = AVURLAsset(
            url: track.url,
            options: [AVURLAssetPreferPreciseDurationAndTimingKey: true]
          )
          let session = try await MusicUnderstandingSession(asset: asset)
          let result = try await session.analyze(for: [.instrumentActivity])
          guard let activity = result.instrumentActivity else {
            await DiagnosticLog.shared.log(
              "sonic",
              "Music Understanding returned no instrument activity file=\(track.url.lastPathComponent)"
            )
            return nil
          }

          func points(
            for instrument: InstrumentActivityResult.Instrument
          ) -> [SonicActivityPoint] {
            (activity.activity[instrument] ?? []).compactMap { point in
              let seconds = point.time.seconds
              guard seconds.isFinite else { return nil }
              return SonicActivityPoint(
                time: max(0, seconds),
                value: min(max(point.value, 0), 1)
              )
            }
            .sorted { $0.time < $1.time }
          }

          return SonicInstrumentActivity(
            vocal: points(for: .vocal),
            drum: points(for: .drum),
            bass: points(for: .bass),
            other: points(for: .other)
          )
        } catch {
          await DiagnosticLog.shared.log(
            "sonic",
            "Music Understanding failed file=\(track.url.lastPathComponent) error=\(error)"
          )
          return nil
        }
      }
    #endif
    return nil
  }
}
