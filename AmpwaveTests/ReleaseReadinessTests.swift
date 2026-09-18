import XCTest
import SwiftData
@testable import Ampwave

private actor ControlledAudioActivation {
  var attempts = 0
  private var pending: [CheckedContinuation<Void, Error>] = []
  func activate() async throws {
    attempts += 1
    try await withCheckedThrowingContinuation { pending.append($0) }
  }
  func finish(failing: Bool = false) {
    guard !pending.isEmpty else { return }
    let continuation = pending.removeFirst()
    if failing { continuation.resume(throwing: NSError(domain: "ActivationTest", code: 1)) }
    else { continuation.resume() }
  }
}

@MainActor
final class AudioSessionActivationTests: XCTestCase {
  private func waitForAttempt(_ number: Int, operation: ControlledAudioActivation) async {
    for _ in 0..<1000 {
      if await operation.attempts >= number { return }
      await Task.yield()
    }
    XCTFail("Activation did not start")
  }

  func testConcurrentRequestsShareOneActivation() async {
    let operation = ControlledAudioActivation()
    let activation = AudioSessionActivation { try await operation.activate() }
    let first = Task { await activation.ensureActive() }
    let second = Task { await activation.ensureActive() }
    await waitForAttempt(1, operation: operation)
    await operation.finish()
    let results = await (first.value, second.value)
    XCTAssertTrue(results.0 && results.1)
    let attempts = await operation.attempts
    XCTAssertEqual(attempts, 1)
    XCTAssertTrue(activation.isActive)
  }

  func testInvalidatedCompletionCannotRestoreActiveState() async {
    let operation = ControlledAudioActivation()
    let activation = AudioSessionActivation { try await operation.activate() }
    let first = Task { await activation.ensureActive() }
    await waitForAttempt(1, operation: operation)
    activation.invalidate()
    await operation.finish()
    let staleResult = await first.value
    XCTAssertFalse(staleResult)
    XCTAssertFalse(activation.isActive)
    let second = Task { await activation.ensureActive() }
    await waitForAttempt(2, operation: operation)
    await operation.finish()
    let result = await second.value
    XCTAssertTrue(result)
  }

  func testFailedActivationIsNotCachedAndCanRetry() async {
    let operation = ControlledAudioActivation()
    let activation = AudioSessionActivation { try await operation.activate() }
    let first = Task { await activation.ensureActive() }
    await waitForAttempt(1, operation: operation)
    await operation.finish(failing: true)
    let failedResult = await first.value
    XCTAssertFalse(failedResult)
    XCTAssertFalse(activation.isActive)
    let second = Task { await activation.ensureActive() }
    await waitForAttempt(2, operation: operation)
    await operation.finish()
    let result = await second.value
    XCTAssertTrue(result)
  }
}

final class ReleaseReadinessTests: XCTestCase {
  func testFilenameParserRemovesTrackNumberAndExtractsArtist() {
    let parsed = FilenameParser.parse("04 - Gracie Abrams - Good Reason.flac")

    XCTAssertEqual(parsed.artists, ["Gracie Abrams"])
    XCTAssertEqual(parsed.title, "Good Reason")
    XCTAssertGreaterThanOrEqual(parsed.confidence, 0.8)
  }

  func testFilenameParserPreservesAccentedMetadata() {
    let parsed = FilenameParser.parse("Black Idol - Annihilate (feat. Loïc Rossetti).flac")

    XCTAssertEqual(parsed.artists, ["Black Idol"])
    XCTAssertTrue(parsed.title.contains("Loïc Rossetti"))
  }

  func testMetadataMatcherAcceptsNormalizedEquivalentMetadata() {
    let score = MetadataMatcher.computeMatchScore(
      title1: "That's So True",
      artist1: "Gracie Abrams",
      duration1: 166,
      title2: "That’s So True",
      artist2: "GRACIE ABRAMS",
      duration2: 167
    )

    XCTAssertGreaterThanOrEqual(score, 0.9)
  }

  func testMetadataMatcherRejectsUnrelatedTracks() {
    let score = MetadataMatcher.computeMatchScore(
      title1: "Good Reason",
      artist1: "Gracie Abrams",
      duration1: 248,
      title2: "Completely Different",
      artist2: "Another Artist",
      duration2: 180
    )

    XCTAssertLessThan(score, 0.3)
  }

  func testEmbeddedMetadataConfidencePenalizesPlaceholderValues() {
    XCTAssertEqual(
      MetadataConfidenceScorer.scoreEmbedded(value: "Unknown Artist", field: "artist"),
      0.4
    )
    XCTAssertEqual(
      MetadataConfidenceScorer.scoreEmbedded(value: "Gracie Abrams", field: "artist"),
      0.95
    )
  }
}

