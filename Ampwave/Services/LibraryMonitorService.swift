//
//  LibraryMonitorService.swift
//  Ampwave
//
//  Event-driven monitoring for referenced and app-managed music folders.
//

import CryptoKit
import Foundation
import Observation

/// A presenter, a scan, and multiple player items can share one sandbox grant.
/// Each releases its own lease; backgrounding a presenter must not revoke the
/// grant still needed by the audio player.
@MainActor
final class SecurityScopedAccessPool {
  @MainActor final class Lease {
    let url: URL
    private var releaseAction: (() -> Void)?
    init(url: URL, release: @escaping () -> Void) {
      self.url = url
      releaseAction = release
    }
    func release() {
      releaseAction?()
      releaseAction = nil
    }
  }

  private struct Entry { let url: URL; let secured: Bool; var references: Int }
  private var entries: [String: Entry] = [:]
  private let start: (URL) -> Bool
  private let stop: (URL) -> Void

  init(start: @escaping (URL) -> Bool = { $0.startAccessingSecurityScopedResource() },
       stop: @escaping (URL) -> Void = { $0.stopAccessingSecurityScopedResource() }) {
    self.start = start
    self.stop = stop
  }

  func acquire(_ url: URL) -> Lease {
    let key = url.standardizedFileURL.path
    if entries[key] != nil { entries[key]!.references += 1 }
    else {
      let secured = start(url)
      entries[key] = Entry(url: url, secured: secured, references: 1)
      if !secured && !FileManager.default.isReadableFile(atPath: url.path) {
        DiagnosticLog.shared.log("file-access", "Source requires relinking name=\(url.lastPathComponent)")
      }
    }
    return Lease(url: url) { [self] in
      guard var entry = entries[key] else { return }
      entry.references -= 1
      if entry.references == 0 {
        if entry.secured { stop(entry.url) }
        entries[key] = nil
      } else { entries[key] = entry }
    }
  }
}

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

  func accommodatePresentedItemDeletion(completionHandler: @escaping (Error?) -> Void) {
    if let presentedItemURL { changeHandler(presentedItemURL) }
    // The coordinator waits for this acknowledgement before deleting. Never
    // wait on the main actor or a rescan from a file-presenter callback.
    completionHandler(nil)
  }

  func accommodatePresentedSubitemDeletion(at url: URL, completionHandler: @escaping (Error?) -> Void) {
    changeHandler(url)
    completionHandler(nil)
  }

  func presentedItemDidMove(to newURL: URL) {
    if let presentedItemURL { changeHandler(presentedItemURL) }
    changeHandler(newURL)
  }

  func presentedSubitem(at oldURL: URL, didMoveTo newURL: URL) {
    changeHandler(oldURL)
    changeHandler(newURL)
  }
}

@MainActor
@Observable
final class LibraryMonitorService {
  static let shared = LibraryMonitorService(library: .shared)

  private struct PresenterRegistration {
    let presenter: MusicFolderPresenter
    let folderURL: URL
    let access: SecurityScopedAccessPool.Lease?
  }

  private struct FolderScan: Sendable {
    let files: [URL]
    let snapshot: Set<String>
  }

  private let enabledKey = "com.ampwave.liveLibraryMonitoringEnabled"
  private let referencedFoldersKey = "com.ampwave.liveLibraryReferencedFolders"
  private let managedFolderStampKey = "com.ampwave.liveLibraryManagedFolderStamp"
  nonisolated private static let audioExtensions: Set<String> = [
    "mp3", "m4a", "aac", "flac", "wav", "ogg", "opus", "aiff", "wma", "alac", "m4b",
  ]

  private var registrations: [PresenterRegistration] = []
  private var presentedSongIDs: Set<UUID> = []
  private var folderSnapshots: [String: Set<String>] = [:]
  private var folderExclusions: [String: Set<String>] = [:]
  private var pendingChangedURLs: Set<URL> = []
  private var needsFullReconciliation = false
  private var changeDebounceTask: Task<Void, Never>?
  private var reconciliationTask: Task<Void, Never>?
  private var reconciliationID: UUID?
  private var isInBackground = false
  private let library: SongLibrary
  private let defaults: UserDefaults
  private let accessPool: SecurityScopedAccessPool
  private var resolvedFolders: [Data: URL] = [:]
  private var resolvedSongBookmarks: [Data: URL] = [:]
  private(set) var presenterGeneration = UUID()

  init(library: SongLibrary, defaults: UserDefaults = .standard,
       accessPool: SecurityScopedAccessPool? = nil) {
    self.library = library
    self.defaults = defaults
    self.accessPool = accessPool ?? SecurityScopedAccessPool()
  }

  var monitoredURLs: [URL] { registrations.map(\.folderURL) }

