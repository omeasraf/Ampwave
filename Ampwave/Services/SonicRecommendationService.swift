import AVFoundation
import Foundation
import SwiftData

nonisolated struct SonicTrackSnapshot: Sendable {
  let id: UUID
  let fileHash: String
  let url: URL
  let requiresSecurityScope: Bool
}

nonisolated private struct SonicProfile: Sendable {
  let loudness: Double
  let dynamics: Double
  let zeroCrossingRate: Double
  let brightness: Double
  let crestFactor: Double
  let stereoWidth: Double

  init(
    loudness: Double,
    dynamics: Double,
    zeroCrossingRate: Double,
    brightness: Double,
    crestFactor: Double,
    stereoWidth: Double
  ) {
    self.loudness = loudness
    self.dynamics = dynamics
    self.zeroCrossingRate = zeroCrossingRate
    self.brightness = brightness
    self.crestFactor = crestFactor
    self.stereoWidth = stereoWidth
  }

  init(record: SonicAnalysisRecord) {
    loudness = record.loudness
    dynamics = record.dynamics
    zeroCrossingRate = record.zeroCrossingRate
    brightness = record.brightness
    crestFactor = record.crestFactor
    stereoWidth = record.stereoWidth
  }

  func distance(to other: SonicProfile) -> Double {
    let values: [(Double, Double)] = [
      (loudness - other.loudness, 1.25),
      (dynamics - other.dynamics, 1.15),
      (zeroCrossingRate - other.zeroCrossingRate, 0.9),
      (brightness - other.brightness, 1.2),
      (crestFactor - other.crestFactor, 0.85),
      (stereoWidth - other.stereoWidth, 0.65),
    ]
    let square = values.reduce(0.0) { $0 + $1.0 * $1.0 * $1.1 }
    return sqrt(square / values.reduce(0.0) { $0 + $1.1 })
  }

  static func centroid(of profiles: [SonicProfile]) -> SonicProfile? {
    guard !profiles.isEmpty else { return nil }
    let count = Double(profiles.count)
    return SonicProfile(
      loudness: profiles.reduce(0) { $0 + $1.loudness } / count,
      dynamics: profiles.reduce(0) { $0 + $1.dynamics } / count,
      zeroCrossingRate: profiles.reduce(0) { $0 + $1.zeroCrossingRate } / count,
      brightness: profiles.reduce(0) { $0 + $1.brightness } / count,
      crestFactor: profiles.reduce(0) { $0 + $1.crestFactor } / count,
      stereoWidth: profiles.reduce(0) { $0 + $1.stereoWidth } / count
    )
  }
}

/// Owns the persistent sonic index and one low-priority import-analysis worker.
/// SwiftData access stays on the main actor while audio decoding is detached.
@MainActor
final class SonicRecommendationService {
  static let shared = SonicRecommendationService()

  private let analysisVersion = 1
  private var modelContext: ModelContext?
  private var pending: [SonicTrackSnapshot] = []
  private var pendingHashes = Set<String>()
  private var analysisWorker: Task<Void, Never>?

  private init() {}

  func setModelContext(_ context: ModelContext) {
    modelContext = context
  }

  func snapshot(for song: LibrarySong) -> SonicTrackSnapshot {
    snapshot(for: song, library: .shared)
  }

  func snapshot(for song: LibrarySong, library: SongLibrary) -> SonicTrackSnapshot {
    SonicTrackSnapshot(
      id: song.id,
      fileHash: song.fileHash.isEmpty ? "\(song.id)-\(song.size)" : song.fileHash,
      url: library.getFileURL(for: song),
      requiresSecurityScope: song.storageMode == .referenced
    )
  }

  func enqueueAnalysis(for song: LibrarySong) {
    enqueueAnalysis(for: song, library: .shared)
  }

  func enqueueAnalysis(for song: LibrarySong, library: SongLibrary) {
    enqueueAnalysis(snapshot(for: song, library: library))
  }

  /// Backfills existing libraries after upgrading from a build without sonic
  /// analysis, while imports enqueue their new song immediately.
  func enqueueMissingAnalysis(for songs: [LibrarySong]) {
    enqueueMissingAnalysis(for: songs, library: .shared)
  }