@MainActor
final class ImportStorageTests: XCTestCase {
  @MainActor private struct Fixture {
    let root: URL
    let container: ModelContainer
    let library: SongLibrary
    let preferences: UserPreferences
    let defaults: UserDefaults
    let defaultsSuite: String
    let previousThemePreferences: UserPreferences?
    let previousImportHook: ((LibrarySong) -> Void)?
    let previousLoadHook: (([LibrarySong]) -> Void)?
    var context: ModelContext { container.mainContext }
    var sourceDirectory: URL { root.appendingPathComponent("External/Songs/Album") }

    init() throws {
      defaultsSuite = "ImportStorageTests-library-\(UUID().uuidString)"
      defaults = UserDefaults(suiteName: defaultsSuite)!
      previousThemePreferences = ThemeManager.shared.userPreferences
      previousImportHook = SongLibrary.songWasImported
      previousLoadHook = SongLibrary.libraryDidLoad
      // A durable location outside tmp: reference imports must reject staging
      // files belonging to a download/extraction that will be cleaned up.
      root = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("ImportStorageTests-\(UUID().uuidString)")
      let schema = Schema([
        LibrarySong.self, Album.self, Artist.self, Playlist.self, PlaylistIcon.self,
        RadioStation.self, ListeningHistory.self, SongPlayStatistics.self,
        SyncedLyric.self, AppSettings.self, UserPreferences.self, PlaybackState.self,
        PendingScrobble.self, AmpwaveCapsule.self, SonicAnalysisRecord.self,
      ])
      container = try ModelContainer(
        for: schema, configurations: ModelConfiguration(isStoredInMemoryOnly: true)
      )
      container.mainContext.autosaveEnabled = false
      preferences = UserPreferences.getOrCreate(in: container.mainContext)
      preferences.copyMusicToStorage = false
      preferences.autoFetchMetadata = false
      preferences.autoFetchArtistAlbumInfo = false
      preferences.autoFetchLyrics = false
      preferences.isOfflineMode = true
      AppSettings.getOrCreate(in: container.mainContext).mergeSongDuplicates = false
      library = SongLibrary(
        songsDirectory: root.appendingPathComponent("Managed/Songs"),
        artworkCacheDirectory: root.appendingPathComponent("Managed/Artwork"),
        defaults: defaults
      )
      library.modelContext = container.mainContext
      try FileManager.default.createDirectory(at: sourceDirectory, withIntermediateDirectories: true)
      try container.mainContext.save()
      SongLibrary.songWasImported = nil
      SongLibrary.libraryDidLoad = nil
    }

    func audioFile(_ name: String = "Artist - Song", sample: Int16 = 400) throws -> URL {
      let url = sourceDirectory.appendingPathComponent(name).appendingPathExtension("wav")
      var data = Data()
      func text(_ value: String) { data.append(contentsOf: value.utf8) }
      func word<T: FixedWidthInteger>(_ value: T) {
        var littleEndian = value.littleEndian
        withUnsafeBytes(of: &littleEndian) { data.append(contentsOf: $0) }
      }
      let sampleCount: UInt32 = 8_000
      text("RIFF"); word(UInt32(36) + sampleCount * 2); text("WAVEfmt ")
      word(UInt32(16)); word(UInt16(1)); word(UInt16(1)); word(UInt32(8_000))
      word(UInt32(16_000)); word(UInt16(2)); word(UInt16(16))
      text("data"); word(sampleCount * 2)
      for _ in 0..<sampleCount { word(sample) }
      try data.write(to: url)
      return url
    }

    func managedFiles() -> [URL] {
      let enumerator = FileManager.default.enumerator(
        at: library.songsDirectory, includingPropertiesForKeys: [.isRegularFileKey]
      )
      return (enumerator?.allObjects as? [URL] ?? []).filter { !$0.hasDirectoryPath }
    }

    func cleanUp() {
      // The importer schedules optional enrichment after returning. Release
      // its context before this fixture's in-memory container is destroyed.
      library.modelContext = nil
      ThemeManager.shared.userPreferences = previousThemePreferences
      SongLibrary.songWasImported = previousImportHook
      SongLibrary.libraryDidLoad = previousLoadHook
      defaults.removePersistentDomain(forName: defaultsSuite)
      try? FileManager.default.removeItem(at: root)
    }
  }

  func testCopyDefaultsOffButPreservesExplicitOnboardingChoice() {
    let key = "com.ampwave.onboarding.copyToStorage"
    let previous = UserDefaults.standard.object(forKey: key)
    defer {
      if let previous { UserDefaults.standard.set(previous, forKey: key) }
      else { UserDefaults.standard.removeObject(forKey: key) }
    }
    UserDefaults.standard.removeObject(forKey: key)
    XCTAssertFalse(UserPreferences().copyMusicToStorage)
    UserDefaults.standard.set(true, forKey: key)
    XCTAssertTrue(UserPreferences().copyMusicToStorage)
  }

