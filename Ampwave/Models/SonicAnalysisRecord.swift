import Foundation
import SwiftData

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

  init(
    fileHash: String,
    analysisVersion: Int,
    loudness: Double,
    dynamics: Double,
    zeroCrossingRate: Double,
    brightness: Double,
    crestFactor: Double,
    stereoWidth: Double
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
  }
}