  func enqueueMissingAnalysis(for songs: [LibrarySong], library: SongLibrary) {
    guard let modelContext else { return }
    let records = (try? modelContext.fetch(FetchDescriptor<SonicAnalysisRecord>())) ?? []
    let existingHashes = Set(
      records.lazy.filter { $0.analysisVersion == self.analysisVersion }.map(\.fileHash)
    )
    for song in songs {
      let track = snapshot(for: song, library: library)
      if !existingHashes.contains(track.fileHash) {
        enqueueAnalysis(track, databaseCheckAlreadyPerformed: true)
      }
    }
  }

  func rank(
    seed: SonicTrackSnapshot,
    candidates: [SonicTrackSnapshot],
    limit: Int
  ) async -> [UUID] {
    await rank(seeds: [seed], candidates: candidates, limit: limit)
  }

  /// Playlist matching uses the centroid of a representative set of tracks.
  func rank(
    seeds: [SonicTrackSnapshot],
    candidates: [SonicTrackSnapshot],
    limit: Int
  ) async -> [UUID] {
    guard limit > 0 else { return [] }
    var seedProfiles: [SonicProfile] = []
    for seed in seeds {
      if let profile = await profile(for: seed) { seedProfiles.append(profile) }
    }
    guard let reference = SonicProfile.centroid(of: seedProfiles) else { return [] }

    var ranked: [(id: UUID, distance: Double)] = []
    let seedIDs = Set(seeds.map(\.id))
    for candidate in candidates {
      if Task.isCancelled { break }
      guard !seedIDs.contains(candidate.id), let profile = await profile(for: candidate) else {
        continue
      }
      ranked.append((candidate.id, reference.distance(to: profile)))
    }

    let result = ranked.sorted {
      $0.distance == $1.distance
        ? $0.id.uuidString < $1.id.uuidString
        : $0.distance < $1.distance
    }
    .prefix(limit)
    .map(\.id)
    DiagnosticLog.shared.log(
      "sonic",
      "Ranked seeds=\(seeds.count) analyzed=\(ranked.count)/\(candidates.count) returned=\(result.count)"
    )
    return result
  }

  private func enqueueAnalysis(
    _ track: SonicTrackSnapshot,
    databaseCheckAlreadyPerformed: Bool = false
  ) {
    guard !pendingHashes.contains(track.fileHash) else { return }
    guard databaseCheckAlreadyPerformed || fetchProfile(hash: track.fileHash) == nil else {
      return
    }
    pending.append(track)
    pendingHashes.insert(track.fileHash)
    startWorkerIfNeeded()
  }

  private func startWorkerIfNeeded() {
    guard analysisWorker == nil else { return }
    analysisWorker = Task(priority: .utility) { [weak self] in
      guard let self else { return }
      while !Task.isCancelled, !self.pending.isEmpty {
        let track = self.pending.removeLast()
        self.pendingHashes.remove(track.fileHash)
        _ = await self.profile(for: track)
        await Task.yield()
      }
      self.analysisWorker = nil
    }
  }

  private func profile(for track: SonicTrackSnapshot) async -> SonicProfile? {
    if let cached = fetchProfile(hash: track.fileHash) { return cached }
    let analyzed = await Task.detached(priority: .utility) { Self.analyze(track) }.value
    guard let analyzed, let modelContext else { return analyzed }
    if let cached = fetchProfile(hash: track.fileHash) { return cached }

    modelContext.insert(
      SonicAnalysisRecord(
        fileHash: track.fileHash,
        analysisVersion: analysisVersion,
        loudness: analyzed.loudness,
        dynamics: analyzed.dynamics,
        zeroCrossingRate: analyzed.zeroCrossingRate,
        brightness: analyzed.brightness,
        crestFactor: analyzed.crestFactor,
        stereoWidth: analyzed.stereoWidth
      )
    )
    try? modelContext.save()
    return analyzed
  }