  func testRecentlyPlayedAppearsAtStartAndReusesOneHistoryRowAtFinish() async throws {
    let fixture = try Fixture()
    defer { fixture.cleanUp() }
    let source = try fixture.audioFile()
    await fixture.library.importFiles([source])
    let song = try XCTUnwrap(fixture.library.songs.first)
    let tracker = ListeningHistoryTracker()
    tracker.setModelContext(fixture.context)

    tracker.songStarted(song)
    var rows = try fixture.context.fetch(FetchDescriptor<ListeningHistory>())
    XCTAssertEqual(rows.count, 1)
    XCTAssertEqual(rows.first?.playDuration, 0)
    XCTAssertEqual(tracker.getRecentlyPlayed(library: fixture.library).first?.id, song.id)

    tracker.songEnded(skipped: true)
    rows = try fixture.context.fetch(FetchDescriptor<ListeningHistory>())
    XCTAssertEqual(rows.count, 1, "Finishing must update the start row, not create another play")
    XCTAssertEqual(tracker.getStatistics(for: song)?.playCount, 0)
    XCTAssertEqual(tracker.getStatistics(for: song)?.skipCount, 1)
  }

  func testRediscoverUsesPracticalAgeTiersAndExcludesRecentOrDislikedSongs() async throws {
    let fixture = try Fixture()
    defer { fixture.cleanUp() }
    let files = try [
      fixture.audioFile("A - Favorite", sample: 101),
      fixture.audioFile("B - Forgotten", sample: 102),
      fixture.audioFile("C - Recent", sample: 103),
      fixture.audioFile("D - Disliked", sample: 104),
    ]
    await fixture.library.importFiles(files)
    let now = Date(timeIntervalSince1970: 2_000_000_000)
    var stats: [UUID: SongPlayStatistics] = [:]
    for song in fixture.library.songs {
      let value = SongPlayStatistics(songId: song.id)
      if song.title.contains("Favorite") {
        value.isLiked = true; value.lastPlayedAt = now.addingTimeInterval(-31 * 86_400)
      } else if song.title.contains("Forgotten") {
        value.lastPlayedAt = now.addingTimeInterval(-15 * 86_400)
      } else if song.title.contains("Recent") {
        value.lastPlayedAt = now.addingTimeInterval(-3 * 86_400)
      } else {
        value.isDisliked = true; value.lastPlayedAt = now.addingTimeInterval(-90 * 86_400)
      }
      stats[song.id] = value
    }
    let selected = HomeRediscoverSelector.select(songs: fixture.library.songs, stats: stats, now: now)
    XCTAssertEqual(selected.map(\.title), ["Favorite", "Forgotten"])
  }

  func testMadeForYouExplanationsReflectFavoritesAndHeavyRotation() async throws {
    let fixture = try Fixture()
    defer { fixture.cleanUp() }
    let files = try [
      fixture.audioFile("One - Seed", sample: 201),
      fixture.audioFile("Two - Favorite", sample: 202),
      fixture.audioFile("Three - Frequent", sample: 203),
      fixture.audioFile("Four - Fresh", sample: 204),
    ]
    await fixture.library.importFiles(files)
    let tracker = ListeningHistoryTracker()
    tracker.setModelContext(fixture.context)
    let favorite = try XCTUnwrap(fixture.library.songs.first { $0.title == "Favorite" })
    let frequent = try XCTUnwrap(fixture.library.songs.first { $0.title == "Frequent" })
    tracker.setLiked(true, for: favorite)
    let frequentStats = SongPlayStatistics(songId: frequent.id)
    for _ in 0..<5 { frequentStats.recordPlay(duration: 60) }
    fixture.context.insert(frequentStats)
    try fixture.context.save()
    tracker.invalidateStatisticsIndex()
    fixture.preferences.enableRecommendations = true
    let engine = RecommendationEngine(library: fixture.library, historyTracker: tracker)
    engine.setModelContext(fixture.context)
    let recommendations = await engine.generateForYouRecommendations()
    let reasons = Dictionary(uniqueKeysWithValues: recommendations.compactMap { recommendation in
      if case .song(let song) = recommendation.item { return (song.id, recommendation.reason) }
      return nil
    })
    XCTAssertEqual(reasons[favorite.id], .favorite)
    XCTAssertEqual(reasons[frequent.id], .heavyRotation)
    XCTAssertGreaterThan(Set(recommendations.map { $0.reason.displayText }).count, 1)
  }

  func testExplicitStartupLoadDoesNotLaunchASecondLoadAndEmptyLibraryStaysLoaded() async throws {
    let fixture = try Fixture()
    defer { fixture.cleanUp() }
    fixture.library.modelContext = nil
    var loads = 0
    SongLibrary.libraryDidLoad = { _ in loads += 1 }
    fixture.library.setModelContext(fixture.context, loadImmediately: false)
    await fixture.library.loadSongs()
    fixture.library.setModelContext(fixture.context)
    await Task.yield()
    await fixture.library.loadSongs()
    XCTAssertEqual(loads, 1)
  }

