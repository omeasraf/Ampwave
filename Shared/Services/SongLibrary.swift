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

  nonisolated let songsDirectory: URL
  nonisolated let artworkCacheDirectory: URL

  /// Indexing status for startup and Files app sync.
  private(set) var indexingStatus: IndexingStatus = .idle
  private(set) var pendingMetadataFetches: Int = 0 {
    didSet {
      updateIndexingStatusForMetadata()
    }
  }

  var modelContext: ModelContext? {
    didSet {
      // Don't trigger indexing here - let views control timing
    }
  }

  private static let audioExtensions: Set<String> = [
    "mp3", "m4a", "aac", "flac", "wav", "ogg", "opus", "aiff", "wma", "alac", "m4b",
  ]

  private init() {
    let baseDir = PathManager.documentsDirectory.standardizedFileURL
    let songsDir = baseDir.appendingPathComponent("Songs", isDirectory: true).standardizedFileURL
    let artworkDir = baseDir.appendingPathComponent("Artwork", isDirectory: true).standardizedFileURL

    self.songsDirectory = songsDir
    self.artworkCacheDirectory = artworkDir

    let fm = FileManager.default
    try? fm.createDirectory(at: songsDir, withIntermediateDirectories: true)
    try? fm.createDirectory(at: artworkDir, withIntermediateDirectories: true)
  }

  // MARK: - Artists

  /// Gets all unique artists from the library
  func allArtists() async -> [Artist] {
    var artistMap: [String: Artist] = [:]

    for song in songs {
      // Use individual artists from the artists array
      let artistNames = song.artists.isEmpty ? [song.artist] : song.artists

      for artistName in artistNames {
        let trimmedName = artistName.trimmingCharacters(in: .whitespaces)
        guard !trimmedName.isEmpty else { continue }

        if let existing = artistMap[trimmedName] {
          existing.songCount += 1
          // Update artwork if needed
          if existing.artworkPath == nil {
            existing.artworkPath = song.artworkPath
          }
          // Update lastAddedDate
          if song.importedDate > existing.lastAddedDate {
            existing.lastAddedDate = song.importedDate
          }
          // Update genres
          if let genre = song.genre, !genre.isEmpty {
            if existing.genres == nil {
              existing.genres = [genre]
            } else if !(existing.genres?.contains(genre) ?? false) {
              existing.genres?.append(genre)
            }
          }
        } else {
          let artist = Artist(name: trimmedName)
          artist.songCount = 1
          artist.artworkPath = song.artworkPath
          artist.lastAddedDate = song.importedDate
          if let genre = song.genre {
            artist.genres = [genre]
          }
          artistMap[trimmedName] = artist
        }
      }
    }

    // Count albums per artist
    for album in albums {
      let normalizedAlbumArtist = (album.artist ?? "").lowercased()
      if let artistKey = artistMap.keys.first(where: { $0.lowercased() == normalizedAlbumArtist }) {
        artistMap[artistKey]?.albumCount = (artistMap[artistKey]?.albumCount ?? 0) + 1
      }
    }

    return artistMap.values.sorted { $0.name < $1.name }
  }

  /// Gets an artist by name
  func getArtist(named name: String) -> Artist? {
    artists.first { $0.name.lowercased() == name.lowercased() }
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

  func loadSongs() async {
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

      // Merge duplicate albums if setting is enabled
      let settings = AppSettings.getOrCreate(in: modelContext)
      if settings.mergeAlbumDuplicates {
        print("[DEBUG] SongLibrary.loadAlbums: Merging duplicate albums")
        await mergeAlbumDuplicates(in: modelContext)
      }
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

    indexingStatus = .indexing("Scanning…")
    defer {
      print("[DEBUG] indexOnStartup completed")
      indexingStatus = .complete
      isIndexing = false
    }

    print("[DEBUG] Getting AppSettings")
    let settings = AppSettings.getOrCreate(in: modelContext)

    try? fileManager.createDirectory(at: songsDirectory, withIntermediateDirectories: true)

    print("[DEBUG] Fetching existing songs from database")
    let descriptor = FetchDescriptor<LibrarySong>()
    var existingSongs: [LibrarySong]
    do {
      existingSongs = try modelContext.fetch(descriptor)
      print("[DEBUG] Found \(existingSongs.count) existing songs in database")
      
      // Safety: if DB is empty but memory has songs, avoid mass deletion
      if existingSongs.isEmpty && !self.songs.isEmpty {
        print("[DEBUG] DB returned empty but cache is not. Aborting index.")
        return
      }
    } catch {
      print("[DEBUG] Failed to fetch songs, calling loadSongs: \(error)")
      await loadSongs()
      return
    }

    print("[DEBUG] Finding audio files on disk")
    // Find audio files on disk
    let audioURLs = findAudioFiles(in: songsDirectory)
    print("[DEBUG] Found \(audioURLs.count) audio files on disk")

    // Use standardized path strings for more reliable matching
    let audioPathSet = Set(audioURLs.map { $0.standardizedFileURL.path })
    var fileNameToURLs: [String: [URL]] = [:]
    for url in audioURLs {
      fileNameToURLs[url.lastPathComponent, default: []].append(url)
    }

    print("[DEBUG] Checking for moved or deleted files")
    var accountedForPaths = Set<String>()
    var deletedCount = 0
    var movedCount = 0
    
    for song in existingSongs {
      let expectedURL = getFileURL(for: song).standardizedFileURL
      let expectedPath = expectedURL.path
      
      if audioPathSet.contains(expectedPath) {
        accountedForPaths.insert(expectedPath)
        continue
      }

      // File is NOT at expected location. Check if it moved.
      print("[DEBUG] Song \(song.title) not at expected path: \(expectedPath)")
      var foundMoved = false
      if let possibleURLs = fileNameToURLs[song.fileName] {
        for possibleURL in possibleURLs {
          if await self.fileHash(at: possibleURL) == song.fileHash {
            print("[DEBUG] Found moved song at: \(possibleURL.path), moving back to: \(expectedPath)")
            // Move it back to the expected location
            try? fileManager.createDirectory(at: expectedURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            do {
              try fileManager.moveItem(at: possibleURL, to: expectedURL)
              accountedForPaths.insert(expectedPath)
              foundMoved = true
              movedCount += 1
            } catch {
              print("[DEBUG] Failed to move file: \(error)")
            }
            break
          }
        }
      }

      if !foundMoved {
        print("[DEBUG] Deleting song from database (not found on disk): \(song.fileName) [\(song.title)]")
        modelContext.delete(song)
        deletedCount += 1
      }
    }
    
    if deletedCount > 0 || movedCount > 0 {
      print("[DEBUG] indexOnStartup results: \(movedCount) moved, \(deletedCount) deleted")
    }

    print("[DEBUG] Importing new files")
    // Get existing hashes once for efficient lookup
    modelContext.processPendingChanges()
    let finalExistingSongs = (try? modelContext.fetch(FetchDescriptor<LibrarySong>())) ?? []
    let finalExistingHashes = Set(finalExistingSongs.map(\.fileHash))

    // Use the accountedForPaths set to avoid processing files we already matched
    var importCount = 0
    for url in audioURLs {
      let standardizedPath = url.standardizedFileURL.path
      if accountedForPaths.contains(standardizedPath) { continue }

      // Check by hash for truly unknown files
      guard let hash = await self.fileHash(at: url) else { continue }
      
      // Double check if this hash somehow exists in DB
      if finalExistingHashes.contains(hash) {
        continue
      }

      print("[DEBUG] Importing new file found on disk: \(url.lastPathComponent)")
      _ = await importFileInPlace(at: url, modelContext: modelContext)
      importCount += 1
    }
    
    if importCount > 0 {
      print("[DEBUG] indexOnStartup imported \(importCount) new songs")
    }

    print("[DEBUG] Saving context")
    saveContext()

    print("[DEBUG] Reindexing missing technical metadata")
    await reindexMissingTechnicalMetadata()

    print("[DEBUG] Loading songs")
    await loadSongs()
  }

  private func findAudioFiles(in directory: URL, currentDepth: Int = 0) -> [URL] {
    var audioFiles: [URL] = []
    let maxDepth = 3 // Limit depth to avoid scanning outside the music folders if somehow linked

    guard currentDepth <= maxDepth,
      let contents = try? fileManager.contentsOfDirectory(
        at: directory,
        includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey],
        options: .skipsHiddenFiles
      )
    else {
      return audioFiles
    }

    for url in contents {
      let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false

      if isDir {
        audioFiles.append(contentsOf: findAudioFiles(in: url, currentDepth: currentDepth + 1))
      } else {
        let ext = url.pathExtension.lowercased()
        if Self.audioExtensions.contains(ext) {
          audioFiles.append(url)
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
      await loadSongs()
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
    do {
      var descriptor = FetchDescriptor<LibrarySong>(
        predicate: #Predicate<LibrarySong> { $0.fileHash == fileHash }
      )
      descriptor.fetchLimit = 1
      let count = try modelContext.fetchCount(descriptor)
      if count > 0 {
        print("[DEBUG] SongLibrary.importFile: Song already exists in library (hash: \(fileHash))")
        return nil
      }
    } catch {
      print("[DEBUG] SongLibrary.importFile: Error checking for existing song: \(error)")
    }

    // Offload remaining heavy I/O to a background task
    print("[DEBUG] SongLibrary.importFile: Offloading remaining I/O to background task")
    let ioResult = await Task.detached(priority: .userInitiated) {
      // Extract metadata (this also does I/O)
      print(
        "[DEBUG] SongLibrary.importFile.detached: Extracting metadata for \(url.lastPathComponent)")
      let metadata = await AudioMetadataExtractor.extract(from: url)

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
        return nil as (ExtractedAudioMetadata, URL, Int)?
      }

      let fileSize = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
      print("[DEBUG] SongLibrary.importFile.detached: I/O completed for \(url.lastPathComponent)")

      return (metadata, destinationURL, fileSize)
    }.value

    guard let (metadata, destinationURL, fileSize) = ioResult else {
      print("[DEBUG] SongLibrary.importFile: I/O task failed for \(url.lastPathComponent)")
      return nil
    }

    let uniqueFileName = destinationURL.lastPathComponent

    // Cache artwork
    print("[DEBUG] SongLibrary.importFile: Caching artwork")
    let artworkPath: String?
    if let data = metadata.artwork {
      artworkPath = await cacheArtwork(data)
    } else {
      artworkPath = nil
    }

    // Check for companion .lrc file in the source location
    var songLyrics = metadata.lyrics
    let lrcURL = url.deletingPathExtension().appendingPathExtension("lrc")
    if FileManager.default.fileExists(atPath: lrcURL.path) {
      if let lrcContent = try? String(contentsOf: lrcURL, encoding: .utf8) {
        songLyrics = lrcContent
        // Optionally copy the .lrc file to destination too
        let destLrcURL = destinationURL.deletingPathExtension().appendingPathExtension("lrc")
        try? FileManager.default.copyItem(at: lrcURL, to: destLrcURL)
      }
    }

    print("[DEBUG] SongLibrary.importFile: Creating LibrarySong object")
    let song = LibrarySong(
      title: metadata.title,
      artist: metadata.artist,
      fileName: uniqueFileName,
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
      sampleRate: metadata.sampleRate,
      bitDepth: metadata.bitDepth,
      bitRate: metadata.bitRate,
      channels: metadata.channels,
      format: metadata.format
    )

    print("[DEBUG] SongLibrary.importFile: Inserting song into modelContext")
    modelContext.insert(song)

    // Save lyrics to SyncedLyric if it's LRC format
    if let lyrics = songLyrics {
      LyricsService.shared.saveLyrics(for: song, content: lyrics)
    }

    // Link to album
    print("[DEBUG] SongLibrary.importFile: Linking to album")
    let primaryArtist =
      ArtistParser.parseArtists(from: metadata.albumArtist ?? metadata.artist).first
      ?? (metadata.albumArtist ?? metadata.artist)

    if let album = getOrCreateAlbum(
      name: metadata.album,
      artist: primaryArtist,
      year: metadata.year,
      artworkPath: artworkPath,
      in: modelContext
    ) {
      song.albumReference = album
      album.songs.append(song)
    }

    // Background fetch online metadata and assets
    Task {
      await fetchMetadataForSong(song)
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

    let song = LibrarySong(
      title: metadata.title,
      artist: metadata.artist,
      fileName: fileName,
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
      sampleRate: metadata.sampleRate,
      bitDepth: metadata.bitDepth,
      bitRate: metadata.bitRate,
      channels: metadata.channels,
      format: metadata.format
    )

    modelContext.insert(song)

    // Save lyrics to SyncedLyric if it's LRC format
    if let lyrics = songLyrics {
      LyricsService.shared.saveLyrics(for: song, content: lyrics)
    }

    // Link to album
    let primaryArtist =
      ArtistParser.parseArtists(from: metadata.albumArtist ?? metadata.artist).first
      ?? (metadata.albumArtist ?? metadata.artist)
    if let album = getOrCreateAlbum(
      name: metadata.album,
      artist: primaryArtist,
      year: metadata.year,
      artworkPath: artworkPath,
      in: modelContext
    ) {
      song.albumReference = album
      album.songs.append(song)
    }

    // Background fetch online metadata and assets
    Task {
      await fetchMetadataForSong(song)
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
    if pendingMetadataFetches > 0 {
      // Only set to fetchingMetadata if not already indexing something else (like file import)
      switch indexingStatus {
      case .idle, .complete, .fetchingMetadata:
        indexingStatus = .fetchingMetadata(pendingMetadataFetches)
      default:
        break
      }
    } else if case .fetchingMetadata = indexingStatus {
      indexingStatus = .complete
    }
  }

  // MARK: - Metadata Fetching from API

  private func fetchMetadataForSong(_ song: LibrarySong) async {
    print("[DEBUG] SongLibrary.fetchMetadataForSong: Starting for \(song.title)")
    guard let modelContext = modelContext else {
      print("[DEBUG] SongLibrary.fetchMetadataForSong: Error - No modelContext")
      return
    }

    let preferences = UserPreferences.getOrCreate(in: modelContext)

    // 1. Online Metadata & Artwork
    // Only fetch if metadata is missing/incomplete AND we haven't already tried.
    let needsMetadata = song.artworkPath == nil || song.album == nil || song.album == "Unknown Album"
    if preferences.autoFetchMetadata && needsMetadata && !song.metadataCheckAttempted {
      pendingMetadataFetches += 1
      defer { 
        song.metadataCheckAttempted = true
        pendingMetadataFetches -= 1 
        saveContext()
      }

      let metadataService = MetadataService.shared
      if metadataService.modelContext == nil {
        metadataService.setModelContext(modelContext)
      }

      print("[DEBUG] SongLibrary.fetchMetadataForSong: Calling MetadataService.fetchMetadata")
      if let metadata = await metadataService.fetchMetadata(for: song) {
        // Apply fetched metadata (on MainActor)
        print("[DEBUG] SongLibrary.fetchMetadataForSong: Metadata fetched, applying to song")
        await applyFetchedMetadata(metadata, to: song, preferences: preferences)
      } else {
        print("[DEBUG] SongLibrary.fetchMetadataForSong: No metadata found for \(song.title)")
      }
    }

    // 2. Synced Lyrics
    // Fetch if no synced lyrics AND we haven't already tried.
    let hasSyncedLyrics = !LRCParser.parse(song.lyrics ?? "").isEmpty
    if preferences.autoFetchLyrics && !hasSyncedLyrics && !song.lyricsCheckAttempted {
      print("[DEBUG] SongLibrary.fetchMetadataForSong: Missing synced lyrics, calling LyricsService")
      
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

    // Fetch for songs that have no artwork and haven't been attempted yet
    let descriptor = FetchDescriptor<LibrarySong>(
      predicate: #Predicate<LibrarySong> { $0.artworkPath == nil && !$0.metadataCheckAttempted }
    )

    do {
      let songsToFetch = try modelContext.fetch(descriptor).prefix(10)
      if songsToFetch.isEmpty { return }

      for song in songsToFetch {
        await fetchMetadataForSong(song)
      }
    } catch {
      print("[DEBUG] SongLibrary.fetchMetadataForNewSongs: Error: \(error)")
    }
  }

  func refreshAllMetadata() async {
    print("[DEBUG] SongLibrary.refreshAllMetadata: Starting full library refresh")
    guard let modelContext = modelContext else { return }

    // Reset attempt flags so we can try again
    for song in songs {
      song.metadataCheckAttempted = false
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

    // Update song fields only if they're empty or better
    if let title = metadata.title, !title.isEmpty,
      song.title.contains("Untitled") || song.title == song.fileName
    {
      print("[DEBUG] SongLibrary.applyFetchedMetadata: Updating title to \(title)")
      song.title = title
      needsSave = true
    }

    if let artist = metadata.artist, !artist.isEmpty,
      song.artist == "Unknown Artist" || song.artist.isEmpty
    {
      print("[DEBUG] SongLibrary.applyFetchedMetadata: Updating artist to \(artist)")
      song.artist = artist
      needsSave = true
    }

    if let album = metadata.album, !album.isEmpty,
      song.album == nil || song.album?.isEmpty == true || song.album == "Unknown Album"
    {
      print("[DEBUG] SongLibrary.applyFetchedMetadata: Updating album to \(album)")
      song.album = album
      needsSave = true
    }

    if let year = metadata.year, song.year == nil || song.year == 0 {
      print("[DEBUG] SongLibrary.applyFetchedMetadata: Updating year to \(year)")
      song.year = year
      needsSave = true
    }

    if let genre = metadata.genre, !genre.isEmpty, song.genre == nil || song.genre?.isEmpty == true
    {
      print("[DEBUG] SongLibrary.applyFetchedMetadata: Updating genre to \(genre)")
      song.genre = genre
      needsSave = true
    }

    if let duration = metadata.duration, duration > 0, song.duration <= 0 {
      print("[DEBUG] SongLibrary.applyFetchedMetadata: Updating duration to \(duration)")
      song.duration = duration
      needsSave = true
    }

    // Download and cache artwork if available
    if let artworkURL = metadata.artworkURL {
      // If we prefer online, or if we don't have artwork yet, fetch it.
      // We skip if we already have remote artwork to satisfy "once" requirement.
      let shouldFetchArtwork =
        (preferences.preferOnlineArtwork && !song.isRemoteArtwork) || song.artworkPath == nil

      if shouldFetchArtwork {
        print(
          "[DEBUG] SongLibrary.applyFetchedMetadata: Fetching online artwork (preferOnline: \(preferences.preferOnlineArtwork))"
        )
        if let artworkPath = await MetadataService.shared.downloadArtwork(from: artworkURL) {
          print("[DEBUG] SongLibrary.applyFetchedMetadata: Artwork downloaded to \(artworkPath)")
          song.artworkPath = artworkPath
          song.isRemoteArtwork = true
          needsSave = true

          // Update album artwork too
          if let album = song.albumReference {
            print("[DEBUG] SongLibrary.applyFetchedMetadata: Updating album artwork")
            album.artworkPath = artworkPath
          }
        } else {
          print("[DEBUG] SongLibrary.applyFetchedMetadata: Failed to download artwork")
        }
      }
    }

    if needsSave {
      print("[DEBUG] SongLibrary.applyFetchedMetadata: Saving changes")
      try? modelContext.save()
    }
    print("[DEBUG] SongLibrary.applyFetchedMetadata: Finished for \(song.title)")
  }

  // MARK: - Album Management

  private func getOrCreateAlbum(
    name: String?, artist: String?, year: Int?, artworkPath: String?, in modelContext: ModelContext
  ) -> Album? {
    guard let albumName = name, !albumName.isEmpty else { return nil }

    let artistName = artist ?? "Unknown Artist"

    do {
      var descriptor = FetchDescriptor<Album>(
        predicate: #Predicate<Album> { $0.name == albumName && $0.artist == artistName }
      )
      descriptor.fetchLimit = 1
      if let existingAlbum = try modelContext.fetch(descriptor).first {
        if existingAlbum.artworkPath == nil, let newArtworkPath = artworkPath {
          existingAlbum.artworkPath = newArtworkPath
        }
        return existingAlbum
      }
    } catch {
      return nil
    }

    let album = Album(
      name: albumName,
      artist: artistName,
      year: year,
      artworkPath: artworkPath
    )
    modelContext.insert(album)
    return album
  }

  /// Merges duplicate albums with the same name and artist
  private func mergeAlbumDuplicates(in modelContext: ModelContext) async {
    do {
      // Fetch all albums
      let descriptor = FetchDescriptor<Album>(
        sortBy: [SortDescriptor(\.createdDate, order: .forward)]
      )
      let allAlbums = try modelContext.fetch(descriptor)

      // Group albums by (name, artist) key
      var albumGroups: [String: [Album]] = [:]
      for album in allAlbums {
        let key = "\(album.name)|\(album.artist ?? "")"
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
    guard let modelContext = modelContext else {
      return songsDirectory.appendingPathComponent(song.fileName)
    }

    let settings = AppSettings.getOrCreate(in: modelContext)
    return getAlbumDirectory(
      album: song.album, artist: song.artist, groupByAlbum: settings.groupSongsByAlbum
    )
    .appendingPathComponent(song.fileName)
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

  func deleteSong(_ song: LibrarySong) {
    guard let modelContext = modelContext else { return }
    
    // 1. Delete file
    let url = getFileURL(for: song)
    if fileManager.fileExists(atPath: url.path) {
      try? fileManager.removeItem(at: url)
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
    
    // 1. Delete all song files in the album
    for song in album.songs {
      let url = getFileURL(for: song)
      if fileManager.fileExists(atPath: url.path) {
        try? fileManager.removeItem(at: url)
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

  private func saveContext() {
    print("[DEBUG] SongLibrary.saveContext: Saving modelContext")
    guard let modelContext = modelContext else {
      print("[DEBUG] SongLibrary.saveContext: Error - No modelContext")
      return
    }
    do {
      try modelContext.save()
      print("[DEBUG] SongLibrary.saveContext: Successfully saved")
    } catch {
      print("[DEBUG] SongLibrary.saveContext: Error saving: \(error)")
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
  }
}