  private func fetchProfile(hash: String) -> SonicProfile? {
    guard let modelContext else { return nil }
    let cacheKey = "\(analysisVersion):\(hash)"
    let descriptor = FetchDescriptor<SonicAnalysisRecord>(
      predicate: #Predicate { $0.cacheKey == cacheKey }
    )
    return (try? modelContext.fetch(descriptor).first).map(SonicProfile.init(record:))
  }

  private nonisolated static func analyze(_ track: SonicTrackSnapshot) -> SonicProfile? {
    let secured = track.requiresSecurityScope && track.url.startAccessingSecurityScopedResource()
    defer { if secured { track.url.stopAccessingSecurityScopedResource() } }
    guard
      let file = try? AVAudioFile(
        forReading: track.url,
        commonFormat: .pcmFormatFloat32,
        interleaved: false
      )
    else { return nil }

    let format = file.processingFormat
    let sampleRate = format.sampleRate
    let totalFrames = file.length
    guard sampleRate > 0, totalFrames > 0 else { return nil }
    let regionFrames = AVAudioFrameCount(min(sampleRate * 0.85, Double(totalFrames)))
    guard regionFrames > 0 else { return nil }

    var sampleCount = 0
    var sumSquares = 0.0
    var differenceSquares = 0.0
    var stereoDifferenceSquares = 0.0
    var peak = 0.0
    var zeroCrossings = 0
    var previous: Double?
    var regionRMS: [Double] = []

    for fraction in [0.12, 0.48, 0.78] {
      let requested = AVAudioFramePosition(Double(totalFrames) * fraction)
      file.framePosition = min(requested, max(0, totalFrames - AVAudioFramePosition(regionFrames)))
      guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: regionFrames) else {
        continue
      }
      do { try file.read(into: buffer, frameCount: regionFrames) } catch { continue }
      guard buffer.frameLength > 0, let channels = buffer.floatChannelData else { continue }

      let channelCount = max(1, Int(format.channelCount))
      var localSquares = 0.0
      for frame in 0..<Int(buffer.frameLength) {
        var mixed = 0.0
        for channel in 0..<channelCount { mixed += Double(channels[channel][frame]) }
        mixed /= Double(channelCount)
        let square = mixed * mixed
        sumSquares += square
        localSquares += square
        peak = max(peak, abs(mixed))
        if let previous {
          let difference = mixed - previous
          differenceSquares += difference * difference
          if (mixed >= 0) != (previous >= 0) { zeroCrossings += 1 }
        }
        previous = mixed
        if channelCount > 1 {
          let difference = Double(channels[0][frame] - channels[1][frame])
          stereoDifferenceSquares += difference * difference
        }
        sampleCount += 1
      }
      regionRMS.append(sqrt(localSquares / Double(buffer.frameLength)))
    }

    guard sampleCount > 1 else { return nil }
    let rms = sqrt(sumSquares / Double(sampleCount))
    guard rms.isFinite, rms > 0.000_001 else { return nil }
    let averageRegionRMS = regionRMS.reduce(0, +) / Double(max(regionRMS.count, 1))
    let variance = regionRMS.reduce(0.0) { $0 + pow($1 - averageRegionRMS, 2) }
      / Double(max(regionRMS.count, 1))
    let differenceRMS = sqrt(differenceSquares / Double(sampleCount - 1))
    let stereoDifferenceRMS = sqrt(stereoDifferenceSquares / Double(sampleCount))

    return SonicProfile(
      loudness: clamp((20 * log10(rms) + 60) / 60),
      dynamics: clamp((sqrt(variance) / max(averageRegionRMS, 0.000_001)) / 0.8),
      zeroCrossingRate: clamp((Double(zeroCrossings) / Double(sampleCount - 1)) / 0.3),
      brightness: clamp((differenceRMS / rms) / 2),
      crestFactor: clamp(((peak / rms) - 1) / 9),
      stereoWidth: clamp((stereoDifferenceRMS / rms) / 2)
    )
  }

  private nonisolated static func clamp(_ value: Double) -> Double {
    min(max(value.isFinite ? value : 0, 0), 1)
  }
}