  func testCompletedAnalysisNeverResolvesAudioURLsDuringBackfillOrPlaybackPriority() async throws {
    let fixture = try Fixture()
    defer { fixture.cleanUp() }
    let source = try fixture.audioFile()
    await fixture.library.importFiles([source])
    let song = try XCTUnwrap(fixture.library.songs.first)
    fixture.context.insert(SonicAnalysisRecord(
      fileHash: song.fileHash, analysisVersion: 1,
      loudness: 0, dynamics: 0, zeroCrossingRate: 0,
      brightness: 0, crestFactor: 0, stereoWidth: 0,
      musicUnderstandingVersion: MusicUnderstandingAnalyzer.analysisVersion,
      instrumentActivityData: Data()
    ))
    try fixture.context.save()
    var resolutions = 0
    let service = SonicRecommendationService { _, _ in
      resolutions += 1
      return source
    }
    service.setModelContext(fixture.context)
    service.enqueueMissingAnalysis(for: fixture.library.songs, library: fixture.library)
    service.enqueueAnalysis(for: song, library: fixture.library)
    service.prioritizeAnalysis(for: song)
    XCTAssertEqual(resolutions, 0)
    XCTAssertFalse(service.hasPendingAnalysis)
  }

  func testAnalysisIndexDistinguishesMissingAndOutdatedActivityWithoutDecodingIt() throws {
    let fixture = try Fixture()
    defer { fixture.cleanUp() }
    for (hash, version, data) in [
      ("complete", 1, Data(repeating: 7, count: 1_000_000)),
      ("missing", 1, nil),
      ("outdated", 0, Data([1])),
    ] as [(String, Int, Data?)] {
      fixture.context.insert(SonicAnalysisRecord(
        fileHash: hash, analysisVersion: 1, loudness: 0, dynamics: 0,
        zeroCrossingRate: 0, brightness: 0, crestFactor: 0, stereoWidth: 0,
        musicUnderstandingVersion: version, instrumentActivityData: data
      ))
    }
    try fixture.context.save()
    // Use a fresh context so the query cannot reuse models created above.
    let index = try SonicRecommendationService.analysisIndex(in: ModelContext(fixture.container))
    XCTAssertEqual(index.base, ["complete", "missing", "outdated"])
    XCTAssertEqual(index.complete, ["complete"])
  }

  func testInitialLoadDefersMergingAndAnalysisUntilAfterLaunch() async throws {
    let fixture = try Fixture()
    defer { fixture.cleanUp() }
    let first = try fixture.audioFile(sample: 320)
    let second = try fixture.audioFile("Artist - Alternate", sample: 321)
    await fixture.library.importFiles([first, second])
    for song in fixture.library.songs { song.title = "Song"; song.album = "Album" }
    AppSettings.getOrCreate(in: fixture.context).mergeSongDuplicates = true
    try fixture.context.save()
    var backfills = 0
    SongLibrary.libraryDidLoad = { _ in backfills += 1 }
    await fixture.library.loadSongs(force: true, performMaintenance: false)
    XCTAssertEqual(fixture.library.songs.count, 2)
    XCTAssertEqual(backfills, 0)
    await fixture.library.finishDeferredLoading()
    XCTAssertEqual(fixture.library.songs.count, 1)
    XCTAssertEqual(backfills, 1)
  }

  func testLaunchLoadCanDeferAlbumsAndArtistsUntilAfterFirstFrame() async throws {
    let fixture = try Fixture()
    defer { fixture.cleanUp() }
    await fixture.library.importFiles([try fixture.audioFile()])

    let launchLibrary = SongLibrary(
      songsDirectory: fixture.library.songsDirectory,
      artworkCacheDirectory: fixture.library.artworkCacheDirectory,
      defaults: fixture.defaults
    )
    launchLibrary.setModelContext(fixture.context, loadImmediately: false)
    defer { launchLibrary.modelContext = nil }

    await launchLibrary.loadSongs(
      force: true,
      performMaintenance: false,
      includeCollections: false
    )
    XCTAssertEqual(launchLibrary.songs.count, 1)
    XCTAssertTrue(launchLibrary.albums.isEmpty)
    XCTAssertTrue(launchLibrary.artists.isEmpty)

    await launchLibrary.finishDeferredLoading()
    XCTAssertFalse(launchLibrary.albums.isEmpty)
    XCTAssertFalse(launchLibrary.artists.isEmpty)
  }

