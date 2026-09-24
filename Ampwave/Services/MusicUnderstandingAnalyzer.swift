import AVFoundation
import Foundation

#if canImport(MusicUnderstanding)
  import MusicUnderstanding
#endif
/// iOS instrument analysis needs a user-initiated continued task with GPU
/// access. Automatic/background library analysis keeps using the DSP fallback.
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
    // Never launch a GPU session from the automatic import/backfill worker.
    return false
  }

  @MainActor
  static var isUserInitiatedAvailable: Bool {
    #if canImport(MusicUnderstanding) && os(iOS)
      if #available(iOS 27.0, *) {
        return BackgroundWorkCoordinator.supportsUserInitiatedGPU
      }
    #elseif canImport(MusicUnderstanding) && os(macOS)
      if #available(macOS 27.0, *) { return true }
    #endif
    return false
  }

  static var requiresProtectedGPU: Bool {
    #if os(iOS)
      return true
    #else
      return false
    #endif
  }

  static func analyze(
    _ track: SonicTrackSnapshot,
    protectedByBackgroundGPUTask: Bool = false
  ) async -> SonicInstrumentActivity? {
    #if canImport(MusicUnderstanding) && (os(iOS) || os(macOS))
      if #available(iOS 27.0, macOS 27.0, *) {
        #if os(iOS)
          guard protectedByBackgroundGPUTask else {
          await DiagnosticLog.shared.log(
            "sonic",
            "Music Understanding skipped without GPU-protected task file=\(track.url.lastPathComponent)"
          )
          return nil
          }
        #endif

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