  /// Waits for work already scheduled by start or a file-presenter event.
  func waitForPendingChanges() async {
    let changes = changeDebounceTask
    let reconciliation = reconciliationTask
    await changes?.value
    await reconciliation?.value
  }

  var isEnabled: Bool {
    get {
      if defaults.object(forKey: enabledKey) == nil {
        return true
      }
      return defaults.bool(forKey: enabledKey)
    }
    set {
      defaults.set(newValue, forKey: enabledKey)
      if newValue { start() } else { stop() }
    }
  }

  /// Starts foreground event delivery and performs one reconciliation for
  /// changes that may have happened while Ampwave was not running.
  func start() {
    guard !isInBackground, !library.isResetting else { return }
    if isEnabled {
      let referencedIDs = Set(library.songs.filter { $0.storageMode == .referenced }.map(\.id))
      if registrations.isEmpty || referencedIDs != presentedSongIDs { activateFilePresenters() }
    }
    scheduleReconciliation()
  }

  func prepareForLibraryReset() {
    stop()
    folderSnapshots.removeAll()
    folderExclusions.removeAll()
    resolvedFolders.removeAll()
    resolvedSongBookmarks.removeAll()
    defaults.removeObject(forKey: referencedFoldersKey)
    defaults.removeObject(forKey: managedFolderStampKey)
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
  func registerReferencedFolder(_ url: URL, expectedGeneration: UUID) {
    guard !library.isResetting, expectedGeneration == library.importGeneration else { return }
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
    defaults.set(bookmarks, forKey: referencedFoldersKey)

    if isEnabled, !isInBackground {
      activateFilePresenters()
      scheduleReconciliation()
    }
  }

  private var referencedFolderBookmarks: [Data] {
    defaults.array(forKey: referencedFoldersKey) as? [Data] ?? []
  }

  private func resolveFolder(_ bookmark: Data) -> URL? {
    if let url = resolvedFolders[bookmark] { return url }
    let url = PathManager.resolveBookmark(bookmark)
    resolvedFolders[bookmark] = url
    return url
  }

  /// Prefer the actual folder bookmark over constructing a child URL and
  /// attempting to consume another (possibly stale) child sandbox extension.
  func acquirePlaybackAccess(for song: LibrarySong) -> SecurityScopedAccessPool.Lease? {
    guard song.storageMode == .referenced, !library.isResetting,
      let storedURL = expectedStoredURL(for: song), !PathManager.isTrashed(storedURL)
    else { return nil }
    for bookmark in referencedFolderBookmarks {
      if let folder = resolveFolder(bookmark), !PathManager.isTrashed(folder),
        Self.isInside(storedURL, directory: folder) {
        return accessPool.acquire(folder)
      }
    }
    // Individually imported files must use the URL carrying the bookmark's
    // grant, not a freshly constructed URL with the same path.
    if let bookmark = song.bookmarkData {
      let resolved = resolvedSongBookmarks[bookmark] ?? PathManager.resolveBookmark(bookmark)
      if let resolved, !PathManager.isTrashed(resolved),
        !PathManager.isInside(resolved, directory: library.songsDirectory),
        (storedURL.resolvingSymlinksInPath() == resolved.resolvingSymlinksInPath()
          || PathManager.isInside(storedURL, directory: library.songsDirectory)) {
        resolvedSongBookmarks[bookmark] = resolved
        return accessPool.acquire(resolved)
      }
    }
    return nil
  }

  private func activateFilePresenters() {
    deactivateFilePresenters()

    // Files copied directly into Ampwave's exposed Songs directory never pass
    // through the document picker, so this presenter is what makes those
    // additions visible immediately.
    addPresenter(for: library.songsDirectory, access: nil)

    for bookmark in referencedFolderBookmarks {
      guard let folderURL = resolveFolder(bookmark), !PathManager.isTrashed(folderURL) else { continue }
      addPresenter(for: folderURL, access: accessPool.acquire(folderURL))
    }

    // Individually selected files have no imported parent-folder bookmark.
    // Present those files themselves so they receive deletion callbacks too.
    for song in library.songs where song.storageMode == .referenced {
      if let storedURL = expectedStoredURL(for: song), registrations.contains(where: {
        $0.folderURL.standardizedFileURL == storedURL.standardizedFileURL
          || Self.isInside(storedURL, directory: $0.folderURL)
      }) { continue }
      let access = acquirePlaybackAccess(for: song)
      let url = library.getFileURL(for: song)
      guard !PathManager.isTrashed(url),
        !registrations.contains(where: {
          $0.folderURL.standardizedFileURL == url.standardizedFileURL
            || Self.isInside(url, directory: $0.folderURL)
        })
      else { access?.release(); continue }
      addPresenter(for: url, access: access)
    }
    presentedSongIDs = Set(library.songs.filter { $0.storageMode == .referenced }.map(\.id))
  }

  private func addPresenter(for folderURL: URL, access: SecurityScopedAccessPool.Lease?) {
    let generation = presenterGeneration
    let presenter = MusicFolderPresenter(url: folderURL) { [weak self] changedURL in
      Task { @MainActor in self?.recordPresentedChange(at: changedURL, generation: generation) }
    }
    NSFileCoordinator.addFilePresenter(presenter)
    registrations.append(
      PresenterRegistration(
        presenter: presenter,
        folderURL: folderURL,
        access: access
      )
    )
  }

  private func deactivateFilePresenters() {
    // Removing a presenter does not retract callbacks already queued on the
    // main actor. Invalidate them so reset/foreground cannot revive old links.
    presenterGeneration = UUID()
    for registration in registrations {
      NSFileCoordinator.removeFilePresenter(registration.presenter)
      registration.access?.release()
    }
    registrations.removeAll()
    presentedSongIDs.removeAll()
  }

  func recordPresentedChange(at url: URL, generation: UUID) {
    guard generation == presenterGeneration, isEnabled, !isInBackground, !library.isResetting else { return }

    pendingChangedURLs.insert(url)
    if !Self.audioExtensions.contains(url.pathExtension.lowercased()) {
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
    guard !library.isResetting else { return }
    let urls = Array(pendingChangedURLs)
    pendingChangedURLs.removeAll()
    let reconcile = needsFullReconciliation
    needsFullReconciliation = false

    // A directory deletion invalidates all descendants, including currently
    // buffered tracks. Keep the original URL even if its bookmark follows it.
    removeSongsMatchingDisappearedFiles(urls.filter { PathManager.isDefinitelyMissing($0) })
    if reconcile {
      // A provider may report only a nested parent directory. Its change does
      // not always update the root folder's modification date, so the event is
      // itself the authoritative reason to scan the managed tree once.
      await reconcileMonitoredFolders(forceManagedScan: true)
    } else if !urls.isEmpty {
      let existingURLs = urls.filter { FileManager.default.fileExists(atPath: $0.path) }

      let managedDirectory = library.songsDirectory
      let managedFiles = existingURLs.filter { Self.isInside($0, directory: managedDirectory) }
      let referencedFiles = existingURLs.filter { !Self.isInside($0, directory: managedDirectory) }
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
  private func reconcileMonitoredFolders(forceManagedScan: Bool = false) async {
    guard library.modelContext != nil, !library.isResetting, !Task.isCancelled else { return }
    await library.reconcileReferencedSources()
    guard isEnabled, !library.isResetting, !Task.isCancelled else { return }

    let managedFolder = library.songsDirectory
    if forceManagedScan || managedFolderNeedsScan(managedFolder) {
      if let managedScan = await scan(folder: managedFolder) {
        guard !Task.isCancelled, !library.isResetting else { return }
        let managedKey = Self.normalizedPath(managedFolder)
        if folderSnapshots[managedKey] != managedScan.snapshot {
          folderSnapshots[managedKey] = managedScan.snapshot
          reconcileMissingSongs(
            in: managedFolder,
            presentFiles: managedScan.files,
            storageMode: .copied
          )
          await importNewManagedFiles(managedScan.files)
        }
        rememberManagedFolderStamp(managedFolder)
      }
    }

    for bookmark in referencedFolderBookmarks {
      guard !Task.isCancelled, !library.isResetting else { return }
      guard let folderURL = resolveFolder(bookmark),
        !PathManager.isTrashed(folderURL)
      else { continue }

      // The scan owns a lease even if backgrounding removes its presenter.
      let access = accessPool.acquire(folderURL)
      let scan = await scan(folder: folderURL)
      defer { access.release() }
      guard !Task.isCancelled, !library.isResetting, let scan else { continue }

      let folderKey = Self.normalizedPath(folderURL)
      // The source files may be unchanged while a retained duplicate in a
      // different folder disappears, or the user disables duplicate merging.
      if folderSnapshots[folderKey] == scan.snapshot,
        folderExclusions[folderKey] == referencedImportExclusions { continue }
      folderSnapshots[folderKey] = scan.snapshot
      reconcileMissingSongs(
        in: folderURL,
        presentFiles: scan.files,
        storageMode: .referenced
      )
      await importGenuinelyNewReferencedFiles(scan.files)
      folderExclusions[folderKey] = referencedImportExclusions
    }
  }

  private func scan(folder: URL) async -> FolderScan? {
    await Task.detached(priority: .utility) {
      guard let files = Self.audioFiles(in: folder) else { return nil }
      return FolderScan(files: files, snapshot: Set(files.map(Self.snapshotEntry)))
    }.value
  }

  /// Removes database entries only after a successful scan of a folder that
  /// Ampwave is already responsible for monitoring. Failed security-scope or
  /// provider access produces `nil` above and never turns into a mass deletion.
  private func reconcileMissingSongs(
    in folder: URL,
    presentFiles: [URL],
    storageMode: LibrarySong.StorageMode
  ) {
    let presentPaths = Set(presentFiles.map(Self.normalizedPath))
    let missing = library.songs.filter { song in
      guard song.storageMode == storageMode,
        let expectedURL = expectedStoredURL(for: song),
        Self.isInside(expectedURL, directory: folder)
      else { return false }
      return !presentPaths.contains(Self.normalizedPath(expectedURL))
    }
    library.removeSongsWhoseFilesDisappeared(missing)
  }

  /// Handles the precise `NSFilePresenter` disappearance callback without
  /// waiting for a recursive folder scan.
  private func removeSongsMatchingDisappearedFiles(_ urls: [URL]) {
    guard !urls.isEmpty else { return }
    let missing = library.songs.filter { song in
      guard let expected = expectedStoredURL(for: song) else { return false }
      return urls.contains {
        Self.normalizedPath(expected) == Self.normalizedPath($0)
          || Self.isInside(expected, directory: $0)
      }
    }
    library.removeSongsWhoseFilesDisappeared(missing)
  }

  private func expectedStoredURL(for song: LibrarySong) -> URL? {
    guard let path = song.filePath, !path.isEmpty else { return nil }
    if path.hasPrefix("/") { return URL(fileURLWithPath: path).standardizedFileURL }
    return PathManager.baseDirectory.appendingPathComponent(path).standardizedFileURL
  }

  /// iOS does not expose a directory hash. Its modification date is the cheap
  /// change token, while the content snapshot remains the authoritative check
  /// only after that token changes. On first use, the startup index timestamp
  /// proves the managed folder was already reconciled this launch.
  private func managedFolderNeedsScan(_ folder: URL) -> Bool {
    guard let stamp = Self.directoryModificationStamp(folder) else { return true }

    if defaults.object(forKey: managedFolderStampKey) != nil {
      return defaults.double(forKey: managedFolderStampKey) != stamp
    }

    let startupScan = defaults.double(forKey: "com.ampwave.lastDiskScanTime")
    if startupScan > 0, stamp <= startupScan {
      defaults.set(stamp, forKey: managedFolderStampKey)
      return false
    }
    return true
  }

  private func rememberManagedFolderStamp(_ folder: URL) {
    guard let stamp = Self.directoryModificationStamp(folder) else { return }
    defaults.set(stamp, forKey: managedFolderStampKey)
  }

  private func importNewManagedFiles(_ files: [URL]) async {
    guard library.modelContext != nil, !files.isEmpty, !Task.isCancelled else { return }

    let knownHashes = Set(library.songs.map(\.fileHash))
    let newFiles = await Self.uniqueFiles(files, excluding: knownHashes)
    guard !Task.isCancelled, !newFiles.isEmpty else { return }

    print("[DEBUG] LibraryMonitorService: Indexing \(newFiles.count) new managed files")
    await library.importManagedFilesInPlace(newFiles)
  }

  /// Path aliases from Files providers are verified by content hash before the
  /// importer is called. Existing songs and albums are never rewritten here.
  private var referencedImportExclusions: Set<String> {
    Set(library.songs.map(\.fileHash))
      .union(library.liveMonitoringIgnoredHashes)
      .union(library.liveMonitoringMergedHashes)
  }

  private func importGenuinelyNewReferencedFiles(_ files: [URL]) async {
    guard library.modelContext != nil, !files.isEmpty, !Task.isCancelled else { return }

    let knownPaths = storedReferencedPaths(in: library)
    let possibleNewFiles = files.filter {
      Self.audioExtensions.contains($0.pathExtension.lowercased())
        && !knownPaths.contains(Self.normalizedPath($0))
    }
    guard !possibleNewFiles.isEmpty else { return }

    let excludedHashes = referencedImportExclusions
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

  nonisolated private static func audioFiles(in folderURL: URL) -> [URL]? {
    // An enumerator can yield a partial tree then fail (offline provider,
    // permissions). That must never become an authoritative deletion list.
    guard let values = try? folderURL.resourceValues(forKeys: [.isDirectoryKey]),
      values.isDirectory == true
    else { return nil }
    var enumerationFailed = false
    guard
      let enumerator = FileManager.default.enumerator(
        at: folderURL,
        includingPropertiesForKeys: [
          .isRegularFileKey, .fileSizeKey, .contentModificationDateKey,
        ],
        options: [.skipsHiddenFiles, .skipsPackageDescendants],
        errorHandler: { _, _ in
          enumerationFailed = true
          return false
        }
      )
    else { return nil }

    var files: [URL] = []
    for case let url as URL in enumerator
    where audioExtensions.contains(url.pathExtension.lowercased())
    {
      files.append(url)
    }
    return enumerationFailed ? nil : files
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