  func testPlaybackFolderLeaseSurvivesMonitorBackgroundAndIsReleasedOnLastOwner() async throws {
    let fixture = try Fixture()
    defer { fixture.cleanUp() }
    let source = try fixture.audioFile()
    await fixture.library.importFiles([source])
    var starts = 0
    var stops = 0
    let pool = SecurityScopedAccessPool(start: { _ in starts += 1; return true }, stop: { _ in stops += 1 })
    let monitor = LibraryMonitorService(library: fixture.library, defaults: fixture.defaults, accessPool: pool)
    defer { monitor.stop() }
    monitor.registerReferencedFolder(fixture.sourceDirectory, expectedGeneration: fixture.library.importGeneration)
    await monitor.waitForPendingChanges()
    let song = try XCTUnwrap(fixture.library.songs.first)
    let current = try XCTUnwrap(monitor.acquirePlaybackAccess(for: song))
    let preload = try XCTUnwrap(monitor.acquirePlaybackAccess(for: song))
    XCTAssertEqual(current.url, fixture.sourceDirectory)
    XCTAssertEqual(starts, 1, "Presenter, scan and player share the original folder grant")
    monitor.applicationDidEnterBackground()
    XCTAssertEqual(stops, 0, "Removing presenters must not revoke playback access")
    current.release()
    current.release()
    XCTAssertEqual(stops, 0)
    preload.release()
    XCTAssertEqual(stops, 1)
  }

  func testMergedReferencesStayExcludedAcrossRestartButAlternativeReturnsWhenSurvivorIsDeleted() async throws {
    let fixture = try Fixture()
    defer { fixture.cleanUp() }
    let first = try fixture.audioFile("Artist - Song", sample: 451)
    let alternative = try fixture.audioFile("Artist - Song (duplicate)", sample: 952)
    let firstBytes = try Data(contentsOf: first)
    let alternativeBytes = try Data(contentsOf: alternative)
    await fixture.library.importFiles([first, alternative])
    XCTAssertEqual(fixture.library.songs.count, 2)
    for song in fixture.library.songs {
      song.title = "Song"
      song.album = "Album"
    }
    AppSettings.getOrCreate(in: fixture.context).mergeSongDuplicates = true
    try fixture.context.save()
    await fixture.library.loadSongs(force: true)
    XCTAssertEqual(fixture.library.songs.count, 1)
    XCTAssertEqual(fixture.library.liveMonitoringMergedHashes.count, 1)
    XCTAssertEqual(try Data(contentsOf: first), firstBytes)
    XCTAssertEqual(try Data(contentsOf: alternative), alternativeBytes)

    let restartedLibrary = SongLibrary(
      songsDirectory: fixture.library.songsDirectory,
      artworkCacheDirectory: fixture.library.artworkCacheDirectory,
      defaults: fixture.defaults
    )
    defer { restartedLibrary.modelContext = nil }
    restartedLibrary.setModelContext(fixture.context, loadImmediately: false)
    await restartedLibrary.loadSongs()
    XCTAssertEqual(restartedLibrary.liveMonitoringMergedHashes.count, 1)
    let retained = try XCTUnwrap(restartedLibrary.songs.first)
    let retainedID = retained.id
    let retainedURL = restartedLibrary.getFileURL(for: retained)
    let monitor = LibraryMonitorService(library: restartedLibrary, defaults: fixture.defaults)
    defer { monitor.stop() }
    var imported = 0
    SongLibrary.songWasImported = { _ in imported += 1 }
    monitor.registerReferencedFolder(fixture.sourceDirectory, expectedGeneration: restartedLibrary.importGeneration)
    await monitor.waitForPendingChanges()
    XCTAssertEqual(imported, 0, "A fresh scan must not reimport the merged source")
    XCTAssertEqual(restartedLibrary.songs.map(\.id), [retainedID])
    let presenterGeneration = monitor.presenterGeneration
    monitor.start()
    XCTAssertEqual(monitor.presenterGeneration, presenterGeneration, "Repeated start must preserve active scopes")
    await monitor.waitForPendingChanges()

    monitor.stop()
    try FileManager.default.removeItem(at: retainedURL)
    monitor.start()
    await monitor.waitForPendingChanges()
    XCTAssertEqual(imported, 1, "The other external source must remain recoverable")
    XCTAssertEqual(restartedLibrary.songs.count, 1)
    XCTAssertNotEqual(restartedLibrary.songs.first?.id, retainedID)
    XCTAssertTrue(fixture.managedFiles().isEmpty)
    restartedLibrary.clearLiveMonitoringExclusions()
    XCTAssertNil(fixture.defaults.object(forKey: "com.ampwave.mergedReferenceHashes"))
  }

