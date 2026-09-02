import Foundation
import SwiftData

/// Framework-neutral representation of Music Understanding's time-stamped
/// activity output. Keeping Apple's result types out of the model lets the
/// same store continue to open on iOS 26, where the framework is unavailable.
nonisolated struct SonicActivityPoint: Codable, Sendable {
  let time: TimeInterval
  let value: Float
}

nonisolated struct SonicInstrumentActivity: Codable, Sendable {
  let vocal: [SonicActivityPoint]
  let drum: [SonicActivityPoint]
  let bass: [SonicActivityPoint]
  let other: [SonicActivityPoint]

  func value(in points: [SonicActivityPoint], at time: TimeInterval) -> Float {
    guard let first = points.first else { return 0 }
    guard time > first.time else { return first.value }
    guard let last = points.last, time < last.time else { return points.last?.value ?? 0 }

    var lower = 0
    var upper = points.count - 1
    while lower + 1 < upper {
      let middle = (lower + upper) / 2
      if points[middle].time <= time {
        lower = middle
      } else {
        upper = middle
      }
    }

    let lhs = points[lower]
    let rhs = points[upper]
    let span = rhs.time - lhs.time
    guard span > 0 else { return rhs.value }
    let progress = Float((time - lhs.time) / span)
    return lhs.value + (rhs.value - lhs.value) * progress
  }

  func vocalActivity(at time: TimeInterval) -> Float {
    value(in: vocal, at: time)
  }

  func drumActivity(at time: TimeInterval) -> Float {
    value(in: drum, at: time)
  }

  func bassActivity(at time: TimeInterval) -> Float {
    value(in: bass, at: time)
  }
}

/// Persisted, privacy-preserving acoustic characteristics for one audio file.
/// The file hash is the identity so duplicate imports reuse the same analysis.
@Model
final class SonicAnalysisRecord {
  @Attribute(.unique) var cacheKey: String
  var fileHash: String
  var analyzedAt: Date
  var analysisVersion: Int
  var loudness: Double
  var dynamics: Double
  var zeroCrossingRate: Double
  var brightness: Double
  var crestFactor: Double
  var stereoWidth: Double
  /// Nil for records made on systems without Music Understanding. Optional
  /// fields keep this an additive SwiftData migration for existing libraries.
  var musicUnderstandingVersion: Int?
  var instrumentActivityData: Data?

  init(
    fileHash: String,
    analysisVersion: Int,
    loudness: Double,
    dynamics: Double,
    zeroCrossingRate: Double,
    brightness: Double,
    crestFactor: Double,
    stereoWidth: Double,
    musicUnderstandingVersion: Int? = nil,
    instrumentActivityData: Data? = nil
  ) {
    self.cacheKey = "\(analysisVersion):\(fileHash)"
    self.fileHash = fileHash
    self.analyzedAt = Date()
    self.analysisVersion = analysisVersion
    self.loudness = loudness
    self.dynamics = dynamics
    self.zeroCrossingRate = zeroCrossingRate
    self.brightness = brightness
    self.crestFactor = crestFactor
    self.stereoWidth = stereoWidth
    self.musicUnderstandingVersion = musicUnderstandingVersion
    self.instrumentActivityData = instrumentActivityData
  }
}
