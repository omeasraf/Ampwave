//
//  LibraryMonitorService.swift
//  Ampwave
//
//  Event-driven monitoring for referenced and app-managed music folders.
//

import CryptoKit
import Foundation
import Observation

/// Receives coordinated changes for one music directory. File presenter
/// callbacks arrive on a private operation queue and are forwarded to the
/// main-actor monitor, which debounces bursts from sync providers.
private final class MusicFolderPresenter: NSObject, NSFilePresenter {
  let presentedItemURL: URL?
  let presentedItemOperationQueue: OperationQueue
  private let changeHandler: (URL) -> Void

  init(url: URL, changeHandler: @escaping (URL) -> Void) {
    presentedItemURL = url
    self.changeHandler = changeHandler

    let queue = OperationQueue()
    queue.name = "com.ampwave.referenced-folder-presenter"
    queue.qualityOfService = .utility
    queue.maxConcurrentOperationCount = 1
    presentedItemOperationQueue = queue
    super.init()
  }

  func presentedItemDidChange() {
    if let presentedItemURL { changeHandler(presentedItemURL) }
  }

  func presentedSubitemDidAppear(at url: URL) {
    changeHandler(url)
  }

  func presentedSubitemDidChange(at url: URL) {
    changeHandler(url)
  }

  func presentedSubitemDidDisappear(at url: URL) {
    changeHandler(url.deletingLastPathComponent())
  }

  func presentedSubitem(at oldURL: URL, didMoveTo newURL: URL) {
    changeHandler(newURL)
  }
}

@MainActor
@Observable
final class LibraryMonitorService {
  static let shared = LibraryMonitorService()

  private struct PresenterRegistration {
    let presenter: MusicFolderPresenter
    let folderURL: URL
    let isAccessingSecurityScope: Bool
  }

  private let enabledKey = "com.ampwave.liveLibraryMonitoringEnabled"
  private let referencedFoldersKey = "com.ampwave.liveLibraryReferencedFolders"
  private let managedFolderStampKey = "com.ampwave.liveLibraryManagedFolderStamp"
  nonisolated private static let audioExtensions: Set<String> = [
    "mp3", "m4a", "aac", "flac", "wav", "ogg", "opus", "aiff", "wma", "alac", "m4b",
  ]