  func testReferenceImportDoesNotCopyAudioAndCannotFallBackToManagedAudio() async throws {
    let fixture = try Fixture()
    defer { fixture.cleanUp() }
    let source = try fixture.audioFile()
    let accepted = await fixture.library.importFiles([source])
    XCTAssertTrue(accepted)
    let song = try XCTUnwrap(fixture.library.songs.first)
    XCTAssertEqual(song.storageMode, .referenced)
    XCTAssertEqual(fixture.library.getFileURL(for: song), source)
    XCTAssertTrue(fixture.managedFiles().isEmpty)
    XCTAssertTrue(fixture.library.fileExists(for: song))

    // Reproduce the dangerous same-name managed fallback, including a source
    // whose external path contains /Songs/.
    let oldCopy = fixture.library.songsDirectory.appendingPathComponent(song.fileName)
    try FileManager.default.copyItem(at: source, to: oldCopy)
    try FileManager.default.removeItem(at: source)
    fixture.library.invalidateResolvedURLCache()
    XCTAssertEqual(fixture.library.getFileURL(for: song), source)
    XCTAssertFalse(fixture.library.fileExists(for: song))
    await fixture.library.reconcileReferencedSources()
    XCTAssertTrue(fixture.library.songs.isEmpty)
    XCTAssertEqual(try fixture.context.fetchCount(FetchDescriptor<LibrarySong>()), 0)
    XCTAssertTrue(FileManager.default.fileExists(atPath: oldCopy.path))
  }

  func testDeletedFolderPrunesSongsAndPlaylistRelationships() async throws {
    let fixture = try Fixture()
    defer { fixture.cleanUp() }
    let first = try fixture.audioFile("Artist - One", sample: 100)
    let second = try fixture.audioFile("Artist - Two", sample: 200)
    await fixture.library.importFiles([first, second])
    XCTAssertEqual(fixture.library.songs.count, 2)
    let playlist = Playlist(name: "Source album")
    playlist.songs = fixture.library.songs
    playlist.songOrder = fixture.library.songs.map(\.id)
    fixture.context.insert(playlist)
    try fixture.context.save()

    let deletion = expectation(forNotification: .songsWereDeleted, object: nil) { notification in
      (notification.object as? Set<UUID>)?.count == 2
    }
    try FileManager.default.removeItem(at: fixture.sourceDirectory)
    await fixture.library.reconcileReferencedSources()
    await fulfillment(of: [deletion], timeout: 2)
    XCTAssertTrue(fixture.library.songs.isEmpty)
    XCTAssertTrue(playlist.songs.isEmpty)
    XCTAssertTrue(playlist.songOrder.isEmpty)
    XCTAssertEqual(try fixture.context.fetchCount(FetchDescriptor<Album>()), 0)
    XCTAssertTrue(fixture.managedFiles().isEmpty)
  }

  func testCopyIsOptInAndExplicitReferenceReimportRetiresOldCopy() async throws {
    let fixture = try Fixture()
    defer { fixture.cleanUp() }
    let source = try fixture.audioFile()
    fixture.preferences.copyMusicToStorage = true
    await fixture.library.importFiles([source])
    let song = try XCTUnwrap(fixture.library.songs.first)
    let originalID = song.id
    let copy = fixture.library.getFileURL(for: song)
    XCTAssertEqual(song.storageMode, .copied)
    XCTAssertNotEqual(copy, source)
    XCTAssertTrue(FileManager.default.fileExists(atPath: copy.path))

    fixture.preferences.copyMusicToStorage = false
    // Toggling is not authorization to destroy an existing intentional copy.
    XCTAssertTrue(FileManager.default.fileExists(atPath: copy.path))
    await fixture.library.importFiles([source])
    XCTAssertEqual(fixture.library.songs.count, 1)
    XCTAssertEqual(fixture.library.songs.first?.id, originalID)
    XCTAssertEqual(song.storageMode, .referenced)
    XCTAssertEqual(fixture.library.getFileURL(for: song), source)
    XCTAssertFalse(FileManager.default.fileExists(atPath: copy.path))
    XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
  }

  func testDownloadCannotForceCopyWhenSettingIsOff() async throws {
    let fixture = try Fixture()
    defer { fixture.cleanUp() }
    let source = try fixture.audioFile()
    let accepted = await fixture.library.importFiles([source], forceCopy: true)
    XCTAssertFalse(accepted)
    XCTAssertTrue(fixture.library.songs.isEmpty)
    XCTAssertTrue(fixture.managedFiles().isEmpty)
  }

  func testIntentionalCopySurvivesDeletionOfOriginal() async throws {
    let fixture = try Fixture()
    defer { fixture.cleanUp() }
    let source = try fixture.audioFile()
    fixture.preferences.copyMusicToStorage = true
    await fixture.library.importFiles([source])
    try FileManager.default.removeItem(at: source)
    await fixture.library.reconcileReferencedSources()
    let song = try XCTUnwrap(fixture.library.songs.first)
    XCTAssertEqual(song.storageMode, .copied)
    XCTAssertTrue(fixture.library.fileExists(for: song))
  }

