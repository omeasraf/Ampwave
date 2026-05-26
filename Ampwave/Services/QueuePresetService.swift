//
//  QueuePresetService.swift
//  Ampwave
//
//  Saves and restores reusable queue presets.
//

import Foundation

struct QueuePreset: Codable, Identifiable, Equatable {
  let id: UUID
  var name: String
  let songIDs: [UUID]
  let currentIndex: Int
  let shuffleModeRaw: String
  let repeatModeRaw: String
  let savedAt: Date

  init(
    id: UUID = UUID(),
    name: String,
    songIDs: [UUID],
    currentIndex: Int,
    shuffleModeRaw: String,
    repeatModeRaw: String,
    savedAt: Date = Date()
  ) {
    self.id = id
    self.name = name
    self.songIDs = songIDs
    self.currentIndex = currentIndex
    self.shuffleModeRaw = shuffleModeRaw
    self.repeatModeRaw = repeatModeRaw
    self.savedAt = savedAt
  }
}

enum QueuePresetService {
  private static let presetsKey = "com.ampwave.queuePresets"

  static func loadPresets() -> [QueuePreset] {
    guard
      let data = UserDefaults.standard.data(forKey: presetsKey),
      let presets = try? JSONDecoder().decode([QueuePreset].self, from: data)
    else {
      return []
    }

    return presets.sorted { $0.savedAt > $1.savedAt }
  }

  @discardableResult
  static func saveCurrentQueue(named name: String, playback: PlaybackController) -> QueuePreset? {
    let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty, !playback.queue.isEmpty else { return nil }

    var presets = loadPresets()
    let preset = QueuePreset(
      name: trimmed,
      songIDs: playback.queue.map(\.id),
      currentIndex: playback.currentQueueIndex,
      shuffleModeRaw: playback.shuffleMode.rawValue,
      repeatModeRaw: playback.repeatMode.rawValue
    )
    presets.insert(preset, at: 0)
    persist(presets)
    return preset
  }

  static func deletePreset(id: UUID) {
    let filtered = loadPresets().filter { $0.id != id }
    persist(filtered)
  }

  @discardableResult
  static func restorePreset(_ preset: QueuePreset, playback: PlaybackController) -> Bool {
    let songs = preset.songIDs.compactMap { id in
      SongLibrary.shared.songs.first(where: { $0.id == id })
    }

    guard !songs.isEmpty else { return false }

    let boundedIndex = min(max(preset.currentIndex, 0), songs.count - 1)
    playback.restoreSavedQueue(
      songs,
      currentIndex: boundedIndex,
      shuffleMode: ShuffleMode(rawValue: preset.shuffleModeRaw) ?? .off,
      repeatMode: RepeatMode(rawValue: preset.repeatModeRaw) ?? .off
    )
    return true
  }

  private static func persist(_ presets: [QueuePreset]) {
    guard let data = try? JSONEncoder().encode(presets) else { return }
    UserDefaults.standard.set(data, forKey: presetsKey)
  }
}
