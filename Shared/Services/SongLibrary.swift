//
//  SongLibrary.swift
//  Ampwave
//
//  Enhanced song library service with artist management and metadata fetching.
//

import CryptoKit
import Foundation
import SwiftData

@Observable
  @MainActor
  final class SongLibrary {
    static let shared = SongLibrary()
  
    private let fileManager = FileManager.default
    private(set) var songs: [LibrarySong] = []
    private(set) var albums: [Album] = []
    private(set) var artists: [Artist] = []
    private(set) var libraryVersion: Int = 0
  
    private var isLoaded = false
  nonisolated let songsDirectory: URL
  nonisolated let artworkCacheDirectory: URL

  /// Indexing status for startup and Files app sync.
  private(set) var indexingStatus: IndexingStatus = .idle
  private(set) var pendingMetadataFetches: Int = 0 {
    didSet {
      updateIndexingStatusForMetadata()
    }
  }
  private var totalMetadataFetches: Int = 0
  private var isGenreBackfillActive: Bool = false

  var modelContext: ModelContext?

  private static let audioExtensions: Set<String> = [
    "mp3", "m4a", "aac", "flac", "wav", "ogg", "opus", "aiff", "wma", "alac", "m4b",
  ]

  private init() {
    let baseDir = PathManager.baseDirectory.standardizedFileURL
    let songsDir = baseDir.appendingPathComponent("Songs", isDirectory: true).standardizedFileURL
    let artworkDir = baseDir.appendingPathComponent("Artwork", isDirectory: true)
      .standardizedFileURL

    self.songsDirectory = songsDir
    self.artworkCacheDirectory = artworkDir

    let fm = FileManager.default
    try? fm.createDirectory(at: songsDir, withIntermediateDirectories: true)
    try? fm.createDirectory(at: artworkDir, withIntermediateDirectories: true)
  }

  func notifyLibraryChange() {
    libraryVersion += 1
  }

  // MARK: - Duplicate Detection

  private func normalizeForMatching(_ text: String) -> String {
    var normalized = text.lowercased()

    // Remove common parenthetical additions and featured artists
    let patterns = [
      "\\(.*?remastered.*?\\)", "\\[.*?remastered.*?\\]",
      "\\(.*?radio edit.*?\\)", "\\[.*?radio edit.*?\\]",
      "\\(.*?live.*?\\)", "\\[.*?live.*?\\]",
      "\\(.*?deluxe.*?\\)", "\\[.*?deluxe.*?\\]",
      "\\(.*?feat\\..*?\\)", "\\[.*?feat\\..*?\\]",
      "\\(.*?ft\\..*?\\)", "\\[.*?ft\\..*?\\]",
      "\\(.*?featuring.*?\\)", "\\[.*?featuring.*?\\]",
      "\\(.*?official.*?\\)", "\\[.*?official.*?\\]",
      "\\(.*?lyrics.*?\\)", "\\[.*?lyrics.*?\\]",
      "\\(.*?hq.*?\\)", "\\[.*?hq.*?\\]",
      "\\(.*?high quality.*?\\)", "\\[.*?high quality.*?\\]",
      "remastered", "radio edit", "deluxe edition",
      "feat\\.", "ft\\.", "featuring", "official video", "official audio",
    ]

    for pattern in patterns {
      normalized = normalized.replacingOccurrences(
        of: pattern, with: "", options: [.regularExpression, .caseInsensitive])
    }

    return
      normalized
      .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
      .replacingOccurrences(of: "[^a-z0-9]", with: "", options: .regularExpression)
      .trimmingCharacters(in: .whitespacesAndNewlines)
  }

  struct DuplicateGroup: Identifiable {
    let id = UUID()
    let songs: [LibrarySong]
    let reason: String
  }

  /// Finds potential duplicate songs in the library.
  nonisolated func findDuplicates() -> [DuplicateGroup] {
    // We need to run this on a background context or ensure we're not blocking MainActor
    // for long periods, but since it's nonisolated, we must fetch the data ourselves.

    // For safety and simplicity, let's keep it isolated to the actor that owns the data
    // but ensure we're using it correctly.

    // Re-evaluating: If I make it nonisolated, I can't access `self.songs`.
    // The crash happened because of cross-thread access to external storage.
    // The safest way is to run it on MainActor (where songs live) but keep it efficient.
    return MainActor.assumeIsolated {
      var groups: [DuplicateGroup] = []

      // 1. Group by file hash (100% confidence)
      var hashGroups: [String: [LibrarySong]] = [:]
      for song in songs {
        hashGroups[song.fileHash, default: []].append(song)
      }

      var accountedForIds = Set<UUID>()
      for (_, group) in hashGroups where group.count > 1 {
        groups.append(DuplicateGroup(songs: group, reason: "Identical File Hash"))
        accountedForIds.formUnion(group.map(\.id))
      }

      // 2. Group by metadata (High confidence: Fuzzy Title + Artist + Album + Duration)
      let remainingSongs = songs.filter { !accountedForIds.contains($0.id) }
      var metaGroups: [String: [LibrarySong]] = [:]

      for song in remainingSongs {
        let title = normalizeForMatching(song.title)
        // Access artists.first safely on MainActor
        let artist = normalizeForMatching(song.artists.first ?? song.artist)
        let album = normalizeForMatching(song.album ?? "")

        let key = "\(title)|\(artist)|\(album)"
        metaGroups[key, default: []].append(song)
      }

      for (_, candidates) in metaGroups where candidates.count > 1 {
        // Further refine by duration tolerance (± 5 seconds)
        let refined = refineByDuration(candidates, tolerance: 5.0)
        for subgroup in refined where subgroup.count > 1 {
          groups.append(DuplicateGroup(songs: subgroup, reason: "Matching Metadata & Duration"))
          accountedForIds.formUnion(subgroup.map(\.id))
        }
      }

      // 3. Group by loose metadata (Title + Artist + Duration, ignoring Album)
      let looseRemaining = songs.filter { !accountedForIds.contains($0.id) }
      var looseGroups: [String: [LibrarySong]] = [:]

      for song in looseRemaining {
        let title = normalizeForMatching(song.title)
        let artist = normalizeForMatching(song.artists.first ?? song.artist)
        let key = "\(title)|\(artist)"
        looseGroups[key, default: []].append(song)
      }

      for (_, candidates) in looseGroups where candidates.count > 1 {
        // Use a stricter duration tolerance when album doesn't match (± 2 seconds)
        let refined = refineByDuration(candidates, tolerance: 2.0)
        for subgroup in refined where subgroup.count > 1 {
          groups.append(DuplicateGroup(songs: subgroup, reason: "Matching Title & Artist"))
          accountedForIds.formUnion(subgroup.map(\.id))
        }
      }

      return groups
    }
  }

  private func refineByDuration(_ songs: [LibrarySong], tolerance: TimeInterval) -> [[LibrarySong]]
  {
    var subgroups: [[LibrarySong]] = []
    for song in songs {
      var found = false
      for i in 0..<subgroups.count {
        if abs(subgroups[i][0].duration - song.duration) <= tolerance {
          subgroups[i].append(song)
          found = true
          break
        }
      }
      if !found {
        subgroups.append([song])
      }
    }
    return subgroups
  }

  /// Calculates a quality score for a song to determine which version to keep.
  func calculateQualityScore(for song: LibrarySong) -> Int {
    var score = 0

    // Format priority
    let format = song.format?.lowercased() ?? ""
    if format.contains("flac") {
      score += 1000
    } else if format.contains("alac") || format.contains("wav") || format.contains("aiff") {
      score += 800
    } else if format.contains("m4a") || format.contains("aac") {
      score += 600
    } else if format.contains("mp3") {
      score += 400
    }

    // Bitrate contribution (secondary)
    if let bitRate = song.bitRate {
      score += bitRate / 10  // e.g., 320kbps adds 32 points
    }

    // Sample rate and bit depth contribution
    if let sampleRate = song.sampleRate {
      score += Int(sampleRate / 1000)
    }
    if let bitDepth = song.bitDepth {
      score += bitDepth
    }

    // Metadata completeness
    if song.artworkPath != nil { score += 10 }
    if song.lyrics != nil { score += 5 }

    return score
  }

  /// Automatically merges duplicate songs if they match with high confidence.
  private func mergeSongDuplicates(in modelContext: ModelContext) async {
    let duplicateGroups = findDuplicates()
    guard !duplicateGroups.isEmpty else { return }

    print(
      "[DEBUG] SongLibrary.mergeSongDuplicates: Found \(duplicateGroups.count) duplicate groups")

    var deletedCount = 0
    for group in duplicateGroups {
      // Only auto-merge if identical hash or extremely high confidence metadata match
      // For metadata matches, we only auto-merge if both have the same album name (not "Unknown Album")
      let isHashMatch = group.reason == "Identical File Hash"
      let isHighConfMeta =
        group.reason == "Matching Metadata & Duration" && group.songs.first?.album != nil
        && group.songs.first?.album != "Unknown Album"

      guard isHashMatch || isHighConfMeta else { continue }

      // Keep the "best" song based on quality score
      let sortedGroup = group.songs.sorted { s1, s2 in
        let s1Score = calculateQualityScore(for: s1)
        let s2Score = calculateQualityScore(for: s2)
        if s1Score != s2Score { return s1Score > s2Score }
        return s1.importedDate < s2.importedDate  // Prefer older if scores are equal
      }

      let primary = sortedGroup[0]
      for duplicate in sortedGroup.dropFirst() {
        // Transfer playlist memberships
        if let playlists = duplicate.playlists {
          for playlist in playlists {
            if !(primary.playlists?.contains(playlist) ?? false) {
              primary.playlists?.append(playlist)
              if !(playlist.songs.contains(primary)) {
                playlist.songs.append(primary)
              }
            }
          }
        }

        // Delete file if it's in the managed directory and not referenced by others
        let url = getFileURL(for: duplicate)
        if duplicate.storageMode == .copied && FileManager.default.fileExists(atPath: url.path) {
          // Check if any other song uses this exact file path (rare but possible)
          let otherUsingFile = songs.contains {
            $0.id != duplicate.id && getFileURL(for: $0).path == url.path
          }
          if !otherUsingFile {
            try? FileManager.default.removeItem(at: url)
          }
        }

        modelContext.delete(duplicate)
        deletedCount += 1
      }
    }

    if deletedCount > 0 {
      try? modelContext.save()
      print("[DEBUG] SongLibrary.mergeSongDuplicates: Deleted \(deletedCount) duplicate songs")
    }
  }

  // MARK: - Artists

  /// Gets all unique artists from the library
  func allArtists() async -> [Artist] {
    guard let modelContext = modelContext else { return [] }

    do {
      let descriptor = FetchDescriptor<Artist>(
        sortBy: [SortDescriptor(\.name, order: .forward)]
      )
      let fetchedArtists = try modelContext.fetch(descriptor)

      if fetchedArtists.isEmpty && !songs.isEmpty {
        print(
          "[DEBUG] SongLibrary.allArtists: No artists in DB but songs exist. Reindexing artists.")
        return await reindexArtists()
      }

      return fetchedArtists
    } catch {
      print("[DEBUG] SongLibrary.allArtists: Error fetching artists: \(error)")
      return []
    }
  }

  /// Reindexes all artists from current songs and albums
  func reindexArtists() async -> [Artist] {
    print("[DEBUG] SongLibrary.reindexArtists: Starting full artist reindex")
    guard let modelContext = modelContext else { return [] }

    // Reset stats for all existing artists
    do {
      let descriptor = FetchDescriptor<Artist>()
      let existingArtists = try modelContext.fetch(descriptor)
      for artist in existingArtists {
        artist.songCount = 0
        artist.albumCount = 0
      }
    } catch {
      print("[DEBUG] SongLibrary.reindexArtists: Error resetting artists: \(error)")
    }

    var artistMap: [String: Artist] = [:]

    for song in songs {
      let artistNames = song.artists.isEmpty ? [song.artist] : song.artists

      for artistName in artistNames {
        let trimmedName = artistName.trimmingCharacters(in: .whitespaces)
        guard !trimmedName.isEmpty else { continue }

        let artist = getOrCreateArtist(named: trimmedName, in: modelContext)

        // Update statistics
        artist.songCount += 1
        if !artist.isDedicatedArtwork {
          artist.artworkPath = song.artworkPath
        }
        if song.importedDate > artist.lastAddedDate {
          artist.lastAddedDate = song.importedDate
        }
        if let genre = song.genre, !genre.isEmpty {
          if artist.genres == nil {
            artist.genres = [genre]
          } else if !(artist.genres?.contains(genre) ?? false) {
            artist.genres?.append(genre)
          }
        }
        artistMap[trimmedName] = artist
      }
    }

    // Count albums per artist
    for album in albums {
      let normalizedAlbumArtist = (album.artist ?? "").lowercased()
      if let artistKey = artistMap.keys.first(where: { $0.lowercased() == normalizedAlbumArtist }) {
        artistMap[artistKey]?.albumCount = (artistMap[artistKey]?.albumCount ?? 0) + 1
      }
    }

    saveContext()
    return Array(artistMap.values).sorted { $0.name < $1.name }
  }

  /// Gets or creates an artist by name
  private func getOrCreateArtist(named name: String, in modelContext: ModelContext) -> Artist {
    let trimmedName = name.trimmingCharacters(in: .whitespaces)

    do {
      var descriptor = FetchDescriptor<Artist>(
        predicate: #Predicate<Artist> { $0.name == trimmedName }
      )
      descriptor.fetchLimit = 1
      if let existing = try modelContext.fetch(descriptor).first {
        return existing
      }
    } catch {
      print("[DEBUG] SongLibrary.getOrCreateArtist: Error fetching: \(error)")
    }

    let newArtist = Artist(name: trimmedName)
    modelContext.insert(newArtist)
    return newArtist
  }

  /// Gets an artist by name from current memory list or DB
  func getArtist(named name: String) -> Artist? {
    let normalized = name.trimmingCharacters(in: .whitespaces).lowercased()

    // Check local memory first
    if let match = artists.first(where: { $0.name.lowercased() == normalized }) {
      return match
    }

    // Fallback to fetching from DB
    guard let modelContext = modelContext else { return nil }
    do {
      var descriptor = FetchDescriptor<Artist>(
        predicate: #Predicate<Artist> { $0.name.localizedStandardContains(name) }
      )
      descriptor.fetchLimit = 1
      return try modelContext.fetch(descriptor).first { $0.name.lowercased() == normalized }
    } catch {
      return nil
    }
  }

  /// Gets an album by name and canonical artist (album artist / Various Artists / track artist).
  func getAlbum(named name: String, artist artistName: String) -> Album? {
    let normalizedName = name.lowercased()
    let normalizedArtist = artistName.lowercased()

    // Check local memory first
    if let match = albums.first(where: {
      $0.name.lowercased() == normalizedName &&
      (($0.isCompilation ? "various artists" : ($0.artist ?? "").lowercased()) == normalizedArtist)
    }) {
      return match
    }

    // Fallback to fetching from DB
    guard let modelContext = modelContext else { return nil }
    do {
      var descriptor = FetchDescriptor<Album>(
        predicate: #Predicate<Album> {
          $0.name == name && $0.artist == artistName
        }
      )
      descriptor.fetchLimit = 1
      return try modelContext.fetch(descriptor).first
    } catch {
      return nil
    }
  }

  /// Gets all songs by a specific artist (including features)
  func getSongs(byArtist artistName: String) -> [LibrarySong] {
    let normalized = artistName.trimmingCharacters(in: .whitespaces).lowercased()
    return songs.filter { song in
      let artistNames = song.artists.isEmpty ? [song.artist] : song.artists
      return artistNames.contains { $0.lowercased() == normalized }
    }
  }

  // MARK: - Loading

  func loadSongs(force: Bool = false) async {
    if !force && isLoaded && !songs.isEmpty {
      print("[DEBUG] SongLibrary.loadSongs: Already loaded, skipping")
      return
    }
    
    print("[DEBUG] SongLibrary.loadSongs: Loading songs from database")
    guard let modelContext = modelContext else {
      print("[DEBUG] SongLibrary.loadSongs: Error - No modelContext")
      return
    }

    do {
      let descriptor = FetchDescriptor<LibrarySong>(
        sortBy: [SortDescriptor(\.importedDate, order: .reverse)]
      )
      songs = try modelContext.fetch(descriptor)
      print("[DEBUG] SongLibrary.loadSongs: Fetched \(songs.count) songs")

      // Merge duplicate songs if setting is enabled
      let appSettings = AppSettings.getOrCreate(in: modelContext)
      if appSettings.mergeSongDuplicates {
        print("[DEBUG] SongLibrary.loadSongs: Merging duplicate songs")
        await mergeSongDuplicates(in: modelContext)
        // Refresh songs after merge
        songs = try modelContext.fetch(descriptor)
      }
      
      isLoaded = true
      notifyLibraryChange()
    } catch {
      print("[DEBUG] SongLibrary.loadSongs: Error fetching songs: \(error)")
      songs = []
    }

    await loadAlbums()
    artists = await allArtists()
    print("[DEBUG] SongLibrary.loadSongs: Finished loading songs, albums, and artists")
  }

  private func loadAlbums() async {
    print("[DEBUG] SongLibrary.loadAlbums: Loading albums from database")
    guard let modelContext = modelContext else {
      print("[DEBUG] SongLibrary.loadAlbums: Error - No modelContext")
      return
    }

    do {
      let descriptor = FetchDescriptor<Album>(
        sortBy: [SortDescriptor(\.name, order: .forward)]
      )
      albums = try modelContext.fetch(descriptor)
      print("[DEBUG] SongLibrary.loadAlbums: Fetched \(albums.count) albums")

      // Always merge duplicate albums to fix any historical splits caused by
      // track-artist variations (e.g. "NF; mgk" vs "NF").
      print("[DEBUG] SongLibrary.loadAlbums: Merging duplicate albums")
      await mergeAlbumDuplicates(in: modelContext)
    } catch {
      print("[DEBUG] SongLibrary.loadAlbums: Error fetching albums: \(error)")
      albums = []
    }
  }

  // MARK: - Indexing

  private var isIndexing = false

  func indexOnStartup() async {
    guard !isIndexing else {
      print("[DEBUG] indexOnStartup - already indexing, skipping")
      return
    }
    isIndexing = true

    print("[DEBUG] indexOnStartup started on thread: \(Thread.current.name)")
    guard let modelContext = modelContext else {
      print("[DEBUG] indexOnStartup - no modelContext")
      isIndexing = false
      return
    }

    // 0. Smart Scan Check
    let fm = FileManager.default
    let lastScanTime = UserDefaults.standard.double(forKey: "com.ampwave.lastDiskScanTime")
    let songsDir = self.songsDirectory
    
    if let attributes = try? fm.attributesOfItem(atPath: songsDir.path),
       let modDate = attributes[.modificationDate] as? Date {
      
      let lastScanDate = Date(timeIntervalSince1970: lastScanTime)
      if modDate < lastScanDate {
        print("[DEBUG] indexOnStartup: Directory hasn't changed since last scan (\(lastScanDate)). Skipping scan.")
        await repairStoredFilePathsIfNeeded(in: modelContext)
        indexingStatus = .complete
        isIndexing = false
        // Still run metadata backfill check just in case
        await fetchMetadataForNewSongs()
        return
      }
    }

    indexingStatus = .indexing("Scanning…")

    // 1. Scan disk in background
    let audioURLs = await Task.detached(priority: .userInitiated) {
      self.findAudioFiles(in: songsDir)
    }.value

    print("[DEBUG] Found \(audioURLs.count) audio files on disk")

    // 2. Fetch existing songs from database (MainActor)
    let descriptor = FetchDescriptor<LibrarySong>()
    let existingSongs = (try? modelContext.fetch(descriptor)) ?? []
    print("[DEBUG] Found \(existingSongs.count) existing songs in database")

    // Safety check: If we found no files on disk but have many in DB, 
    // it's likely a mount/permission issue or folder was moved. Don't mass delete.
    if audioURLs.isEmpty && existingSongs.count > 0 {
      print("[DEBUG] indexOnStartup: Safety triggered. Found 0 files on disk but \(existingSongs.count) in DB. Aborting sync to prevent accidental deletion.")
      indexingStatus = .complete
      isIndexing = false
      return
    }

    // 3. Process changes
    let audioPathSet = Set(audioURLs.map { $0.standardizedFileURL.path })
    var fileNameToURLs: [String: [URL]] = [:]
    for url in audioURLs {
      fileNameToURLs[url.lastPathComponent, default: []].append(url)
    }

    var accountedForPaths = Set<String>()
    var deletedSongs: [LibrarySong] = []

    for song in existingSongs {
      // REFERENCED SONGS: We don't delete these automatically in the startup scan.
      // Bookmark resolution and permission issues make automatic deletion too risky.
      if song.storageMode == .referenced {
        let url = getFileURL(for: song)
        let secured = url.startAccessingSecurityScopedResource()
        let exists = FileManager.default.fileExists(atPath: url.path)
        if secured { url.stopAccessingSecurityScopedResource() }
        
        if !exists {
          print("[DEBUG] indexOnStartup: Referenced song file not accessible/missing: \(song.title)")
          // We still don't delete it automatically, just log it.
        }
        continue
      }

      // COPIED SONGS: Check if they still exist in our managed directory
      let expectedURL = getFileURL(for: song).standardizedFileURL
      let expectedPath = expectedURL.path

      if audioPathSet.contains(expectedPath) {
        updateStoredFilePath(for: song, to: expectedURL)
        accountedForPaths.insert(expectedPath)
        continue
      }

      // File is NOT at expected location. Check if it moved within our directory.
      var foundMoved = false
      if let possibleURLs = fileNameToURLs[song.fileName] {
        for possibleURL in possibleURLs {
          if await self.fileHash(at: possibleURL) == song.fileHash {
            // Found it at a new path in our directory - update it
            print("[DEBUG] indexOnStartup: Found moved file for \(song.title) at \(possibleURL.lastPathComponent)")
            // We don't move it back here (to avoid disk churn), just store the actual path.
            updateStoredFilePath(for: song, to: possibleURL)
            accountedForPaths.insert(possibleURL.standardizedFileURL.path)
            foundMoved = true
            break
          }
        }
      }

      if !foundMoved {
        // Only mark for deletion if we are reasonably sure it's gone from our managed folder
        print("[DEBUG] indexOnStartup: Marking copied song for deletion (not found on disk): \(song.title)")
        deletedSongs.append(song)
      }
    }

    // Batch delete
    if !deletedSongs.isEmpty {
      print("[DEBUG] indexOnStartup: Deleting \(deletedSongs.count) missing songs")
      for song in deletedSongs {
        modelContext.delete(song)
      }
    }

    // 4. Import new files
    modelContext.processPendingChanges()
    let finalExistingHashes = Set(
      ((try? modelContext.fetch(FetchDescriptor<LibrarySong>())) ?? []).map(\.fileHash))

    var newFiles: [URL] = []
    for url in audioURLs {
      let standardizedPath = url.standardizedFileURL.path
      if accountedForPaths.contains(standardizedPath) { continue }
      newFiles.append(url)
    }

    if !newFiles.isEmpty {
      indexingStatus = .indexing("Importing \(newFiles.count) new songs…")
      for url in newFiles {
        guard let hash = await self.fileHash(at: url) else { continue }
        if !finalExistingHashes.contains(hash) {
          _ = await importFileInPlace(at: url, modelContext: modelContext)
        }
      }
    }

    saveContext()
    await pruneEmptyAlbums()
    await reindexMissingTechnicalMetadata()
    await loadSongs()

    indexingStatus = .complete
    isIndexing = false
    
    // 5. Update last scan time
    UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: "com.ampwave.lastDiskScanTime")
    
    // 6. Check for missing metadata
    await fetchMetadataForNewSongs()
  }

  private func repairStoredFilePathsIfNeeded(in modelContext: ModelContext) async {
    let descriptor = FetchDescriptor<LibrarySong>()
    let existingSongs = (try? modelContext.fetch(descriptor)) ?? []
    let copiedSongsNeedingRepair = existingSongs.filter { song in
      guard song.storageMode == .copied else { return false }

      guard let storedURL = resolvedStoredFileURL(for: song) else { return true }
      return !fileManager.fileExists(atPath: storedURL.path)
    }

    guard !copiedSongsNeedingRepair.isEmpty else { return }

    print(
      "[DEBUG] SongLibrary.repairStoredFilePathsIfNeeded: Checking \(copiedSongsNeedingRepair.count) copied songs"
    )

    let audioURLs = await Task.detached(priority: .utility) {
      self.findAudioFiles(in: self.songsDirectory)
    }.value

    var fileNameToURLs: [String: [URL]] = [:]
    for url in audioURLs {
      fileNameToURLs[url.lastPathComponent, default: []].append(url)
    }

    var repairedCount = 0
    for song in copiedSongsNeedingRepair {
      let legacyURL = legacyMetadataFileURL(for: song)
      if fileManager.fileExists(atPath: legacyURL.path) {
        if updateStoredFilePath(for: song, to: legacyURL) {
          repairedCount += 1
        }
        continue
      }

      guard let candidates = fileNameToURLs[song.fileName] else { continue }
      for candidate in candidates {
        if await fileHash(at: candidate) == song.fileHash {
          if updateStoredFilePath(for: song, to: candidate) {
            repairedCount += 1
          }
          break
        }
      }
    }

    if repairedCount > 0 {
      print(
        "[DEBUG] SongLibrary.repairStoredFilePathsIfNeeded: Repaired \(repairedCount) stored file paths"
      )
      try? modelContext.save()
    }
  }

  /// Removes albums that have no songs associated with them
  private func pruneEmptyAlbums() async {
    guard let modelContext = modelContext else { return }
    print("[DEBUG] SongLibrary.pruneEmptyAlbums: Checking for empty albums")
    
    do {
      let descriptor = FetchDescriptor<Album>()
      let allAlbums = try modelContext.fetch(descriptor)
      
      var prunedCount = 0
      for album in allAlbums {
        if album.songs.isEmpty {
          modelContext.delete(album)
          prunedCount += 1
        }
      }
      
      if prunedCount > 0 {
        print("[DEBUG] SongLibrary.pruneEmptyAlbums: Deleted \(prunedCount) empty albums")
        saveContext()
      }
    } catch {
      print("[DEBUG] SongLibrary.pruneEmptyAlbums: Error: \(error)")
    }
  }

  nonisolated private func findAudioFiles(in directory: URL, currentDepth: Int = 0) -> [URL] {
    var audioFiles: [URL] = []
    let maxDepth = 5

    guard currentDepth <= maxDepth else { return [] }

    let fm = FileManager.default
    guard
      let contents = try? fm.contentsOfDirectory(
        at: directory,
        includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey],
        options: .skipsHiddenFiles
      )
    else { return [] }

    for url in contents {
      var isDir: ObjCBool = false
      if fm.fileExists(atPath: url.path, isDirectory: &isDir) {
        if isDir.boolValue {
          audioFiles.append(contentsOf: findAudioFiles(in: url, currentDepth: currentDepth + 1))
        } else {
          let ext = url.pathExtension.lowercased()
          if SongLibrary.audioExtensions.contains(ext) {
            audioFiles.append(url)
          }
        }
      }
    }

    return audioFiles
  }

  nonisolated private func fileHash(at url: URL) async -> String? {
    do {
      let handle = try FileHandle(forReadingFrom: url)
      defer { try? handle.close() }

      var hasher = SHA256()
      while true {
        let data = try autoreleasepool {
          try handle.read(upToCount: 65536)
        }
        guard let data = data, !data.isEmpty else { break }
        hasher.update(data: data)
      }

      let hash = hasher.finalize()
      return hash.compactMap { String(format: "%02x", $0) }.joined()
    } catch {
      print("Failed to calculate hash: \(error)")
      return nil
    }
  }

  // MARK: - Import

  func importFiles(_ urls: [URL]) async {
    print("[DEBUG] SongLibrary.importFiles: Starting import of \(urls.count) files")
    guard let modelContext = modelContext else {
      print("[DEBUG] SongLibrary.importFiles: Error - No modelContext")
      return
    }

    indexingStatus = .indexing("Importing \(urls.count) songs…")
    defer {
      print("[DEBUG] SongLibrary.importFiles: Import finished")
      indexingStatus = .complete
    }

    let settings = AppSettings.getOrCreate(in: modelContext)
    let groupByAlbum = settings.groupSongsByAlbum

    var importedCount = 0
    let totalCount = urls.count

    for (index, url) in urls.enumerated() {
      // Update status every file for better feedback
      print(
        "[DEBUG] SongLibrary.importFiles: Processing file \(index + 1)/\(totalCount): \(url.lastPathComponent)"
      )
      indexingStatus = .indexing("Importing \(index + 1)/\(totalCount)…")

      if await importFile(
        from: url, modelContext: modelContext, groupByAlbum: groupByAlbum) != nil
      {
        importedCount += 1
        print("[DEBUG] SongLibrary.importFiles: Successfully imported \(url.lastPathComponent)")
      } else {
        print("[DEBUG] SongLibrary.importFiles: Failed or skipped \(url.lastPathComponent)")
      }

      // Save periodically for large imports
      if importedCount % 5 == 0 && importedCount > 0 {
        print("[DEBUG] SongLibrary.importFiles: Periodic save (count: \(importedCount))")
        saveContext()
        // Process changes to help clear memory and let system catch up
        modelContext.processPendingChanges()
        try? await Task.sleep(nanoseconds: 100_000_000)  // 0.1s to allow system cleanup
      }
    }

    if importedCount > 0 {
      print("[DEBUG] SongLibrary.importFiles: Final save and reloading library")
      saveContext()
      // force: true bypasses the isLoaded guard so subsequent imports
      // (e.g. file import after a folder import) always refresh the UI.
      await loadSongs(force: true)

      // Start background metadata fetch for everything imported
      Task {
        await fetchMetadataForNewSongs()
      }
    }
    print(
      "[DEBUG] SongLibrary.importFiles: Completed. Imported \(importedCount)/\(totalCount) files")
  }

  private func importFile(from url: URL, modelContext: ModelContext, groupByAlbum: Bool) async
    -> LibrarySong?
  {
    print("[DEBUG] SongLibrary.importFile: Starting for \(url.lastPathComponent)")
    // Start accessing the security-scoped resource
    let secured = url.startAccessingSecurityScopedResource()
    defer {
      if secured {
        url.stopAccessingSecurityScopedResource()
      }
    }

    // Calculate hash first to check if it already exists
    print("[DEBUG] SongLibrary.importFile: Calculating hash for \(url.lastPathComponent)")
    guard let fileHash = await self.fileHash(at: url) else {
      print("[DEBUG] SongLibrary.importFile: Failed to calculate hash for \(url.lastPathComponent)")
      return nil
    }

    // Perform SwiftData operations on Main Actor
    print("[DEBUG] SongLibrary.importFile: Checking for existing song with hash: \(fileHash)")
    var songToRepair: LibrarySong?
    do {
      var descriptor = FetchDescriptor<LibrarySong>(
        predicate: #Predicate<LibrarySong> { $0.fileHash == fileHash }
      )
      descriptor.fetchLimit = 1
      if let existingSong = try modelContext.fetch(descriptor).first {
        let existingURL = getFileURL(for: existingSong)
        if fileManager.fileExists(atPath: existingURL.path) {
          print(
            "[DEBUG] SongLibrary.importFile: Song already exists in library (hash: \(fileHash))"
          )
          return nil
        } else {
          print(
            "[DEBUG] SongLibrary.importFile: Reusing stale record for missing file: \(existingURL.path)"
          )
          songToRepair = existingSong
        }
      }
    } catch {
      print("[DEBUG] SongLibrary.importFile: Error checking for existing song: \(error)")
    }

    // Offload remaining heavy I/O to a background task
    print("[DEBUG] SongLibrary.importFile: Offloading remaining I/O to background task")
    let preferences = UserPreferences.getOrCreate(in: modelContext)
    let shouldCopy = preferences.copyMusicToStorage

    let ioResult = await Task.detached(priority: .userInitiated) {
      // Extract metadata (this also does I/O)
      print(
        "[DEBUG] SongLibrary.importFile.detached: Extracting metadata for \(url.lastPathComponent)")
      let metadata = await AudioMetadataExtractor.extract(from: url)

      let fileSize = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0

      if shouldCopy {
        // Prepare destination
        let fileName = self.generateFileName(
          artist: metadata.artist,
          title: metadata.title,
          trackNumber: metadata.trackNumber,
          originalExtension: url.pathExtension
        )

        let albumDir = self.getAlbumDirectory(
          album: metadata.album, artist: metadata.artist, groupByAlbum: groupByAlbum)

        // Create directory on background
        print("[DEBUG] SongLibrary.importFile.detached: Creating directory \(albumDir.path)")
        try? FileManager.default.createDirectory(at: albumDir, withIntermediateDirectories: true)

        let uniqueFileName = self.getUniqueFileName(baseName: fileName, in: albumDir)
        let destinationURL = albumDir.appendingPathComponent(uniqueFileName)

        // Copy file on background
        print("[DEBUG] SongLibrary.importFile.detached: Copying file to \(destinationURL.path)")
        do {
          if FileManager.default.fileExists(atPath: destinationURL.path) {
            try FileManager.default.removeItem(at: destinationURL)
          }
          try FileManager.default.copyItem(at: url, to: destinationURL)
        } catch {
          print("[DEBUG] SongLibrary.importFile.detached: Failed to copy file: \(error)")
          return nil as (ExtractedAudioMetadata, URL, Int, LibrarySong.StorageMode, Data?)?
        }
        print("[DEBUG] SongLibrary.importFile.detached: I/O completed for \(url.lastPathComponent)")
        return (metadata, destinationURL, fileSize, LibrarySong.StorageMode.copied, nil)
      } else {
        // Referenced mode
        print(
          "[DEBUG] SongLibrary.importFile.detached: Using referenced mode for \(url.lastPathComponent)"
        )
        let bookmark = PathManager.createBookmark(for: url)
        return (metadata, url, fileSize, LibrarySong.StorageMode.referenced, bookmark)
      }
    }.value

    guard let (metadata, destinationURL, fileSize, storageMode, bookmarkData) = ioResult else {
      print("[DEBUG] SongLibrary.importFile: I/O task failed for \(url.lastPathComponent)")
      return nil
    }

    let uniqueFileName = destinationURL.lastPathComponent

    // Check for companion .lrc file in the source location
    var songLyrics = metadata.lyrics
    let lrcURL = url.deletingPathExtension().appendingPathExtension("lrc")
    if FileManager.default.fileExists(atPath: lrcURL.path) {
      if let lrcContent = try? String(contentsOf: lrcURL, encoding: .utf8) {
        songLyrics = lrcContent

        if storageMode == .copied {
          // Optionally copy the .lrc file to destination too
          let destLrcURL = destinationURL.deletingPathExtension().appendingPathExtension("lrc")
          try? FileManager.default.copyItem(at: lrcURL, to: destLrcURL)
        }
      }
    }

    if let songToRepair {
      print("[DEBUG] SongLibrary.importFile: Repairing existing LibrarySong storage")
      // Preserve identity and user state; only replace fields that locate the audio file.
      songToRepair.fileName = uniqueFileName
      updateStoredFilePath(for: songToRepair, to: destinationURL)
      songToRepair.fileHash = fileHash
      songToRepair.size = fileSize
      songToRepair.storageMode = storageMode
      songToRepair.bookmarkData = bookmarkData
      print("[DEBUG] SongLibrary.importFile: Repaired existing LibrarySong \(songToRepair.id)")
      return songToRepair
    }

    // Cache artwork only when creating a new model.
    print("[DEBUG] SongLibrary.importFile: Caching artwork")
    let artworkPath: String?
    if let data = metadata.artwork {
      artworkPath = await cacheArtwork(data)
    } else {
      artworkPath = nil
    }

    print("[DEBUG] SongLibrary.importFile: Creating LibrarySong object")
    let song = LibrarySong(
      title: metadata.title,
      artist: metadata.artist,
      fileName: uniqueFileName,
      filePath: PathManager.relativePath(from: destinationURL.path),
      fileHash: fileHash,
      size: fileSize,
      duration: metadata.duration,
      lyrics: songLyrics,
      album: metadata.album,
      albumArtist: metadata.albumArtist,
      genre: metadata.genre,
      songDescription: metadata.songDescription,
      trackNumber: metadata.trackNumber,
      discNumber: metadata.discNumber,
      year: metadata.year,
      composer: metadata.composer,
      artworkPath: artworkPath,
      embeddedArtworkPath: artworkPath,
      sampleRate: metadata.sampleRate,
      bitDepth: metadata.bitDepth,
      bitRate: metadata.bitRate,
      channels: metadata.channels,
      format: metadata.format,
      storageMode: storageMode,
      bookmarkData: bookmarkData,
      titleConfidence: metadata.titleConfidence,
      artistConfidence: metadata.artistConfidence,
      albumConfidence: metadata.albumConfidence,
      metadataSourceTitle: metadata.metadataSourceTitle,
      metadataSourceArtist: metadata.metadataSourceArtist,
      metadataSourceAlbum: metadata.metadataSourceAlbum,
      isLive: metadata.isLive,
      isMedley: metadata.isMedley
    )

    // Set initial artwork source
    if artworkPath != nil {
      song.artworkSource = .embedded
    }

    song.updateSearchIndex()

    print("[DEBUG] SongLibrary.importFile: Inserting song into modelContext")
    modelContext.insert(song)

    // Save lyrics to SyncedLyric if it's LRC format
    if let lyrics = songLyrics {
      LyricsService.shared.saveLyrics(for: song, content: lyrics)
    }

    // Link to album and artist
    print("[DEBUG] SongLibrary.importFile: Linking to album and artist")
    let artistNames = ArtistParser.parseArtists(from: metadata.albumArtist ?? metadata.artist)
    let primaryArtistName = artistNames.first ?? (metadata.albumArtist ?? metadata.artist)

    let artist = getOrCreateArtist(named: primaryArtistName, in: modelContext)
    artist.songCount += 1
    if !artist.isDedicatedArtwork { artist.artworkPath = artworkPath }
    if let genre = metadata.genre, !genre.isEmpty {
      if artist.genres == nil {
        artist.genres = [genre]
      } else if !(artist.genres?.contains(genre) ?? false) {
        artist.genres?.append(genre)
      }
    }

    if let album = getOrCreateAlbum(
      name: metadata.album,
      albumArtist: metadata.albumArtist,
      trackArtist: metadata.artist,
      isCompilation: metadata.isCompilation,
      year: metadata.year,
      artworkPath: artworkPath,
      embeddedArtworkPath: artworkPath,
      in: modelContext
    ) {
      song.albumReference = album
      album.songs.append(song)
      if album.songs.count == 1 { artist.albumCount += 1 }
    }

    print("[DEBUG] SongLibrary.importFile: Finished successfully for \(url.lastPathComponent)")
    return song
  }

  private func importFileInPlace(at url: URL, modelContext: ModelContext) async -> LibrarySong? {
    let fileName = url.lastPathComponent

    guard let fileHash = await fileHash(at: url) else { return nil }
    let fileSize = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0

    // Skip if already in library
    do {
      var descriptor = FetchDescriptor<LibrarySong>(
        predicate: #Predicate<LibrarySong> { $0.fileHash == fileHash }
      )
      descriptor.fetchLimit = 1
      let count = try modelContext.fetchCount(descriptor)
      if count > 0 { return nil }
    } catch {
      return nil
    }

    let metadata = await AudioMetadataExtractor.extract(from: url)

    // Check for companion .lrc file
    var songLyrics = metadata.lyrics
    let lrcURL = url.deletingPathExtension().appendingPathExtension("lrc")
    if fileManager.fileExists(atPath: lrcURL.path) {
      if let lrcContent = try? String(contentsOf: lrcURL, encoding: .utf8) {
        songLyrics = lrcContent
      }
    }

    let artworkPath: String? = await {
      if let data = metadata.artwork {
        return await cacheArtwork(data)
      } else {
        return nil
      }
    }()

    // For in-place indexing (e.g. startup scan of Songs/ folder), it's always .copied
    // because it's already in the app's managed directory.
    // However, if we're importing from elsewhere via Files app, it follows the setting.
    // This method is primarily used by indexOnStartup which scans self.songsDirectory.
    let isAlreadyInLibraryDir = url.path.hasPrefix(songsDirectory.path)
    let storageMode: LibrarySong.StorageMode =
      isAlreadyInLibraryDir ? LibrarySong.StorageMode.copied : LibrarySong.StorageMode.referenced
    let bookmarkData = isAlreadyInLibraryDir ? nil : PathManager.createBookmark(for: url)

    let song = LibrarySong(
      title: metadata.title,
      artist: metadata.artist,
      fileName: fileName,
      filePath: PathManager.relativePath(from: url.path),
      fileHash: fileHash,
      size: fileSize,
      duration: metadata.duration,
      lyrics: songLyrics,
      album: metadata.album,
      albumArtist: metadata.albumArtist,
      genre: metadata.genre,
      songDescription: metadata.songDescription,
      trackNumber: metadata.trackNumber,
      discNumber: metadata.discNumber,
      year: metadata.year,
      composer: metadata.composer,
      artworkPath: artworkPath,
      embeddedArtworkPath: artworkPath,
      sampleRate: metadata.sampleRate,
      bitDepth: metadata.bitDepth,
      bitRate: metadata.bitRate,
      channels: metadata.channels,
      format: metadata.format,
      storageMode: storageMode,
      bookmarkData: bookmarkData,
      titleConfidence: metadata.titleConfidence,
      artistConfidence: metadata.artistConfidence,
      albumConfidence: metadata.albumConfidence,
      metadataSourceTitle: metadata.metadataSourceTitle,
      metadataSourceArtist: metadata.metadataSourceArtist,
      metadataSourceAlbum: metadata.metadataSourceAlbum,
      isLive: metadata.isLive,
      isMedley: metadata.isMedley
    )

    // Set initial artwork source
    if artworkPath != nil {
      song.artworkSource = .embedded
    }

    song.updateSearchIndex()

    modelContext.insert(song)

    // Save lyrics to SyncedLyric if it's LRC format
    if let lyrics = songLyrics {
      LyricsService.shared.saveLyrics(for: song, content: lyrics)
    }

    // Link to album and artist
    let artistNames = ArtistParser.parseArtists(from: metadata.albumArtist ?? metadata.artist)
    let primaryArtistName = artistNames.first ?? (metadata.albumArtist ?? metadata.artist)

    let artist = getOrCreateArtist(named: primaryArtistName, in: modelContext)
    artist.songCount += 1
    if !artist.isDedicatedArtwork { artist.artworkPath = artworkPath }
    if let genre = metadata.genre, !genre.isEmpty {
      if artist.genres == nil {
        artist.genres = [genre]
      } else if !(artist.genres?.contains(genre) ?? false) {
        artist.genres?.append(genre)
      }
    }

    if let album = getOrCreateAlbum(
      name: metadata.album,
      albumArtist: metadata.albumArtist,
      trackArtist: metadata.artist,
      isCompilation: metadata.isCompilation,
      year: metadata.year,
      artworkPath: artworkPath,
      embeddedArtworkPath: artworkPath,
      in: modelContext
    ) {
      song.albumReference = album
      album.songs.append(song)
      if album.songs.count == 1 { artist.albumCount += 1 }
    }

    return song
  }

  // MARK: - Reindexing

  func reindexMissingTechnicalMetadata() async {
    print(
      "[DEBUG] SongLibrary.reindexMissingTechnicalMetadata: Checking for songs with missing metadata"
    )
    guard let modelContext = modelContext else { return }

    // Fetch songs where format or sampleRate is nil
    let descriptor = FetchDescriptor<LibrarySong>(
      predicate: #Predicate<LibrarySong> { $0.format == nil || $0.sampleRate == nil }
    )

    do {
      let missingSongs = try modelContext.fetch(descriptor)
      if missingSongs.isEmpty {
        print("[DEBUG] SongLibrary.reindexMissingTechnicalMetadata: No songs missing metadata")
        return
      }

      print(
        "[DEBUG] SongLibrary.reindexMissingTechnicalMetadata: Found \(missingSongs.count) songs missing metadata"
      )
      indexingStatus = .indexing("Updating metadata…")

      for (index, song) in missingSongs.enumerated() {
        let url = getFileURL(for: song)
        if fileManager.fileExists(atPath: url.path) {
          let metadata = await AudioMetadataExtractor.extract(from: url)
          song.sampleRate = metadata.sampleRate
          song.bitDepth = metadata.bitDepth
          song.bitRate = metadata.bitRate
          song.channels = metadata.channels
          song.format = metadata.format
          
          song.titleConfidence = metadata.titleConfidence
          song.artistConfidence = metadata.artistConfidence
          song.albumConfidence = metadata.albumConfidence
          song.metadataSourceTitle = metadata.metadataSourceTitle
          song.metadataSourceArtist = metadata.metadataSourceArtist
          song.metadataSourceAlbum = metadata.metadataSourceAlbum
          song.isLive = metadata.isLive
          song.isMedley = metadata.isMedley
        }

        if index % 10 == 0 {
          saveContext()
          indexingStatus = .indexing("Updating metadata (\(index + 1)/\(missingSongs.count))…")
        }
      }

      saveContext()
      await loadSongs()
      indexingStatus = .complete
    } catch {
      print("[DEBUG] SongLibrary.reindexMissingTechnicalMetadata: Error: \(error)")
    }
  }

  private func updateIndexingStatusForMetadata() {
    // Don't update status during genre backfill to avoid interference
    if isGenreBackfillActive { return }

    if pendingMetadataFetches > 0 {
      // Only set to fetchingMetadata if not already indexing something else (like file import)
      switch indexingStatus {
      case .idle, .complete, .fetchingMetadata:
        let total = max(totalMetadataFetches, pendingMetadataFetches)
        let current = total - pendingMetadataFetches
        Task { @MainActor in
          indexingStatus = .fetchingMetadata(current: current, total: total)
        }
      default:
        break
      }
    } else if case .fetchingMetadata = indexingStatus {
      Task { @MainActor in
        indexingStatus = .complete
      }
      totalMetadataFetches = 0
    }
  }

  // MARK: - Metadata Fetching from API

  private func fetchMetadataForSong(_ song: LibrarySong, isPartOfBatch: Bool = false) async {
    print("[DEBUG] SongLibrary.fetchMetadataForSong: Starting for \(song.title)")
    guard let modelContext = modelContext else {
      print("[DEBUG] SongLibrary.fetchMetadataForSong: Error - No modelContext")
      return
    }

    let preferences = UserPreferences.getOrCreate(in: modelContext)

    // 0. Genre tags when full metadata already ran but genre is still empty
    if preferences.autoFetchMetadata && !preferences.isOfflineMode && NetworkMonitor.shared.isOnline
      && song.metadataCheckAttempted
      && (song.genre == nil || song.genre?.isEmpty == true)
    {
      let metadataService = MetadataService.shared
      if metadataService.modelContext == nil {
        metadataService.setModelContext(modelContext)
      }
      if let genre = await metadataService.fetchGenreTags(for: song), !genre.isEmpty {
        await MainActor.run {
          song.genre = genre
          try? modelContext.save()
        }
      }
    }

    // 1. Online Metadata & Artwork
    let isGenericAlbum =
      song.album == nil || song.album == "Unknown Album" || song.album?.isEmpty == true
    let isGenericArtist = song.artist == "Unknown Artist" || song.artist.isEmpty
    let isMissingKeyInfo =
      song.genre == nil || song.genre?.isEmpty == true || song.year == nil || song.year == 0

    let needsMetadata =
      song.artworkPath == nil || isGenericAlbum || isGenericArtist || isMissingKeyInfo

    if preferences.autoFetchMetadata && needsMetadata && NetworkMonitor.shared.isOnline && !preferences.isOfflineMode {
      // Only increment if not already part of a batch fetch
      if !isPartOfBatch && totalMetadataFetches <= 1 {
        totalMetadataFetches = 1
        pendingMetadataFetches += 1
      }

      // Mark as attempted early to prevent race conditions or repeats on restart
      // (This is redundant if called from fetchMetadataForNewSongs, but good for direct calls)
      song.metadataCheckAttempted = true
      
      let metadataService = MetadataService.shared
      if metadataService.modelContext == nil {
        metadataService.setModelContext(modelContext)
      }

      print("[DEBUG] SongLibrary.fetchMetadataForSong: Calling MetadataService.fetchMetadata")
      if let metadata = await metadataService.fetchMetadata(for: song) {
        // Apply fetched metadata (on MainActor)
        print("[DEBUG] SongLibrary.fetchMetadataForSong: Metadata fetched, applying to song")
        await applyFetchedMetadata(metadata, to: song, preferences: preferences)
        song.metadataFetchSucceeded = true
      } else {
        // API returned nothing — mark succeeded so we don't retry on every launch
        // for songs that genuinely have no match in any source.
        print("[DEBUG] SongLibrary.fetchMetadataForSong: No metadata found for \(song.title)")
        song.metadataFetchSucceeded = true
      }
      
      if !isPartOfBatch {
        pendingMetadataFetches -= 1
        saveContext()
      }
    }

    // 2. Synced Lyrics
    // Fetch if no synced lyrics AND we haven't already tried.
    let hasSyncedLyrics = !LRCParser.parse(song.lyrics ?? "").isEmpty
    if preferences.autoFetchLyrics && !hasSyncedLyrics && !song.lyricsCheckAttempted && NetworkMonitor.shared.isOnline && !preferences.isOfflineMode {
      print(
        "[DEBUG] SongLibrary.fetchMetadataForSong: Missing synced lyrics, calling LyricsService")

      // Mark as attempted even before the call to prevent parallel re-triggers
      song.lyricsCheckAttempted = true
      saveContext()

      let lyricsService = LyricsService.shared
      if lyricsService.modelContext == nil {
        lyricsService.setModelContext(modelContext)
      }
      _ = await lyricsService.fetchLyrics(for: song)
    }
  }

  func fetchMetadataForNewSongs() async {
    print("[DEBUG] SongLibrary.fetchMetadataForNewSongs: Starting batch fetch")
    guard let modelContext = modelContext else { return }

    let preferences = UserPreferences.getOrCreate(in: modelContext)
    
    // Safety: Skip if offline or auto-fetch is disabled
    guard preferences.autoFetchMetadata else {
      print("[DEBUG] SongLibrary.fetchMetadataForNewSongs: Auto-fetch disabled, skipping")
      return
    }
    
    if !NetworkMonitor.shared.isOnline || preferences.isOfflineMode {
      print("[DEBUG] SongLibrary.fetchMetadataForNewSongs: Offline, skipping online fetch")
      return
    }

    // Simplify predicate to avoid compiler timeout.
    let descriptor = FetchDescriptor<LibrarySong>(
      predicate: #Predicate<LibrarySong> { song in
        song.metadataCheckAttempted == false
      }
    )

    do {
      let uncheckedSongs = try modelContext.fetch(descriptor)
      let songsToFetch = uncheckedSongs.filter { song in
        let isEssentialMissing = song.title.contains("Untitled") || song.artist == "Unknown Artist" || song.artist.isEmpty
        let isSecondaryMissing = song.artworkPath == nil
          || song.genre == nil || song.genre?.isEmpty == true
          || song.year == nil
          || song.composer == nil
          || song.trackNumber == nil
          || song.albumArtist == nil || song.albumArtist?.isEmpty == true
        return isEssentialMissing || isSecondaryMissing
      }

      if songsToFetch.isEmpty {
        print("[DEBUG] SongLibrary.fetchMetadataForNewSongs: No songs needing metadata fetch")
        pendingMetadataFetches = 0
        totalMetadataFetches = 0
        return
      }

      print(
        "[DEBUG] SongLibrary.fetchMetadataForNewSongs: Fetching for \(songsToFetch.count) songs")

      totalMetadataFetches = songsToFetch.count
      pendingMetadataFetches = songsToFetch.count

      for song in songsToFetch {
        // Double check if context is still valid
        guard self.modelContext != nil else { break }
        
        // Mark as attempted BEFORE the call to prevent infinite loops if it crashes or fails
        song.metadataCheckAttempted = true
        
        await fetchMetadataForSong(song, isPartOfBatch: true)

        // Decrement here to ensure it happens regardless of what fetchMetadataForSong does
        pendingMetadataFetches -= 1

        // Smaller pause
        try? await Task.sleep(nanoseconds: 50_000_000)  // 0.05s
      }

      // Ensure we hit zero at the end
      pendingMetadataFetches = 0
      totalMetadataFetches = 0
      saveContext()

      print("[DEBUG] SongLibrary.fetchMetadataForNewSongs: Finished batch fetch")
    } catch {
      print("[DEBUG] SongLibrary.fetchMetadataForNewSongs: Error: \(error)")
      pendingMetadataFetches = 0
      totalMetadataFetches = 0
    }
  }

  func refreshAllMetadata() async {
    print("[DEBUG] SongLibrary.refreshAllMetadata: Starting full library refresh")
    guard let modelContext = modelContext else { return }

    // Reset attempt flags so we can try again
    for song in songs {
      song.metadataCheckAttempted = false
      song.metadataFetchSucceeded = false
      song.lyricsCheckAttempted = false
    }
    saveContext()

    let metadataService = MetadataService.shared
    metadataService.setModelContext(modelContext)

    indexingStatus = .indexing("Refreshing library…")

    let songsCount = songs.count
    for (index, song) in songs.enumerated() {
      indexingStatus = .indexing("Refreshing songs (\(index + 1)/\(songsCount))…")
      await metadataService.refreshMetadata(for: song)
    }

    let albumCount = albums.count
    for (index, album) in albums.enumerated() {
      indexingStatus = .indexing("Refreshing albums (\(index + 1)/\(albumCount))…")
      await metadataService.refreshMetadata(for: album)
    }

    indexingStatus = .complete
  }

  func refreshMetadata(for album: Album) async {
    print("[DEBUG] SongLibrary.refreshMetadata: Refreshing album \(album.name)")
    let metadataService = MetadataService.shared
    if let modelContext = modelContext, metadataService.modelContext == nil {
      metadataService.setModelContext(modelContext)
    }
    await metadataService.refreshMetadata(for: album)

    // Also refresh all songs in the album
    for song in album.songs {
      await metadataService.refreshMetadata(for: song)
    }
  }

  func refreshMetadata(for artist: Artist) async {
    print("[DEBUG] SongLibrary.refreshMetadata: Refreshing artist \(artist.name)")
    let metadataService = MetadataService.shared
    if let modelContext = modelContext, metadataService.modelContext == nil {
      metadataService.setModelContext(modelContext)
    }

    // Refresh artist info
    await metadataService.fetchMetadata(for: artist)

    // Refresh all songs by this artist
    let artistSongs = getSongs(byArtist: artist.name)
    for song in artistSongs {
      await metadataService.refreshMetadata(for: song)
    }
  }

  @MainActor
  private func applyFetchedMetadata(
    _ metadata: FetchedMetadata, to song: LibrarySong, preferences: UserPreferences
  ) async {
    print("[DEBUG] SongLibrary.applyFetchedMetadata: Applying metadata to \(song.title)")
    guard let modelContext = modelContext else {
      print("[DEBUG] SongLibrary.applyFetchedMetadata: Error - No modelContext")
      return
    }

    var needsSave = false

    // Update song fields only if they're empty or generic (Preserve user edits)
    if let title = metadata.title, !title.isEmpty,
      !song.userEditedFields.contains("title"),
      (song.titleConfidence < 0.8 || song.title == song.fileName || song.title.contains("Untitled"))
    {
      song.title = title
      song.titleConfidence = (metadata.source == .appleMusic) ? 0.95 : MetadataConfidenceScorer.scoreMusicBrainz(value: title)
      song.metadataSourceTitle = metadata.source.rawValue
      needsSave = true
    }

    if let artist = metadata.artist, !artist.isEmpty,
      !song.userEditedFields.contains("artist"),
      (song.artistConfidence < 0.8 || song.artist == "Unknown Artist" || song.artist.isEmpty)
    {
      song.artist = artist
      song.artistConfidence = (metadata.source == .appleMusic) ? 0.95 : MetadataConfidenceScorer.scoreMusicBrainz(value: artist)
      song.metadataSourceArtist = metadata.source.rawValue
      needsSave = true
    }

    if let album = metadata.album, !album.isEmpty,
      !song.userEditedFields.contains("album"),
      (song.albumConfidence < 0.8 || song.album == nil || song.album == "Unknown Album" || song.album?.isEmpty == true)
    {
      song.album = album
      song.albumConfidence = (metadata.source == .appleMusic) ? 0.95 : MetadataConfidenceScorer.scoreMusicBrainz(value: album)
      song.metadataSourceAlbum = metadata.source.rawValue
      needsSave = true
    }

    if let year = metadata.year,
      !song.userEditedFields.contains("year"),
      song.year == nil || song.year == 0
    {
      song.year = year
      needsSave = true
    }

    if let genre = metadata.genre, !genre.isEmpty,
      !song.userEditedFields.contains("genre"),
      song.genre == nil || song.genre?.isEmpty == true
    {
      song.genre = genre
      needsSave = true
    }

    if let albumArtist = metadata.albumArtist, !albumArtist.isEmpty,
      !song.userEditedFields.contains("albumArtist"),
      song.albumArtist == nil || song.albumArtist?.isEmpty == true
    {
      song.albumArtist = albumArtist
      needsSave = true
    }

    if let composer = metadata.composer, !composer.isEmpty,
      !song.userEditedFields.contains("composer"),
      song.composer == nil || song.composer?.isEmpty == true
    {
      song.composer = composer
      needsSave = true
    }

    if let lyricist = metadata.lyricist, !lyricist.isEmpty,
      !song.userEditedFields.contains("lyricist"),
      song.lyricist == nil || song.lyricist?.isEmpty == true
    {
        song.lyricist = lyricist
        needsSave = true
    }

    if let isrc = metadata.isrc, !isrc.isEmpty {
      song.isrc = isrc
      needsSave = true
    }

    if let appleMusicURL = metadata.appleMusicURL {
      song.appleMusicURL = appleMusicURL.absoluteString
      needsSave = true
    }

    // Update related models
    if let albumRef = song.albumReference {
        if let desc = metadata.albumDescription, (albumRef.albumDescription == nil || albumRef.albumDescription?.isEmpty == true) {
            albumRef.albumDescription = desc
        }
        if albumRef.appleMusicId == nil {
            albumRef.appleMusicId = metadata.appleMusicId
        }
    }
    
    let artistNames = ArtistParser.parseArtists(from: metadata.albumArtist ?? metadata.artist ?? song.artist)
    if let primaryArtist = artistNames.first {
        let artist = getArtist(named: primaryArtist)
        if let artist = artist {
            if let bio = metadata.artistBio, (artist.biography == nil || artist.biography?.isEmpty == true) {
                artist.biography = bio
            }
            if artist.appleMusicId == nil {
                artist.appleMusicId = metadata.appleMusicId
            }
        }
    }

    if let duration = metadata.duration, duration > 0, song.duration <= 0 {
      song.duration = duration
      needsSave = true
    }

    // Download and cache artwork if available
    if let artworkURL = metadata.artworkURL {
      // Only replace if no artwork or if remote artwork is preferred and not user-selected
      let isUserSelected = song.artworkSource == .user
      let hasEmbeddedArt = song.embeddedArtworkPath != nil

      // If preferEmbeddedArtwork is true and we have embedded art, don't replace
      let shouldRespectEmbedded = preferences.preferEmbeddedArtwork && hasEmbeddedArt

      if song.artworkPath == nil
        || (preferences.preferOnlineArtwork && !isUserSelected && !shouldRespectEmbedded)
      {
        if let artworkPath = await MetadataService.shared.downloadArtwork(from: artworkURL) {
          song.artworkPath = artworkPath
          song.isRemoteArtwork = true
          song.artworkSource = .online
          needsSave = true
          
          // Update album artwork too
          if let album = song.albumReference {
            album.artworkPath = artworkPath
          }
        }
      }
    }

    if needsSave {
      print("[DEBUG] SongLibrary.applyFetchedMetadata: Updating search index")
      song.updateSearchIndex()
      print("[DEBUG] SongLibrary.applyFetchedMetadata: Saving changes")
      try? modelContext.save()
    }
    print("[DEBUG] SongLibrary.applyFetchedMetadata: Finished for \(song.title)")
  }

  // MARK: - Album Management

  // MARK: Grouping helpers

  /// Normalise a string for album/artist key comparison: strip whitespace,
  /// fold case and diacritics. Used so that "FEAR", "fear", and " Fear " all
  /// produce the same key and land in the same album bucket.
  private func normalizeForGrouping(_ s: String) -> String {
    s.trimmingCharacters(in: .whitespacesAndNewlines)
      .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
      .lowercased()
  }

  /// Extract the *primary* artist from a compound track-artist string so that
  /// "NF", "NF; mgk", and "NF feat. James Arthur" all resolve to "NF".
  ///
  /// This mirrors how Apple Music and Spotify group albums: featured artists on
  /// individual tracks don't fragment the album. The algorithm strips everything
  /// after the first recognised multi-artist delimiter.
  private func extractPrimaryArtist(from artist: String) -> String {
    let trimmed = artist.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return "Unknown Artist" }

    // Ordered from longest/most-specific to shortest to avoid partial matches.
    let delimiters = [
      " featuring ", " Featuring ",
      " feat. ", " Feat. ",
      " feat ", " Feat ",
      " ft. ", " Ft. ",
      " ft ", " Ft ",
      " with ", " With ",
      " vs. ", " Vs. ",
      " vs ", " Vs ",
      " x ", " X ",
      " & ",
      "; ",
    ]
    for sep in delimiters {
      if let range = trimmed.range(of: sep) {
        let primary = String(trimmed[..<range.lowerBound])
          .trimmingCharacters(in: .whitespacesAndNewlines)
        if !primary.isEmpty { return primary }
      }
    }
    // Bare semicolon or comma (tag editors sometimes omit the space)
    for ch: Character in [";", ","] {
      if let idx = trimmed.firstIndex(of: ch) {
        let primary = String(trimmed[..<idx]).trimmingCharacters(in: .whitespacesAndNewlines)
        if !primary.isEmpty { return primary }
      }
    }
    return trimmed
  }

  /// Determines the canonical album-artist string used as the grouping key.
  ///
  /// Priority (mirrors iTunes / Apple Music / Spotify behaviour):
  ///   1. Compilation flag (TCMP=1) → "Various Artists"
  ///   2. Album Artist tag (TPE2 / aART) → extract primary artist from it.
  ///      Some taggers write "NF; Britt Nicole" or "NF; fleurie" into the Album Artist
  ///      field for collab tracks. extractPrimaryArtist strips the featured artists so
  ///      every track on the same album resolves to the same canonical artist.
  ///   3. No Album Artist → extract the primary artist from the track artist field.
  private func resolveAlbumArtist(
    albumArtist: String?,
    trackArtist: String,
    isCompilation: Bool
  ) -> String {
    if isCompilation { return "Various Artists" }
    if let aa = albumArtist, !aa.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      return extractPrimaryArtist(from: aa.trimmingCharacters(in: .whitespacesAndNewlines))
    }
    return extractPrimaryArtist(from: trackArtist)
  }

  private func getOrCreateAlbum(
    name: String?,
    albumArtist: String?,
    trackArtist: String,
    isCompilation: Bool,
    year: Int?,
    artworkPath: String?,
    embeddedArtworkPath: String?,
    in modelContext: ModelContext
  ) -> Album? {
    guard let albumName = name?.trimmingCharacters(in: .whitespacesAndNewlines),
          !albumName.isEmpty else { return nil }

    let groupingArtist = resolveAlbumArtist(
      albumArtist: albumArtist,
      trackArtist: trackArtist,
      isCompilation: isCompilation
    )

    let normName   = normalizeForGrouping(albumName)
    let normArtist = normalizeForGrouping(groupingArtist)

    do {
      // Fetch all albums and compare with normalised keys.
      // SwiftData's #Predicate uses exact (case-sensitive) equality which would
      // split "FEAR" and "fear" into separate albums. In-memory normalisation
      // handles case / diacritic / whitespace variations correctly.
      // Albums are far fewer than songs so this is acceptably fast.
      let allAlbums = try modelContext.fetch(FetchDescriptor<Album>())
      if let existingAlbum = allAlbums.first(where: {
        normalizeForGrouping($0.name) == normName &&
        normalizeForGrouping($0.artist ?? "") == normArtist
      }) {
        if existingAlbum.artworkPath == nil, let p = artworkPath { existingAlbum.artworkPath = p }
        if existingAlbum.embeddedArtworkPath == nil, let p = embeddedArtworkPath { existingAlbum.embeddedArtworkPath = p }
        if isCompilation { existingAlbum.isCompilation = true }
        return existingAlbum
      }
    } catch {
      return nil
    }

    let album = Album(
      name: albumName,
      artist: groupingArtist,
      year: year,
      artworkPath: artworkPath,
      embeddedArtworkPath: embeddedArtworkPath
    )
    album.isCompilation = isCompilation
    modelContext.insert(album)
    return album
  }

  /// Merges duplicate albums that refer to the same release.
  /// Uses the same normalised (name, resolved-artist) key so albums previously
  /// split by case differences or featured-artist variants are consolidated.
  /// Also applies extractPrimaryArtist to the stored album artist so albums that
  /// were split by old code (which used raw track-artist strings like "NF; mgk")
  /// are healed into the correct single album.
  private func mergeAlbumDuplicates(in modelContext: ModelContext) async {
    do {
      let descriptor = FetchDescriptor<Album>(
        sortBy: [SortDescriptor(\.createdDate, order: .forward)]
      )
      let allAlbums = try modelContext.fetch(descriptor)

      // Group by normalised (name, canonical-artist) key.
      // extractPrimaryArtist is applied so "NF; mgk" and "NF" map to the same key.
      var albumGroups: [String: [Album]] = [:]
      for album in allAlbums {
        let artistKey: String
        if album.isCompilation {
          artistKey = "various artists"
        } else {
          let primary = extractPrimaryArtist(from: album.artist ?? "")
          artistKey = normalizeForGrouping(primary)
        }
        let key = "\(normalizeForGrouping(album.name))|\(artistKey)"
        if albumGroups[key] == nil {
          albumGroups[key] = []
        }
        albumGroups[key]?.append(album)
      }

      // Merge duplicates
      for (_, duplicateAlbums) in albumGroups {
        guard duplicateAlbums.count > 1 else { continue }

        // Keep the first album (oldest), merge others into it
        let primaryAlbum = duplicateAlbums[0]

        for duplicateAlbum in duplicateAlbums.dropFirst() {
          // Move all songs from duplicate to primary
          for song in duplicateAlbum.songs {
            song.albumReference = primaryAlbum
            primaryAlbum.songs.append(song)
          }

          // Update artwork if primary doesn't have one
          if primaryAlbum.artworkPath == nil, let artworkPath = duplicateAlbum.artworkPath {
            primaryAlbum.artworkPath = artworkPath
          }

          // Delete the duplicate album
          modelContext.delete(duplicateAlbum)
        }
      }

      // Save changes
      try modelContext.save()
      print("[DEBUG] SongLibrary.mergeAlbumDuplicates: Merge completed and saved")
    } catch {
      print("[DEBUG] SongLibrary.mergeAlbumDuplicates: Error: \(error)")
    }
  }

  // MARK: - Artwork Caching

  public func cacheArtwork(_ artworkData: Data) async -> String? {
    guard !artworkData.isEmpty else { return nil }

    let hash = artworkData.sha256()
    let fileName = "\(hash).jpg"
    let artworkURL = artworkCacheDirectory.appendingPathComponent(fileName)

    if fileManager.fileExists(atPath: artworkURL.path) {
      return PathManager.relativePath(from: artworkURL.path)
    }

    do {
      try artworkData.write(to: artworkURL)
      return PathManager.relativePath(from: artworkURL.path)
    } catch {
      return nil
    }
  }

  // MARK: - File Management

  func getFileURL(for song: LibrarySong) -> URL {
    if song.storageMode == .referenced, let data = song.bookmarkData {
      if let resolved = PathManager.resolveBookmark(data) {
        return resolved
      }
    }

    if let storedURL = resolvedStoredFileURL(for: song),
      fileManager.fileExists(atPath: storedURL.path)
    {
      return storedURL
    }

    let legacyURL = legacyMetadataFileURL(for: song)
    if fileManager.fileExists(atPath: legacyURL.path) {
      updateStoredFilePath(for: song, to: legacyURL)
      return legacyURL
    }

    return resolvedStoredFileURL(for: song) ?? legacyURL
  }

  private func resolvedStoredFileURL(for song: LibrarySong) -> URL? {
    guard let path = song.filePath, !path.isEmpty else { return nil }
    return PathManager.resolve(path)?.standardizedFileURL
  }

  private func legacyMetadataFileURL(for song: LibrarySong) -> URL {
    guard let modelContext = modelContext else {
      return songsDirectory.appendingPathComponent(song.fileName)
    }

    let settings = AppSettings.getOrCreate(in: modelContext)
    return getAlbumDirectory(
      album: song.album, artist: song.artist, groupByAlbum: settings.groupSongsByAlbum
    )
    .appendingPathComponent(song.fileName)
  }

  @discardableResult
  private func updateStoredFilePath(for song: LibrarySong, to url: URL) -> Bool {
    let relativePath = PathManager.relativePath(from: url.standardizedFileURL.path)
    guard song.filePath != relativePath else { return false }
    song.filePath = relativePath
    return true
  }

  nonisolated private func getAlbumDirectory(album: String?, artist: String?, groupByAlbum: Bool)
    -> URL
  {
    guard groupByAlbum else {
      return songsDirectory
    }

    let artistName = artist ?? "Unknown Artist"
    let albumName = album ?? "Unknown Album"

    // Sanitize names for folder paths
    let sanitizedArtist = artistName.replacingOccurrences(
      of: "[/\\\\:*?\"<>|]", with: "_", options: .regularExpression)
    let sanitizedAlbum = albumName.replacingOccurrences(
      of: "[/\\\\:*?\"<>|]", with: "_", options: .regularExpression)

    let artistDir = songsDirectory.appendingPathComponent(sanitizedArtist, isDirectory: true)
    let albumDir = artistDir.appendingPathComponent(sanitizedAlbum, isDirectory: true)

    return albumDir
  }

  nonisolated private func generateFileName(
    artist: String, title: String, trackNumber: Int?, originalExtension: String
  ) -> String {
    let sanitized = { (str: String) -> String in
      str.replacingOccurrences(of: "[/\\\\:*?\"<>|]", with: "_", options: .regularExpression)
        .trimmingCharacters(in: .whitespaces)
    }

    let artistSanitized = sanitized(artist.isEmpty ? "Unknown" : artist)
    let titleSanitized = sanitized(title.isEmpty ? "Untitled" : title)

    let baseName: String
    if let trackNum = trackNumber, trackNum > 0 {
      let paddedTrack = String(format: "%02d", trackNum)
      baseName = "\(paddedTrack) - \(artistSanitized) - \(titleSanitized)"
    } else {
      baseName = "\(artistSanitized) - \(titleSanitized)"
    }

    let ext = originalExtension.isEmpty ? "mp3" : originalExtension.lowercased()
    return "\(baseName).\(ext)"
  }

  nonisolated private func getUniqueFileName(baseName: String, in directory: URL) -> String {
    let url = directory.appendingPathComponent(baseName)

    guard fileManager.fileExists(atPath: url.path) else {
      return baseName
    }

    let parts = baseName.split(separator: ".", maxSplits: 1, omittingEmptySubsequences: false)
    let nameWithoutExt = String(parts[0])
    let ext = parts.count > 1 ? "." + String(parts[1]) : ""

    var counter = 1
    while counter < 1000 {
      let newName = "\(nameWithoutExt) (\(counter))\(ext)"
      let newURL = directory.appendingPathComponent(newName)
      if !fileManager.fileExists(atPath: newURL.path) {
        return newName
      }
      counter += 1
    }

    return "\(nameWithoutExt) (\(UUID().uuidString.prefix(8)))\(ext)"
  }

  func deleteAllFiles() {
    print("[DEBUG] SongLibrary.deleteAllFiles: Deleting all files in \(songsDirectory.path)")
    try? fileManager.removeItem(at: songsDirectory)
    try? fileManager.createDirectory(at: songsDirectory, withIntermediateDirectories: true)
  }

  /// Clears all in-memory arrays and resets every guard flag so the next
  /// `loadSongs()` and `indexOnStartup()` perform a full, clean run.
  /// Must be called after deleting records from SwiftData and saving.
  func resetInMemoryState() {
    songs   = []
    albums  = []
    artists = []
    isLoaded  = false
    isIndexing = false          // let indexOnStartup run again on next launch
    pendingMetadataFetches = 0
    totalMetadataFetches   = 0
    indexingStatus         = .idle
    notifyLibraryChange()
  }

  func deleteSong(_ song: LibrarySong) {
    guard let modelContext = modelContext else { return }

    // 1. Delete file only if it was copied into our internal library
    if song.storageMode == .copied {
      let url = getFileURL(for: song)
      if fileManager.fileExists(atPath: url.path) {
        print("[DEBUG] SongLibrary.deleteSong: Deleting copied file: \(url.path)")
        try? fileManager.removeItem(at: url)
      }
    } else {
      print("[DEBUG] SongLibrary.deleteSong: Skipping file deletion for referenced song")
    }

    // 2. Remove from database
    modelContext.delete(song)
    saveContext()

    // 3. Update local state
    if let index = songs.firstIndex(where: { $0.id == song.id }) {
      songs.remove(at: index)
    }
  }

  func deleteAlbum(_ album: Album) {
    guard let modelContext = modelContext else { return }

    // 1. Delete all song files in the album only if they were copied
    for song in album.songs {
      if song.storageMode == .copied {
        let url = getFileURL(for: song)
        if fileManager.fileExists(atPath: url.path) {
          try? fileManager.removeItem(at: url)
        }
      }
    }

    // 2. Remove album from database (songs will cascade delete in DB)
    modelContext.delete(album)
    saveContext()

    // 3. Update local state
    if let index = albums.firstIndex(where: { $0.id == album.id }) {
      albums.remove(at: index)
    }

    // Reload songs to reflect deletions
    Task {
      await loadSongs()
    }
  }

  // MARK: - Persistence

  func saveContext() {
    print("[DEBUG] SongLibrary.saveContext: Saving modelContext")
    guard let modelContext = modelContext else {
      print("[DEBUG] SongLibrary.saveContext: Error - No modelContext")
      return
    }
    do {
      try modelContext.save()
      notifyLibraryChange()
      print("[DEBUG] SongLibrary.saveContext: Successfully saved")
    } catch {
      print("[DEBUG] SongLibrary.saveContext: Error saving: \(error)")
    }
  }

  /// On every launch: find songs where a metadata fetch was attempted but never completed
  /// (app killed mid-fetch, network failure, etc.) and re-queue them.
  /// Also picks up any song whose metadata is still incomplete and hasn't been attempted yet.
  /// Gated by the "Auto-fetch metadata" preference and network availability.
  func resumeIncompleteMetadataFetches() async {
    guard let modelContext = modelContext else { return }
    let prefs = UserPreferences.getOrCreate(in: modelContext)
    guard prefs.autoFetchMetadata, !prefs.isOfflineMode, NetworkMonitor.shared.isOnline else {
      return
    }

    MetadataService.shared.setModelContext(modelContext)

    // Songs to resume: attempted but never confirmed as succeeded, AND still missing data.
    // `metadataFetchSucceeded` is set true both on success AND on "no API match", so
    // only songs whose session was interrupted (app killed mid-fetch) stay false.
    let incompleteAttempted = songs.filter { song in
      guard song.metadataCheckAttempted && !song.metadataFetchSucceeded else { return false }
      return hasMissingMetadata(song)
    }

    // Songs never attempted yet (new imports from a previous session).
    let neverAttempted = songs.filter { !$0.metadataCheckAttempted }

    let targets = incompleteAttempted + neverAttempted
    guard !targets.isEmpty else {
      print("[DEBUG] SongLibrary.resumeIncompleteMetadataFetches: All songs up to date")
      return
    }

    print("[DEBUG] SongLibrary.resumeIncompleteMetadataFetches: \(targets.count) songs need fetching (\(incompleteAttempted.count) interrupted, \(neverAttempted.count) new)")

    // Reset the attempted flag so fetchMetadataForNewSongs picks them up.
    for song in targets {
      song.metadataCheckAttempted = false
    }
    try? modelContext.save()

    await fetchMetadataForNewSongs()
  }

  /// Returns true if the song is missing any metadata field worth fetching.
  private func hasMissingMetadata(_ song: LibrarySong) -> Bool {
    song.artworkPath == nil
    || song.genre == nil || song.genre?.isEmpty == true
    || song.year == nil
    || song.albumArtist == nil || song.albumArtist?.isEmpty == true
    || song.title.contains("Untitled")
    || song.artist == "Unknown Artist"
    || song.artist.isEmpty
  }

  /// Distinct genre labels with song counts. Splits compound tags (e.g. `Rock/Pop`) on `/` and `,`.
  func genreEntriesSortedByPopularity() -> [(name: String, count: Int)] {
    var counts: [String: Int] = [:]
    for song in songs {
      guard let raw = song.genre?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty
      else {
        continue
      }

      // Split by common separators: /, ;, ,
      let parts = raw.components(separatedBy: CharacterSet(charactersIn: "/;,"))

      var seenInThisSong = Set<String>()

      for part in parts {
        let trimmed = part.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { continue }

        // Use consistent capitalization for counting
        let normalized = trimmed.capitalized
        if !seenInThisSong.contains(normalized) {
          counts[normalized, default: 0] += 1
          seenInThisSong.insert(normalized)
        }
      }
    }
    return counts.map { (name: $0.key, count: $0.value) }
      .sorted {
        if $0.count != $1.count { return $0.count > $1.count }
        return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
      }
  }

  func setModelContext(_ context: ModelContext) {
    let start = Date()
    print(
      "[\(Date()).ISO8601Format()] [DEBUG] SongLibrary.setModelContext called on thread: \(Thread.current.name)"
    )
    print("[\(Date()).ISO8601Format()] [DEBUG] About to assign context...")
    modelContext = context
    print(
      "[\(Date()).ISO8601Format()] [DEBUG] Context assigned, took \(Date().timeIntervalSince(start))s"
    )

    // Load songs immediately to ensure library is ready for other services
    Task {
      await loadSongs()
      // Notify that library is loaded so other services (like PlaybackController) can react
      NotificationCenter.default.post(name: Notification.Name("SongLibraryDidLoad"), object: nil)
    }
  }
}