  private var registrations: [PresenterRegistration] = []
  private var folderSnapshots: [String: Set<String>] = [:]
  private var pendingChangedURLs: Set<URL> = []
  private var needsFullReconciliation = false
  private var changeDebounceTask: Task<Void, Never>?
  private var reconciliationTask: Task<Void, Never>?
  private var reconciliationID: UUID?
  private var isInBackground = false

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
      if newValue { start() } else { stop() }
    }
  }

  /// Starts foreground event delivery and performs one reconciliation for
  /// changes that may have happened while Ampwave was not running.
  func start() {
    guard isEnabled, !isInBackground else { return }
    activateFilePresenters()
    scheduleReconciliation()
  }

  func stop() {
    changeDebounceTask?.cancel()
    changeDebounceTask = nil
    reconciliationTask?.cancel()
    reconciliationTask = nil
    reconciliationID = nil
    pendingChangedURLs.removeAll()
    needsFullReconciliation = false
    deactivateFilePresenters()
  }

  func applicationDidBecomeActive() {
    isInBackground = false
    start()
  }

  func applicationDidEnterBackground() {
    isInBackground = true
    changeDebounceTask?.cancel()
    changeDebounceTask = nil
    reconciliationTask?.cancel()
    reconciliationTask = nil
    reconciliationID = nil
    pendingChangedURLs.removeAll()
    needsFullReconciliation = false
    // Apple recommends removing file presenters before entering the
    // background to avoid coordinated-write deadlocks with other processes.
    deactivateFilePresenters()
  }

  /// Remembers a Files folder selected while "Copy Imported Music" is off.
  func registerReferencedFolder(_ url: URL) {
    let secured = url.startAccessingSecurityScopedResource()
    defer { if secured { url.stopAccessingSecurityScopedResource() } }

    guard let bookmark = PathManager.createBookmark(for: url) else { return }
    var bookmarks = referencedFolderBookmarks
    let path = Self.normalizedPath(url)
    let alreadyRegistered = bookmarks.contains { data in
      PathManager.resolveBookmark(data).map(Self.normalizedPath) == path
    }
    guard !alreadyRegistered else { return }

    bookmarks.append(bookmark)
    UserDefaults.standard.set(bookmarks, forKey: referencedFoldersKey)

    if isEnabled, !isInBackground {
      activateFilePresenters()
      scheduleReconciliation()
    }
  }

  private var referencedFolderBookmarks: [Data] {
    UserDefaults.standard.array(forKey: referencedFoldersKey) as? [Data] ?? []
  }

  private func activateFilePresenters() {
    deactivateFilePresenters()

    // Files copied directly into Ampwave's exposed Songs directory never pass
    // through the document picker, so this presenter is what makes those
    // additions visible immediately.
    addPresenter(for: SongLibrary.shared.songsDirectory, securityScoped: false)

    for bookmark in referencedFolderBookmarks {
      guard let folderURL = PathManager.resolveBookmark(bookmark) else { continue }
      let secured = folderURL.startAccessingSecurityScopedResource()
      addPresenter(for: folderURL, securityScoped: secured)
    }
  }

  private func addPresenter(for folderURL: URL, securityScoped: Bool) {
    let presenter = MusicFolderPresenter(url: folderURL) { [weak self] changedURL in
      Task { @MainActor in self?.recordPresentedChange(at: changedURL) }
    }
    NSFileCoordinator.addFilePresenter(presenter)
    registrations.append(
      PresenterRegistration(
        presenter: presenter,
        folderURL: folderURL,
        isAccessingSecurityScope: securityScoped
      )
    )
  }

  private func deactivateFilePresenters() {
    for registration in registrations {
      NSFileCoordinator.removeFilePresenter(registration.presenter)
      if registration.isAccessingSecurityScope {
        registration.folderURL.stopAccessingSecurityScopedResource()
      }
    }
    registrations.removeAll()
  }

  private func recordPresentedChange(at url: URL) {
    guard isEnabled, !isInBackground else { return }

    if Self.audioExtensions.contains(url.pathExtension.lowercased()) {
      pendingChangedURLs.insert(url)
    } else {
      // Some providers report only the containing directory. Reconcile in
      // that case so nested additions are still found.
      needsFullReconciliation = true
    }

    changeDebounceTask?.cancel()
    changeDebounceTask = Task { [weak self] in
      try? await Task.sleep(nanoseconds: 1_500_000_000)
      guard !Task.isCancelled else { return }
      await self?.processPresentedChanges()
    }
  }

  private func processPresentedChanges() async {
    let urls = Array(pendingChangedURLs)
    pendingChangedURLs.removeAll()
    let reconcile = needsFullReconciliation
    needsFullReconciliation = false

    if reconcile {
      await reconcileMonitoredFolders()
    } else if !urls.isEmpty {
      let managedDirectory = SongLibrary.shared.songsDirectory
      let managedFiles = urls.filter { Self.isInside($0, directory: managedDirectory) }
      let referencedFiles = urls.filter { !Self.isInside($0, directory: managedDirectory) }
      await importNewManagedFiles(managedFiles)
      rememberManagedFolderStamp(managedDirectory)
      await importGenuinelyNewReferencedFiles(referencedFiles)
    }
  }

  private func scheduleReconciliation() {
    guard reconciliationTask == nil else { return }
    let taskID = UUID()
    reconciliationID = taskID
    reconciliationTask = Task { [weak self] in
      guard let self else { return }
      // Give the launch splash its first frame before any library work begins.
      await Task.yield()
      await self.reconcileMonitoredFolders()
      // A canceled task may finish after foregrounding scheduled its
      // replacement. Only clear the registration that belongs to this task.
      if self.reconciliationID == taskID {
        self.reconciliationTask = nil
        self.reconciliationID = nil
      }
    }
  }

  /// One launch/foreground fallback scan. Normal live monitoring is driven by
  /// NSFilePresenter events, so there is no recurring folder enumeration.
  private func reconcileMonitoredFolders() async {
    let library = SongLibrary.shared
    guard library.modelContext != nil, !Task.isCancelled else { return }

    let managedFolder = library.songsDirectory
    if managedFolderNeedsScan(managedFolder) {
      let managedScan = await scan(folder: managedFolder)
      guard !Task.isCancelled else { return }
      let managedKey = Self.normalizedPath(managedFolder)
      if folderSnapshots[managedKey] != managedScan.1 {
        folderSnapshots[managedKey] = managedScan.1
        await importNewManagedFiles(managedScan.0)
      }
      rememberManagedFolderStamp(managedFolder)
    }

    for bookmark in referencedFolderBookmarks {
      guard !Task.isCancelled,
        let folderURL = PathManager.resolveBookmark(bookmark)
      else { return }

      // Use a separate balanced security-scope access for this scan. The
      // presenter can be removed if the app backgrounds while enumeration is
      // suspended without invalidating the scan's own access token.
      let secured = folderURL.startAccessingSecurityScopedResource()
      let scan = await scan(folder: folderURL)
      if secured { folderURL.stopAccessingSecurityScopedResource() }
      guard !Task.isCancelled else { return }

      let folderKey = Self.normalizedPath(folderURL)
      if folderSnapshots[folderKey] == scan.1 { continue }
      folderSnapshots[folderKey] = scan.1
      await importGenuinelyNewReferencedFiles(scan.0)
    }
  }

  private func scan(folder: URL) async -> ([URL], Set<String>) {
    await Task.detached(priority: .utility) {
      let files = Self.audioFiles(in: folder)
      return (files, Set(files.map(Self.snapshotEntry)))
    }.value
  }

  /// iOS does not expose a directory hash. Its modification date is the cheap
  /// change token, while the content snapshot remains the authoritative check
  /// only after that token changes. On first use, the startup index timestamp
  /// proves the managed folder was already reconciled this launch.
  private func managedFolderNeedsScan(_ folder: URL) -> Bool {
    guard let stamp = Self.directoryModificationStamp(folder) else { return true }

    if UserDefaults.standard.object(forKey: managedFolderStampKey) != nil {
      return UserDefaults.standard.double(forKey: managedFolderStampKey) != stamp
    }

    let startupScan = UserDefaults.standard.double(forKey: "com.ampwave.lastDiskScanTime")
    if startupScan > 0, stamp <= startupScan {
      UserDefaults.standard.set(stamp, forKey: managedFolderStampKey)
      return false
    }
    return true
  }

  private func rememberManagedFolderStamp(_ folder: URL) {
    guard let stamp = Self.directoryModificationStamp(folder) else { return }
    UserDefaults.standard.set(stamp, forKey: managedFolderStampKey)
  }

  private func importNewManagedFiles(_ files: [URL]) async {
    let library = SongLibrary.shared
    guard library.modelContext != nil, !files.isEmpty, !Task.isCancelled else { return }

    let knownHashes = Set(library.songs.map(\.fileHash))
    let newFiles = await Self.uniqueFiles(files, excluding: knownHashes)
    guard !Task.isCancelled, !newFiles.isEmpty else { return }

    print("[DEBUG] LibraryMonitorService: Indexing \(newFiles.count) new managed files")
    await library.importManagedFilesInPlace(newFiles)
  }

  /// Path aliases from Files providers are verified by content hash before the
  /// importer is called. Existing songs and albums are never rewritten here.
  private func importGenuinelyNewReferencedFiles(_ files: [URL]) async {
    let library = SongLibrary.shared
    guard library.modelContext != nil, !files.isEmpty, !Task.isCancelled else { return }

    let knownPaths = storedReferencedPaths(in: library)
    let possibleNewFiles = files.filter {
      Self.audioExtensions.contains($0.pathExtension.lowercased())
        && !knownPaths.contains(Self.normalizedPath($0))
    }
    guard !possibleNewFiles.isEmpty else { return }

    let excludedHashes = Set(library.songs.map(\.fileHash))
      .union(library.liveMonitoringIgnoredHashes)
    let newFiles = await Self.uniqueFiles(possibleNewFiles, excluding: excludedHashes)

    guard !Task.isCancelled, !newFiles.isEmpty else { return }
    print("[DEBUG] LibraryMonitorService: Importing \(newFiles.count) new referenced files")
    await library.importFiles(newFiles, forceCopy: false)
  }

  nonisolated private static func uniqueFiles(
    _ files: [URL], excluding hashes: Set<String>
  ) async -> [URL] {
    await Task.detached(priority: .utility) {
      var seenHashes = hashes
      var uniqueFiles: [URL] = []
      for url in files {
        guard !Task.isCancelled,
          audioExtensions.contains(url.pathExtension.lowercased()),
          let hash = fileHash(at: url),
          seenHashes.insert(hash).inserted
        else { continue }
        uniqueFiles.append(url)
      }
      return uniqueFiles
    }.value
  }

  private func storedReferencedPaths(in library: SongLibrary) -> Set<String> {
    Set(
      library.songs
        .filter { $0.storageMode == .referenced }
        .compactMap { song -> String? in
          guard let path = song.filePath, !path.isEmpty else { return nil }
          let url = path.hasPrefix("/")
            ? URL(fileURLWithPath: path)
            : PathManager.baseDirectory.appendingPathComponent(path)
          return Self.normalizedPath(url)
        }
    )
  }

  nonisolated private static func audioFiles(in folderURL: URL) -> [URL] {
    guard
      let enumerator = FileManager.default.enumerator(
        at: folderURL,
        includingPropertiesForKeys: [
          .isRegularFileKey, .fileSizeKey, .contentModificationDateKey,
        ],
        options: [.skipsHiddenFiles, .skipsPackageDescendants]
      )
    else { return [] }

    var files: [URL] = []
    for case let url as URL in enumerator
    where audioExtensions.contains(url.pathExtension.lowercased())
    {
      files.append(url)
    }
    return files
  }

  nonisolated private static func normalizedPath(_ url: URL) -> String {
    url.standardizedFileURL.path
      .precomposedStringWithCanonicalMapping
      .lowercased()
  }

  nonisolated private static func isInside(_ url: URL, directory: URL) -> Bool {
    let path = url.standardizedFileURL.pathComponents
    let directoryPath = directory.standardizedFileURL.pathComponents
    return path.count > directoryPath.count && path.starts(with: directoryPath)
  }

  nonisolated private static func snapshotEntry(_ url: URL) -> String {
    let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
    let size = values?.fileSize ?? -1
    let modified = values?.contentModificationDate?.timeIntervalSince1970 ?? -1
    return "\(normalizedPath(url))|\(size)|\(modified)"
  }

  nonisolated private static func directoryModificationStamp(_ url: URL) -> Double? {
    let values = try? url.resourceValues(forKeys: [.contentModificationDateKey])
    return values?.contentModificationDate?.timeIntervalSince1970
  }

  nonisolated private static func fileHash(at url: URL) -> String? {
    do {
      let handle = try FileHandle(forReadingFrom: url)
      defer { try? handle.close() }

      var hasher = SHA256()
      while true {
        let data = try autoreleasepool { try handle.read(upToCount: 65_536) }
        guard let data, !data.isEmpty else { break }
        hasher.update(data: data)
      }

      return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    } catch {
      print("[DEBUG] LibraryMonitorService: Couldn't hash \(url.lastPathComponent): \(error)")
      return nil
    }
  }
}
