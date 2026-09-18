import AVFoundation
import Foundation

#if canImport(MusicUnderstanding)
  import MusicUnderstanding
#endif
#if os(iOS)
  import UIKit
#endif

/// Uses Apple's on-device model when the app is built with the iOS 27 SDK and
/// runs on iOS 27 or later. Every public entry point still exists in older SDK
/// builds and on older systems, where the caller keeps using its DSP fallback.
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
    // MusicUnderstanding's instrument-activity model submits Metal work that
    // survives `MusicUnderstandingSession.cancel()`. If the app backgrounds
    // while that command is in flight, iOS 27 rejects it with
    // kIOGPUCommandBufferCallbackErrorBackgroundExecutionNotPermitted and the
    // framework aborts inside MPSGraph. An abort cannot be caught or recovered
    // from, so instrument analysis is operationally unavailable on iOS until
    // Apple provides a cancellation/background-safe implementation. Returning
    // false makes every caller use Ampwave's existing CPU/DSP analysis.
    return false
  }

  static func analyze(_ track: SonicTrackSnapshot) async -> SonicInstrumentActivity? {
    #if canImport(MusicUnderstanding) && os(iOS)
      if #available(iOS 27.0, *) {
        // Music Understanding submits work to the GPU, which iOS rejects as
        // soon as the app leaves the foreground. Avoid starting a session
        // that cannot complete, while the service's scene-phase hook cancels
        // one that was already running.
        let isForeground = await MainActor.run {
          UIApplication.shared.applicationState == .active
        }
        guard isForeground else {
          await DiagnosticLog.shared.log(
            "sonic",
            "Music Understanding skipped outside foreground file=\(track.url.lastPathComponent)"
          )
          return nil
        }

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
          let result = try await withTaskCancellationHandler {
            try await session.analyze(for: [.instrumentActivity])
          } onCancel: {
            Task { await session.cancel() }
          }
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
