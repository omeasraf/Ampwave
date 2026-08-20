//
//  LibraryMonitorService.swift
//  Ampwave
//
//  Lightweight polling monitor for managed and referenced library folders.
//

import Foundation
import Observation

@MainActor
@Observable
final class LibraryMonitorService {
  static let shared = LibraryMonitorService()

  private let enabledKey = "com.ampwave.liveLibraryMonitoringEnabled"
  private let referencedFoldersKey = "com.ampwave.liveLibraryReferencedFolders"
  private var timer: Timer?
  private var lastObservedModificationDate: Date?
  private var isPolling = false

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

    Task { await poll() }
  }

  func stop() {
    timer?.invalidate()
    timer = nil
  }

  private func poll() async {
    guard isEnabled, !isPolling else { return }
    isPolling = true
    defer { isPolling = false }

    let currentDate = directoryModificationDate()
    if let currentDate, let lastObservedModificationDate,
      currentDate > lastObservedModificationDate
    {
      self.lastObservedModificationDate = currentDate
      await SongLibrary.shared.indexOnStartup()
    } else if let currentDate {
      lastObservedModificationDate = currentDate
    }

    await importNewFilesFromReferencedFolders()
  }

  /// Remembers a Files folder selected while "Copy Imported Music" is off.
  /// Its security-scoped bookmark lets monitoring enumerate newly synced files
  /// on later launches instead of only watching Ampwave's private container.
  func registerReferencedFolder(_ url: URL) {
    let secured = url.startAccessingSecurityScopedResource()
    defer { if secured { url.stopAccessingSecurityScopedResource() } }

    guard let bookmark = PathManager.createBookmark(for: url) else { return }
    var bookmarks = referencedFolderBookmarks
    let path = url.standardizedFileURL.path
    let alreadyRegistered = bookmarks.contains { data in
      PathManager.resolveBookmark(data)?.standardizedFileURL.path == path
    }
    guard !alreadyRegistered else { return }

    bookmarks.append(bookmark)
    UserDefaults.standard.set(bookmarks, forKey: referencedFoldersKey)
  }

  private var referencedFolderBookmarks: [Data] {
    UserDefaults.standard.array(forKey: referencedFoldersKey) as? [Data] ?? []
  }

  private func importNewFilesFromReferencedFolders() async {
    let library = SongLibrary.shared
    guard library.modelContext != nil else { return }

    for bookmark in referencedFolderBookmarks {
      guard let folderURL = PathManager.resolveBookmark(bookmark) else { continue }
      let secured = folderURL.startAccessingSecurityScopedResource()
      defer { if secured { folderURL.stopAccessingSecurityScopedResource() } }

      // A URL previously cached while its provider was unavailable may point
      // at a legacy fallback. Resolve child bookmarks again while the parent
      // folder's security scope is active.
      library.invalidateResolvedURLCache()
      let knownPaths = Set(
        library.songs
          .filter { $0.storageMode == .referenced }
          .map { library.getFileURL(for: $0).standardizedFileURL.path }
      )
      let newFiles = audioFiles(in: folderURL).filter {
        !knownPaths.contains($0.standardizedFileURL.path)
      }

      if !newFiles.isEmpty {
        print(
          "[DEBUG] LibraryMonitorService: Importing \(newFiles.count) new referenced files")
        await library.importFiles(newFiles, forceCopy: false)
      }
    }
  }

  private func audioFiles(in folderURL: URL) -> [URL] {
    let extensions: Set<String> = [
      "mp3", "m4a", "aac", "flac", "wav", "ogg", "opus", "aiff", "wma", "alac", "m4b",
    ]
    guard
      let enumerator = FileManager.default.enumerator(
        at: folderURL,
        includingPropertiesForKeys: [.isRegularFileKey],
        options: [.skipsHiddenFiles, .skipsPackageDescendants]
      )
    else { return [] }

    var files: [URL] = []
    for case let url as URL in enumerator where extensions.contains(url.pathExtension.lowercased()) {
      files.append(url)
    }
    return files
  }

  private func directoryModificationDate() -> Date? {
    let path = SongLibrary.shared.songsDirectory.path
    let attributes = try? FileManager.default.attributesOfItem(atPath: path)
    return attributes?[.modificationDate] as? Date
  }
}
