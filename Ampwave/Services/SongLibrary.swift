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

  var modelContext: ModelContext? {
    didSet {
      // Don't trigger indexing here - let views control timing
    }
  }

  private static let audioExtensions: Set<String> = [
    "mp3", "m4a", "aac", "flac", "wav", "ogg", "opus", "aiff", "wma", "alac", "m4b",
  ]

  private init() {
    let baseDir = PathManager.documentsDirectory
    let songsDir = baseDir.appendingPathComponent("Songs", isDirectory: true)
    let artworkDir = baseDir.appendingPathComponent("Artwork", isDirectory: true)

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

  func indexOnStartup() async {
    print("[DEBUG] indexOnStartup started on thread: \(Thread.current.name)")
    guard let modelContext = modelContext else {
      print("[DEBUG] indexOnStartup - no modelContext")
      return
    }

    indexingStatus = .indexing("Scanning…")
    defer {
      print("[DEBUG] indexOnStartup completed")
      indexingStatus = .complete
    }

    print("[DEBUG] Getting AppSettings")
    let settings = AppSettings.getOrCreate(in: modelContext)

    try? fileManager.createDirectory(at: songsDirectory, withIntermediateDirectories: true)

    print("[DEBUG] Fetching existing songs from database")
    let descriptor = FetchDescriptor<LibrarySong>()
    let existingSongs: [LibrarySong]
    do {
      existingSongs = try modelContext.fetch(descriptor)
      print("[DEBUG] Found \(existingSongs.count) existing songs")
    } catch {
      print("[DEBUG] Failed to fetch songs, calling loadSongs: \(error)")
      await loadSongs()
      return
    }

    print("[DEBUG] Checking for deleted files")
    // Remove DB entries for files that no longer exist
    let existingFileNames = Set(existingSongs.map(\.fileName))
    for song in existingSongs {
      let url = getFileURL(for: song)
      if !fileManager.fileExists(atPath: url.path) {
        print("[DEBUG] Deleting song: \(song.fileName)")
        modelContext.delete(song)
      }
    }

    print("[DEBUG] Finding audio files on disk")
    // Find audio files on disk
    let audioURLs = findAudioFiles(in: songsDirectory)
    print("[DEBUG] Found \(audioURLs.count) audio files on disk")

    print("[DEBUG] Importing new files")
    // Import new files
    for url in audioURLs {
      let fileName = url.lastPathComponent
      if existingFileNames.contains(fileName) { continue }

      _ = await importFileInPlace(at: url, modelContext: modelContext)
    }

    print("[DEBUG] Saving context")
    saveContext()
    print("[DEBUG] Loading songs")
    await loadSongs()
  }

  private func findAudioFiles(in directory: URL) -> [URL] {
    var audioFiles: [URL] = []

    guard
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
        audioFiles.append(contentsOf: findAudioFiles(in: url))
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
      while let data = try handle.read(upToCount: 65536), !data.isEmpty {  // Larger chunks for speed
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
      print("[DEBUG] SongLibrary.importFiles: Processing file \(index + 1)/\(totalCount): \(url.lastPathComponent)")
      indexingStatus = .indexing("Importing \(index + 1)/\(totalCount)…")

      if let _ = await importFile(
        from: url, modelContext: modelContext, groupByAlbum: groupByAlbum)
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
      }
    }

    if importedCount > 0 {
      print("[DEBUG] SongLibrary.importFiles: Final save and reloading library")
      saveContext()
      await loadSongs()
    }
    print("[DEBUG] SongLibrary.importFiles: Completed. Imported \(importedCount)/\(totalCount) files")
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
      print("[DEBUG] SongLibrary.importFile.detached: Extracting metadata for \(url.lastPathComponent)")
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
    if let data = metadata.artwork { artworkPath = await cacheArtwork(data) } else { artworkPath = nil }

    print("[DEBUG] SongLibrary.importFile: Creating LibrarySong object")
    let song = LibrarySong(
      title: metadata.title,
      artist: metadata.artist,
      fileName: uniqueFileName,
      fileHash: fileHash,
      size: fileSize,
      duration: metadata.duration,
      lyrics: metadata.lyrics,
      album: metadata.album,
      albumArtist: metadata.albumArtist,
      genre: metadata.genre,
      songDescription: metadata.songDescription,
      trackNumber: metadata.trackNumber,
      discNumber: metadata.discNumber,
      year: metadata.year,
      composer: metadata.composer,
      artworkPath: artworkPath
    )

    print("[DEBUG] SongLibrary.importFile: Inserting song into modelContext")
    modelContext.insert(song)

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

    // Background fetch for detailed metadata from API
    print("[DEBUG] SongLibrary.importFile: Starting background metadata fetch from API")
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
      lyrics: metadata.lyrics,
      album: metadata.album,
      albumArtist: metadata.albumArtist,
      genre: metadata.genre,
      songDescription: metadata.songDescription,
      trackNumber: metadata.trackNumber,
      discNumber: metadata.discNumber,
      year: metadata.year,
      composer: metadata.composer,
      artworkPath: artworkPath
    )

    modelContext.insert(song)

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

    // Background fetch
    Task {
      await fetchMetadataForSong(song)
    }

    return song
  }

  // MARK: - Metadata Fetching from API

  private func fetchMetadataForSong(_ song: LibrarySong) async {
    print("[DEBUG] SongLibrary.fetchMetadataForSong: Starting for \(song.title)")
    guard let modelContext = modelContext else {
      print("[DEBUG] SongLibrary.fetchMetadataForSong: Error - No modelContext")
      return
    }

    let metadataService = MetadataService.shared
    if metadataService.modelContext == nil {
      print("[DEBUG] SongLibrary.fetchMetadataForSong: Setting modelContext in MetadataService")
      metadataService.setModelContext(modelContext)
    }

    // Fetch metadata from MusicBrainz (background)
    print("[DEBUG] SongLibrary.fetchMetadataForSong: Calling MetadataService.fetchMetadata")
    if let metadata = await metadataService.fetchMetadata(for: song) {
      // Apply fetched metadata (on MainActor)
      print("[DEBUG] SongLibrary.fetchMetadataForSong: Metadata fetched, applying to song")
      await applyFetchedMetadata(metadata, to: song)
    } else {
      print("[DEBUG] SongLibrary.fetchMetadataForSong: No metadata found for \(song.title)")
    }
  }

  @MainActor
  private func applyFetchedMetadata(_ metadata: FetchedMetadata, to song: LibrarySong) async {
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

    if let genre = metadata.genre, !genre.isEmpty, song.genre == nil || song.genre?.isEmpty == true {
      print("[DEBUG] SongLibrary.applyFetchedMetadata: Updating genre to \(genre)")
      song.genre = genre
      needsSave = true
    }

    if let duration = metadata.duration, duration > 0, song.duration <= 0 {
      print("[DEBUG] SongLibrary.applyFetchedMetadata: Updating duration to \(duration)")
      song.duration = duration
      needsSave = true
    }

    // Download and cache artwork if available and song doesn't have artwork
    if song.artworkPath == nil, let artworkURL = metadata.artworkURL {
      print("[DEBUG] SongLibrary.applyFetchedMetadata: Downloading artwork from \(artworkURL)")
      if let artworkPath = await MetadataService.shared.downloadArtwork(from: artworkURL) {
        print("[DEBUG] SongLibrary.applyFetchedMetadata: Artwork downloaded to \(artworkPath)")
        song.artworkPath = artworkPath
        needsSave = true

        // Update album artwork too
        if let album = song.albumReference, album.artworkPath == nil {
          print("[DEBUG] SongLibrary.applyFetchedMetadata: Updating album artwork")
          album.artworkPath = artworkPath
        }
      } else {
        print("[DEBUG] SongLibrary.applyFetchedMetadata: Failed to download artwork")
      }
    }

    if needsSave {
      print("[DEBUG] SongLibrary.applyFetchedMetadata: Saving changes")
      try? modelContext.save()
      // No need to reload entire library, @Observable will handle UI update
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

  private func cacheArtwork(_ artworkData: Data) async -> String? {
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

