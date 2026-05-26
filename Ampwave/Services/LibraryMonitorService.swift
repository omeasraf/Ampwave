//
//  LibraryMonitorService.swift
//  Ampwave
//
//  Lightweight polling monitor for managed library folder changes.
//

import Foundation
import Observation

@MainActor
@Observable
final class LibraryMonitorService {
  static let shared = LibraryMonitorService()

  private let enabledKey = "com.ampwave.liveLibraryMonitoringEnabled"
  private var timer: Timer?
  private var lastObservedModificationDate: Date?

  private init() {}

  var isEnabled: Bool {
    get {
      if UserDefaults.standard.object(forKey: enabledKey) == nil {
        return true
      }
      return UserDefaults.standard.bool(forKey: enabledKey)
    }
    set {
      UserDefaults.standard.set(newValue, forKey: enabledKey)
      if newValue {
        start()
      } else {
        stop()
      }
    }
  }

  func start() {
    guard isEnabled else { return }
    stop()
    lastObservedModificationDate = directoryModificationDate()

    timer = Timer.scheduledTimer(withTimeInterval: 12, repeats: true) { [weak self] _ in
      Task { @MainActor in
        await self?.poll()
      }
    }
  }

  func stop() {
    timer?.invalidate()
    timer = nil
  }

  private func poll() async {
    guard isEnabled else { return }
    let currentDate = directoryModificationDate()
    guard let currentDate else { return }

    if let lastObservedModificationDate, currentDate > lastObservedModificationDate {
      self.lastObservedModificationDate = currentDate
      await SongLibrary.shared.indexOnStartup()
      return
    }

    lastObservedModificationDate = currentDate
  }

  private func directoryModificationDate() -> Date? {
    let path = SongLibrary.shared.songsDirectory.path
    let attributes = try? FileManager.default.attributesOfItem(atPath: path)
    return attributes?[.modificationDate] as? Date
  }
}