  func testTemporaryDownloadCannotBecomeAReference() async throws {
    let fixture = try Fixture()
    defer { fixture.cleanUp() }
    let source = try fixture.audioFile()
    let temporary = FileManager.default.temporaryDirectory
      .appendingPathComponent("ImportStorageTests-\(UUID().uuidString).wav")
    try FileManager.default.copyItem(at: source, to: temporary)
    defer { try? FileManager.default.removeItem(at: temporary) }
    let accepted = await fixture.library.importFiles([temporary])
    XCTAssertFalse(accepted)
    XCTAssertTrue(fixture.library.songs.isEmpty)
    XCTAssertTrue(fixture.managedFiles().isEmpty)
  }

  func testUnreadableSourceIsNotMistakenForDeletion() async throws {
    let fixture = try Fixture()
    defer { fixture.cleanUp() }
    let source = try fixture.audioFile()
    await fixture.library.importFiles([source])
    try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: fixture.sourceDirectory.path)
    defer {
      try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fixture.sourceDirectory.path)
    }
    XCTAssertFalse(PathManager.isDefinitelyMissing(source))
    await fixture.library.reconcileReferencedSources()
    XCTAssertEqual(fixture.library.songs.count, 1)
  }

  func testManagedFolderIsIndexedWithoutAnotherCopyEvenWithCopyingOff() async throws {
    let fixture = try Fixture()
    defer { fixture.cleanUp() }
    let external = try fixture.audioFile()
    let owned = fixture.library.songsDirectory.appendingPathComponent(external.lastPathComponent)
    try FileManager.default.moveItem(at: external, to: owned)
    await fixture.library.importFiles([owned])
    XCTAssertEqual(fixture.library.songs.count, 1)
    XCTAssertEqual(fixture.library.songs.first?.storageMode, .copied)
    XCTAssertEqual(fixture.managedFiles().count, 1)
  }

  func testResetDrainsAnImportAndRejectsNewWorkUntilFinished() async throws {
    let fixture = try Fixture()
    defer { fixture.cleanUp() }
    let source = try fixture.audioFile()
    let importing = Task { await fixture.library.importFiles([source]) }
    let oldGeneration = fixture.library.importGeneration
    await Task.yield()
    await fixture.library.prepareForLibraryReset()
    _ = await importing.value
    let countAtReset = try fixture.context.fetchCount(FetchDescriptor<LibrarySong>())
    let acceptedDuringReset = await fixture.library.importFiles([source])
    XCTAssertFalse(acceptedDuringReset)
    await Task.yield()
    XCTAssertEqual(try fixture.context.fetchCount(FetchDescriptor<LibrarySong>()), countAtReset)
    XCTAssertTrue(fixture.managedFiles().isEmpty)
    XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
    fixture.library.finishLibraryReset()
    let acceptedStaleWork = await fixture.library.importFiles([source], expectedGeneration: oldGeneration)
    XCTAssertFalse(acceptedStaleWork)
    await fixture.library.importFiles([source])
    XCTAssertEqual(fixture.library.songs.count, 1)
  }

  func testReferencePathsAreNotRepairedIntoTheAppContainer() {
    let missing = "/external/Songs/Artist/Album/missing.flac"
    XCTAssertEqual(PathManager.referencedURL(for: missing).path, missing)
    let sibling = PathManager.baseDirectory.path + "-other/Songs/song.wav"
    XCTAssertEqual(PathManager.relativePath(from: sibling), sibling)
    XCTAssertTrue(PathManager.isTrashed(URL(fileURLWithPath: "/provider/.Trash/Album/song.wav")))
  }

  private func resetReferences(_ fixture: Fixture, monitor: LibraryMonitorService) async throws {
    monitor.prepareForLibraryReset()
    await fixture.library.prepareForLibraryReset()
    fixture.library.resetInMemoryState()
    try LibraryResetCoordinator.removeLibraryRecords(in: fixture.context)
    fixture.library.finishLibraryReset()
    await fixture.library.loadSongs(force: true)
  }

  func testResetUnlinksFolderAcrossRestartAndRejectsOldCallbacks() async throws {
    let fixture = try Fixture()
    defer { fixture.cleanUp() }
    let suiteName = "ImportStorageTests-monitor-\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let monitor = LibraryMonitorService(library: fixture.library, defaults: defaults)
    defer { monitor.stop() }
    let source = try fixture.audioFile()
    let originalData = try Data(contentsOf: source)
    await fixture.library.importFiles([source])
    XCTAssertFalse(fixture.preferences.copyMusicToStorage)

    let oldImportGeneration = fixture.library.importGeneration
    monitor.registerReferencedFolder(fixture.sourceDirectory, expectedGeneration: oldImportGeneration)
    await monitor.waitForPendingChanges()
    XCTAssertTrue(monitor.monitoredURLs.contains(fixture.sourceDirectory))
    XCTAssertEqual(defaults.array(forKey: "com.ampwave.liveLibraryReferencedFolders")?.count, 1)
    let oldPresenterGeneration = monitor.presenterGeneration

    // A new file can be reported before reset but processed after it. It must
    // not be imported, even though no ignore-list hash exists for this file.
    let newSource = try fixture.audioFile("Artist - Added later", sample: 901)
    monitor.recordPresentedChange(at: newSource, generation: oldPresenterGeneration)
    try await resetReferences(fixture, monitor: monitor)
    XCTAssertTrue(monitor.monitoredURLs.isEmpty)
    XCTAssertNil(defaults.object(forKey: "com.ampwave.liveLibraryReferencedFolders"))
    XCTAssertEqual(try fixture.context.fetchCount(FetchDescriptor<LibrarySong>()), 0)

    monitor.recordPresentedChange(at: newSource, generation: oldPresenterGeneration)
    monitor.registerReferencedFolder(fixture.sourceDirectory, expectedGeneration: oldImportGeneration)
    monitor.applicationDidBecomeActive()
    await monitor.waitForPendingChanges()
    XCTAssertTrue(fixture.library.songs.isEmpty)
    XCTAssertNil(defaults.object(forKey: "com.ampwave.liveLibraryReferencedFolders"))
    monitor.stop()

    // A fresh monitor sees the same persisted state after relaunch: no linked
    // source to scan, even if that source contains newly added music.
    let restarted = LibraryMonitorService(library: fixture.library, defaults: defaults)
    defer { restarted.stop() }
    restarted.start()
    await restarted.waitForPendingChanges()
    XCTAssertTrue(fixture.library.songs.isEmpty)
    XCTAssertEqual(restarted.monitoredURLs, [fixture.library.songsDirectory])
    XCTAssertEqual(try Data(contentsOf: source), originalData)
    XCTAssertTrue(FileManager.default.fileExists(atPath: newSource.path))

    // Only a new, explicit folder selection restores the link.
    restarted.registerReferencedFolder(fixture.sourceDirectory, expectedGeneration: fixture.library.importGeneration)
    await restarted.waitForPendingChanges()
    XCTAssertEqual(fixture.library.songs.count, 2)
    XCTAssertTrue(fixture.library.songs.allSatisfy { $0.storageMode == .referenced })
    XCTAssertTrue(fixture.managedFiles().isEmpty)
  }

  func testResetUnlinksIndividualSongBookmarksWithoutDeletingOriginals() async throws {
    let fixture = try Fixture()
    defer { fixture.cleanUp() }
    let suiteName = "ImportStorageTests-monitor-\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let monitor = LibraryMonitorService(library: fixture.library, defaults: defaults)
    defer { monitor.stop() }
    let source = try fixture.audioFile()
    let originalData = try Data(contentsOf: source)
    await fixture.library.importFiles([source])
    let song = try XCTUnwrap(fixture.library.songs.first)
    XCTAssertNotNil(song.bookmarkData)
    XCTAssertEqual(fixture.library.getFileURL(for: song), source)
    monitor.start()
    await monitor.waitForPendingChanges()
    XCTAssertTrue(monitor.monitoredURLs.contains(source))
    let oldGeneration = monitor.presenterGeneration

    try await resetReferences(fixture, monitor: monitor)
    XCTAssertTrue(monitor.monitoredURLs.isEmpty)
    XCTAssertEqual(try fixture.context.fetchCount(FetchDescriptor<LibrarySong>()), 0)
    monitor.recordPresentedChange(at: source, generation: oldGeneration)
    monitor.applicationDidBecomeActive()
    await monitor.waitForPendingChanges()
    XCTAssertTrue(fixture.library.songs.isEmpty)
    XCTAssertFalse(monitor.monitoredURLs.contains(source))
    XCTAssertEqual(try Data(contentsOf: source), originalData)
  }

  func testResetForgetsFolderLinksEvenWhenMonitoringIsDisabled() async throws {
    let fixture = try Fixture()
    defer { fixture.cleanUp() }
    let suiteName = "ImportStorageTests-monitor-\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let monitor = LibraryMonitorService(library: fixture.library, defaults: defaults)
    defer { monitor.stop() }
    monitor.isEnabled = false
    let source = try fixture.audioFile()
    await fixture.library.importFiles([source])
    monitor.registerReferencedFolder(fixture.sourceDirectory, expectedGeneration: fixture.library.importGeneration)
    XCTAssertNotNil(defaults.object(forKey: "com.ampwave.liveLibraryReferencedFolders"))
    XCTAssertTrue(monitor.monitoredURLs.isEmpty)

    try await resetReferences(fixture, monitor: monitor)
    monitor.isEnabled = true
    await monitor.waitForPendingChanges()
    XCTAssertNil(defaults.object(forKey: "com.ampwave.liveLibraryReferencedFolders"))
    XCTAssertTrue(fixture.library.songs.isEmpty)
    XCTAssertEqual(monitor.monitoredURLs, [fixture.library.songsDirectory])
    XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
  }
}
