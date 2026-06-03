//
//  SettingsView.swift
//  Ampwave
//

import SwiftData
internal import SwiftUI
import UniformTypeIdentifiers

// Unified import mode — covers every file-picker use case in one enum so only
// a single .fileImporter modifier is needed. SwiftUI silently drops all but the
// last .fileImporter when multiple are stacked on the same view.
enum ImportType {
  case file
  case folder
  case playlist
  case backup
}

struct SettingsView: View {
  @Environment(\.modelContext) private var modelContext
  @State private var activeImport: ImportType?        // which mode is pending
  @State private var isShowingImporter = false        // drives the single .fileImporter
  @State private var importError: String?
  @State private var isImporting = false
  @State private var importProgress: Double = 0
  @State private var settings: AppSettings?
  @State private var userPreferences: UserPreferences?
  @State private var showingClearCacheConfirmation = false
  @State private var showingResetConfirmation = false
  @State private var showingResetStatsConfirmation = false
  @State private var isResetting = false
  @State private var backupExportURL: URL?
  @State private var showingOnboarding = false

  private var library: SongLibrary { SongLibrary.shared }
  private var playlistManager: PlaylistManager { PlaylistManager.shared }
  private var historyTracker: ListeningHistoryTracker {
    ListeningHistoryTracker.shared
  }
  private var metadataService: MetadataService { MetadataService.shared }

  let version =
    Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
  let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String
  var buildConfiguration: String {
    #if DEBUG
      return "Debug"
    #else
      return "Release"
    #endif
  }

  @Environment(ThemeManager.self) private var themeManager

  // Derived from the active import mode for the single .fileImporter below.
  private var importerContentTypes: [UTType] {
    switch activeImport {
    case .file:    return [.audio]
    case .folder:  return [.folder]
    case .playlist: return PlaylistImportExport.importableContentTypes
    case .backup:  return [.json]
    case .none:    return [.audio]
    }
  }

  private var importerAllowsMultiple: Bool {
    switch activeImport {
    case .file: return true
    default:    return false
    }
  }

  var body: some View {
    List {
      importSection.listRowBackground(themeManager.cardBackgroundColor)
      libraryStatsSection.listRowBackground(themeManager.cardBackgroundColor)
      playbackSettingsSection.listRowBackground(themeManager.cardBackgroundColor)
      librarySettingsSection.listRowBackground(themeManager.cardBackgroundColor)

      #if os(iOS)
        appleWatchSection.listRowBackground(themeManager.cardBackgroundColor)
      #endif

      themingSection.listRowBackground(themeManager.cardBackgroundColor)
      layoutSection.listRowBackground(themeManager.cardBackgroundColor)
      onlineFeaturesSection.listRowBackground(themeManager.cardBackgroundColor)
      dataManagementSection.listRowBackground(themeManager.cardBackgroundColor)
      dataSourcesSection.listRowBackground(themeManager.cardBackgroundColor)
      aboutSection.listRowBackground(themeManager.cardBackgroundColor)
    }
    .listRowBackground(themeManager.cardBackgroundColor)
    .background(themeManager.backgroundColor)
    .scrollContentBackground(.hidden)
    .tint(themeManager.accentColor)
    .navigationTitle("Settings")
    .sheet(isPresented: $showingOnboarding) {
      OnboardingView()
        .environment(ThemeManager.shared)
    }
    .fileImporter(
      isPresented: $isShowingImporter,
      allowedContentTypes: importerContentTypes,
      allowsMultipleSelection: importerAllowsMultiple
    ) { result in
      // Capture mode NOW — activeImport is still set at this point because
      // $isShowingImporter (not activeImport) is what the picker's dismiss binds to.
      let mode = activeImport
      activeImport = nil
      Task { @MainActor in
        switch mode {
        case .file:     await handleFileImport(result)
        case .folder:   await handleFolderImport(result)
        case .playlist: await handlePlaylistImport(result)
        case .backup:   await handleBackupImport(result)
        case .none:     break
        }
      }
    }
    .alert("Clear Cache?", isPresented: $showingClearCacheConfirmation) {
      Button("Cancel", role: .cancel) {}
      Button("Clear", role: .destructive) {
        clearCache()
      }
    } message: {
      Text(
        "This will remove all cached artwork and lyrics. Your music files will not be affected."
      )
    }
    // Reset Library
    .alert("Reset Library?", isPresented: $showingResetConfirmation) {
      Button("Cancel", role: .cancel) {}
      Button("Reset", role: .destructive) {
        resetLibrary()
      }
    } message: {
      Text(
        "This will remove all songs, playlists, and listening history. This action cannot be undone."
      )
    }
    // Reset Stats
    .alert("Reset Statistics?", isPresented: $showingResetStatsConfirmation) {
      Button("Cancel", role: .cancel) {}
      Button("Reset", role: .destructive) {
        resetStats()
      }
    } message: {
      Text(
        "This will remove your listening history. This action cannot be undone."
      )
    }
    .onAppear {
      setupContext()
      Task {
        await library.loadSongs()
      }
    }
    .overlay {
      if isResetting {
        ZStack {
          Color.black.opacity(0.4)
            .ignoresSafeArea()

          VStack(spacing: 16) {
            ProgressView()
              .scaleEffect(1.5)
            Text("Resetting Library...")
              .font(.headline)
              .foregroundStyle(.white)
          }
          .padding(30)
          .background(.ultraThinMaterial)
          .clipShape(RoundedRectangle(cornerRadius: 20))
        }
      }
    }
  }

  private func setupContext() {
    if library.modelContext == nil {
      library.setModelContext(modelContext)
    }
    if playlistManager.modelContext == nil {
      playlistManager.setModelContext(modelContext)
    }
    if historyTracker.modelContext == nil {
      historyTracker.setModelContext(modelContext)
    }
    if metadataService.modelContext == nil {
      metadataService.setModelContext(modelContext)
    }

    loadSettings()
  }

  private func loadSettings() {
    settings = AppSettings.getOrCreate(in: modelContext)
    userPreferences = UserPreferences.getOrCreate(in: modelContext)
  }

  private var themingSection: some View {
    Section {
      NavigationLink {
        ThemeSelectorView()
      } label: {
        HStack {
          Label("Appearance", systemImage: "paintpalette")
          Spacer()
          Text(userPreferences?.selectedTheme.displayName ?? "Ampwave")
            .foregroundStyle(.secondary)
        }
      }
    } header: {
      Text("Theming")
    }
  }

  private var layoutSection: some View {
    Section {
      if let preferences = userPreferences {
        Toggle(
          "Full Artwork Background",
          isOn: Binding(
            get: { preferences.fullArtworkBackground ?? false },
            set: { preferences.fullArtworkBackground = $0 }
          ))

        Toggle(
          "Player Card",
          isOn: Binding(
            get: { preferences.openPlayerGlassBackground ?? true },
            set: { preferences.openPlayerGlassBackground = $0 }
          ))

        Toggle(isOn: Binding(
          get: { preferences.coverArtAccentPlayer ?? false },
          set: { preferences.coverArtAccentPlayer = $0 }
        )) {
          VStack(alignment: .leading, spacing: 2) {
            Text("Cover Art Accent")
            Text("Tints the player background and card with the dominant color extracted from the current song's artwork. With Player Card on, the card gets a colored tint and glow. With Player Card off, the entire player background shifts to the artwork color.")
              .font(.caption)
              .foregroundStyle(.secondary)
          }
        }

        Toggle(isOn: Binding(
          get: { preferences.coloredSurfaces ?? true },
          set: { preferences.coloredSurfaces = $0 }
        )) {
          VStack(alignment: .leading, spacing: 2) {
            Text("Show Surfaces")
            Text("When off, cards and buttons show only images and text, no glass or color backgrounds")
              .font(.caption)
              .foregroundStyle(.secondary)
          }
        }

        //        if preferences.fullArtworkBackground ?? false {
        //          Toggle(
        //            "Show Background Gradient",
        //            isOn: Binding(
        //              get: { preferences.showFullArtworkGradient ?? false },
        //              set: { preferences.showFullArtworkGradient = $0 }
        //            ))
        //        }

        //        Toggle("Mini Player Floating", isOn: Binding(
        //          get: { preferences.miniPlayerFloating ?? false },
        //          set: { preferences.miniPlayerFloating = $0 }
        //        ))
      }

    } header: {
      Text("Layout")
    }
  }

  private var importSection: some View {
    Section {
      Button {
        activeImport = .file
        isShowingImporter = true
      } label: {
        Label("Import Songs", systemImage: "square.and.arrow.down")
      }
      .disabled(isImporting)

      Button {
        activeImport = .folder
        isShowingImporter = true
      } label: {
        Label("Import Folder", systemImage: "folder.badge.plus")
      }
      .disabled(isImporting)

      Button {
        activeImport = .playlist
        isShowingImporter = true
      } label: {
        Label("Import Playlist", systemImage: "music.note.list")
      }
      .disabled(isImporting)

      if case .indexing(let message) = library.indexingStatus {
        VStack(alignment: .leading, spacing: 8) {
          HStack {
            ProgressView()
              .scaleEffect(0.8)
            Text(message)
              .foregroundStyle(.secondary)
          }
        }
      } else if case .fetchingMetadata(let current, let total) = library.indexingStatus {
        VStack(alignment: .leading, spacing: 8) {
          HStack {
            ProgressView()
              .scaleEffect(0.8)
            if total > 1 {
              Text("Fetching metadata (\(current + 1)/\(total))…")
                .foregroundStyle(.secondary)
            } else {
              Text("Fetching metadata…")
                .foregroundStyle(.secondary)
            }
          }
        }
      } else if isImporting {
        VStack(alignment: .leading, spacing: 8) {
          HStack {
            ProgressView()
              .scaleEffect(0.8)
            Text("Importing…")
              .foregroundStyle(.secondary)
          }
        }
      }

      if let error = importError {
        Text(error)
          .font(.system(size: 12))
          .foregroundStyle(.red)
      }
    } header: {
      Text("Import")
    } footer: {
      if userPreferences?.copyMusicToStorage ?? true {
        Text(
          "Import audio files (MP3, FLAC, WAV, etc.) to your library. Files are copied to the app's storage."
        )
      } else {
        Text(
          "Import audio files to your library. Files stay in their original location, and the app stores references to them."
        )
      }
    }
  }

  private var libraryStatsSection: some View {
    Section {
      HStack {
        Label("Songs", systemImage: "music.note")
        Spacer()
        Text("\(library.songs.count)")
          .foregroundStyle(.secondary)
      }

      HStack {
        Label("Albums", systemImage: "square.stack")
        Spacer()
        Text("\(library.albums.count)")
          .foregroundStyle(.secondary)
      }

      HStack {
        Label("Playlists", systemImage: "list.bullet")
        Spacer()
        Text("\(playlistManager.playlists.count)")
          .foregroundStyle(.secondary)
      }

      HStack {
        Label("Total Listening Time", systemImage: "clock")
        Spacer()
        Text(
          formatListeningTime(historyTracker.getTotalListeningTime())
        )
        .foregroundStyle(.secondary)
      }
    } header: {
      Text("Library Statistics")
    }
  }

  private var appleWatchSection: some View {
    Section {
      NavigationLink {
        WatchSyncSettingsView()
      } label: {
        Label("Apple Watch Sync", systemImage: "applewatch")
      }
    } header: {
      Text("Apple Watch")
    } footer: {
      Text("Manage songs and playlists synced to your Apple Watch.")
    }
  }

  private var playbackSettingsSection: some View {
    Section {
      if let preferences = userPreferences {
        Toggle(
          "Gapless Playback",
          isOn: Binding(
            get: { preferences.gaplessPlayback },
            set: { preferences.gaplessPlayback = $0 }
          )
        )

        Toggle(
          "Normalize Volume",
          isOn: Binding(
            get: { preferences.normalizeVolume },
            set: {
              preferences.normalizeVolume = $0
              PlaybackController.shared.refreshAudioEnhancementsFromSettings()
            }
          )
        )

        Picker(
          "Default Shuffle",
          selection: Binding(
            get: { preferences.defaultShuffleMode },
            set: { preferences.defaultShuffleMode = $0 }
          )
        ) {
          ForEach(ShuffleMode.allCases, id: \.self) { mode in
            Text(mode.displayName).tag(mode)
          }
        }

        Picker(
          "Default Repeat",
          selection: Binding(
            get: { preferences.defaultRepeatMode },
            set: { preferences.defaultRepeatMode = $0 }
          )
        ) {
          ForEach(RepeatMode.allCases, id: \.self) { mode in
            Text(mode.displayName).tag(mode)
          }
        }
      }

      NavigationLink {
        EqualizerSettingsView()
      } label: {
        HStack {
          Label("Equalizer", systemImage: "slider.horizontal.3")
          Spacer()
          if EQManager.shared.isEnabled {
            Text(EQManager.shared.currentPresetName)
              .font(.caption)
              .foregroundStyle(.secondary)
          } else {
            Text("Off")
              .font(.caption)
              .foregroundStyle(.secondary)
          }
        }
      }

    } header: {
      Text("Playback")
    } footer: {
      Text(
        "Playback stays intentionally simple here: focus is on gapless listening, volume consistency, and reliable queue behavior."
      )
    }
  }

  private var librarySettingsSection: some View {
    Section {
      if let settings = settings {
        Toggle(
          "Group by Album",
          isOn: Binding(
            get: { settings.groupSongsByAlbum },
            set: { newValue in
              settings.groupSongsByAlbum = newValue
              saveSettings()
            }
          )
        )

        Toggle(
          "Merge Duplicate Albums",
          isOn: Binding(
            get: { settings.mergeAlbumDuplicates },
            set: { newValue in
              settings.mergeAlbumDuplicates = newValue
              saveSettings()
            }
          )
        )
      }

      if let preferences = userPreferences {
        Toggle(
          "Show Lyrics by Default",
          isOn: Binding(
            get: { preferences.showLyricsByDefault },
            set: { preferences.showLyricsByDefault = $0 }
          )
        )

        Toggle(
          "Word-synced Lyrics",
          isOn: Binding(
            get: { preferences.wordSyncedLyricsEnabled },
            set: { preferences.wordSyncedLyricsEnabled = $0 }
          )
        )

        Toggle(
          "Copy Imported Music",
          isOn: Binding(
            get: { preferences.copyMusicToStorage },
            set: { preferences.copyMusicToStorage = $0 }
          )
        )

        Toggle(
          "Live Library Monitoring",
          isOn: Binding(
            get: { LibraryMonitorService.shared.isEnabled },
            set: { LibraryMonitorService.shared.isEnabled = $0 }
          )
        )
      }
    } header: {
      Text("Library")
    } footer: {
      Text(
        "Turn off 'Copy Imported Music' to keep files in their original location; the app will reference them instead."
      )
    }
  }

  private var onlineFeaturesSection: some View {
    Section {
      if let preferences = userPreferences {
        Toggle(
          "Auto-fetch Metadata",
          isOn: Binding(
            get: { preferences.autoFetchMetadata },
            set: { preferences.autoFetchMetadata = $0 }
          )
        )

        Toggle(
          "Auto-fetch Lyrics",
          isOn: Binding(
            get: { preferences.autoFetchLyrics },
            set: { preferences.autoFetchLyrics = $0 }
          )
        )

        Toggle(
          "Prefer Online Artwork",
          isOn: Binding(
            get: { preferences.preferOnlineArtwork },
            set: { preferences.preferOnlineArtwork = $0 }
          )
        )

        Toggle(
          "Prefer Embedded Artwork",
          isOn: Binding(
            get: { preferences.preferEmbeddedArtwork },
            set: { preferences.preferEmbeddedArtwork = $0 }
          )
        )

        Toggle(
          "Enable Recommendations",
          isOn: Binding(
            get: { preferences.enableRecommendations },
            set: { preferences.enableRecommendations = $0 }
          )
        )
      }

      HStack {
        Label("Network Status", systemImage: "network")
        Spacer()
        NetworkStatusView()
      }
    } header: {
      Text("Online Features")
    } footer: {
      Text(
        "When online, the app can fetch metadata, lyrics, and artwork from online sources. All data is cached for offline use."
      )
    }
  }

  private var dataSourcesSection: some View {
    Section {
      Link(destination: URL(string: "https://musicbrainz.org")!) {
        HStack {
          Label("MusicBrainz", systemImage: "music.note.list")
          Spacer()
          Text("Metadata")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
      }

      Link(destination: URL(string: "https://coverartarchive.org")!) {
        HStack {
          Label("Cover Art Archive", systemImage: "photo.stack")
          Spacer()
          Text("Artwork")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
      }

      Link(destination: URL(string: "https://www.theaudiodb.com")!) {
        HStack {
          Label("TheAudioDB", systemImage: "music.mic")
          Spacer()
          Text("Biography & Fanart")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
      }

      Link(destination: URL(string: "https://lrclib.net")!) {
        HStack {
          Label("LRCLIB", systemImage: "quote.bubble")
          Spacer()
          Text("Synced Lyrics")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
      }

      Link(destination: URL(string: "https://lyrics.ovh")!) {
        HStack {
          Label("Lyrics.ovh", systemImage: "text.alignleft")
          Spacer()
          Text("Plain Lyrics")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
      }
    } header: {
      Text("Data Sources")
    } footer: {
      Text(
        "Ampwave uses these open-source community databases for high-quality metadata, artwork, and lyrics."
      )
    }
  }

  private var dataManagementSection: some View {
    Section {
      NavigationLink {
        DuplicateManagementView()
      } label: {
        Label("Manage Duplicates", systemImage: "rectangle.on.rectangle")
      }

      NavigationLink {
        MetadataQueueView()
      } label: {
        Label("Review Missing Metadata", systemImage: "questionmark.circle")
      }

      if let backupExportURL {
        ShareLink(
          item: backupExportURL,
          subject: Text("Ampwave Backup"),
          message: Text("Versioned library-state backup exported from Ampwave."),
          preview: SharePreview(
            "Ampwave Backup",
            icon: Image(systemName: "externaldrive.badge.checkmark")
          )
        ) {
          Label("Share Latest Backup", systemImage: "square.and.arrow.up")
        }
      }

      Button {
        exportBackup()
      } label: {
        Label("Export Backup", systemImage: "externaldrive.badge.plus")
      }

      Button {
        activeImport = .backup
        isShowingImporter = true
      } label: {
        Label("Restore Backup", systemImage: "arrow.clockwise.icloud")
      }

      Button {
        showingClearCacheConfirmation = true
      } label: {
        Label("Clear Cache", systemImage: "trash")
      }

      Button {
        Task {
          await refreshAllMetadata()
        }
      } label: {
        Label("Refresh All Metadata", systemImage: "arrow.clockwise")
      }

      Button(role: .destructive) {
        showingResetConfirmation = true
      } label: {
        Label("Reset Library", systemImage: "exclamationmark.triangle")
      }

      Button(role: .destructive) {
        showingResetStatsConfirmation = true
      } label: {
        Label(
          "Reset Statistics",
          systemImage:
            "exclamationmark.arrow.trianglehead.2.clockwise.rotate.90"
        )
      }
    } header: {
      Text("Data Management")
    }
  }

  private var aboutSection: some View {
    Section {
      HStack {
        Label("Version", systemImage: "info.circle")
        Spacer()
        Text("\(version ?? "-") (\(build ?? "-"))")
          .foregroundStyle(.secondary)
      }

      HStack {
        Label("Build Type", systemImage: "wrench.and.screwdriver")
        Spacer()
        Text(buildConfiguration)
          .foregroundStyle(.secondary)
      }

      Link(
        destination: URL(string: "https://github.com/omeasraf/ampwave")!
      ) {
        Label("GitHub", image: "github.fill")
      }

      Link(
        destination: URL(
          string: "https://discord.com/invite/gKChVVHRKW"
        )!
      ) {
        Label("Discord", image: "discord")
      }

      Link(
        destination: URL(
          string:
            "https://github.com/omeasraf/AmpwaveDocs/blob/main/privacy.md"
        )!
      ) {
        Label("Privacy Policy", systemImage: "hand.raised")
      }

      Button {
        showingOnboarding = true
      } label: {
        Label("View Setup Guide", systemImage: "sparkles")
      }
    } header: {
      Text("About")
    }
  }

  private func handleFileImport(_ result: Result<[URL], Error>) async {
    importError = nil
    isImporting = true
    importProgress = 0

    do {
      let urls = try result.get()
      guard !urls.isEmpty else {
        isImporting = false
        return
      }

      // Start security-scoped access for every picked URL so the app can
      // read files outside its sandbox. Mirror the pattern used in folder import.
      let accessed = urls.filter { $0.startAccessingSecurityScopedResource() }
      defer { accessed.forEach { $0.stopAccessingSecurityScopedResource() } }

      if library.modelContext == nil {
        library.setModelContext(modelContext)
      }

      await library.importFiles(urls)
      importProgress = 1.0

    } catch {
      importError = error.localizedDescription
    }

    isImporting = false
  }

  private func exportBackup() {
    do {
      backupExportURL = try LibraryBackupService.exportBackup(from: modelContext)
    } catch {
      importError = "Backup export failed: \(error.localizedDescription)"
    }
  }

  private func handleBackupImport(_ result: Result<[URL], Error>) async {
    importError = nil

    do {
      guard let url = try result.get().first else { return }
      let secured = url.startAccessingSecurityScopedResource()
      defer {
        if secured { url.stopAccessingSecurityScopedResource() }
      }

      let data = try Data(contentsOf: url)
      let summary = try LibraryBackupService.importBackup(data: data, into: modelContext)
      importError = summary.userFacingText
      await library.loadSongs()
      await playlistManager.loadPlaylists()
    } catch {
      importError = "Backup restore failed: \(error.localizedDescription)"
    }
  }

  private func handleFolderImport(_ result: Result<[URL], Error>) async {
    importError = nil
    isImporting = true
    importProgress = 0

    do {
      let urls = try result.get()
      guard let folderURL = urls.first else {
        isImporting = false
        return
      }

      // Start accessing the security-scoped resource
      let secured = folderURL.startAccessingSecurityScopedResource()
      defer {
        if secured {
          folderURL.stopAccessingSecurityScopedResource()
        }
      }

      let fileManager = FileManager.default
      var audioFiles: [URL] = []

      // Resource keys we want to pre-fetch for efficiency
      let keys: [URLResourceKey] = [.isRegularFileKey, .isDirectoryKey]

      guard
        let enumerator = fileManager.enumerator(
          at: folderURL,
          includingPropertiesForKeys: keys,
          options: [.skipsHiddenFiles, .skipsPackageDescendants]
        )
      else {
        isImporting = false
        return
      }

      let extensions = [
        "mp3", "m4a", "aac", "flac", "wav", "ogg", "opus", "aiff",
        "wma", "alac", "m4b",
      ]

      for case let fileURL as URL in enumerator {
        let ext = fileURL.pathExtension.lowercased()
        if extensions.contains(ext) {
          audioFiles.append(fileURL)
        }
      }

      if !audioFiles.isEmpty {
        if library.modelContext == nil {
          library.setModelContext(modelContext)
        }

        await library.importFiles(audioFiles)
        importProgress = 1.0
      }

    } catch {
      importError = error.localizedDescription
    }

    isImporting = false
  }

  private func handlePlaylistImport(_ result: Result<[URL], Error>) async {
    importError = nil
    switch result {
    case .success(let urls):
      guard let url = urls.first else { return }
      let secured = url.startAccessingSecurityScopedResource()
      defer {
        if secured {
          url.stopAccessingSecurityScopedResource()
        }
      }
      do {
        let data = try Data(contentsOf: url)
        if library.modelContext == nil {
          library.setModelContext(modelContext)
        }
        _ = try PlaylistImportExport.importPlaylist(
          data: data,
          sourceURL: url,
          into: modelContext,
          library: library
        )
        try modelContext.save()
      } catch {
        importError = error.localizedDescription
      }
    case .failure(let error):
      importError = error.localizedDescription
    }
  }

  private func fetchMetadataForNewSongs() async {
    await library.fetchMetadataForNewSongs()
  }

  private func refreshAllMetadata() async {
    await library.refreshAllMetadata()
  }

  private func clearCache() {
    let artworkCacheDir = library.artworkCacheDirectory
    try? FileManager.default.removeItem(at: artworkCacheDir)
    try? FileManager.default.createDirectory(
      at: artworkCacheDir,
      withIntermediateDirectories: true
    )
  }

  private func resetLibrary() {
    isResetting = true
    print("[DEBUG] SettingsView.resetLibrary: Starting full reset")

    Task {
      // ── 1. Delete SwiftData records ───────────────────────────────────────
      // We fetch-and-delete each type individually rather than using the batch
      // `delete(model:)` API, which can throw silently due to relationship
      // constraint conflicts and leaves data intact.
      //
      // Deletion order matters: delete child/dependent records first so that
      // parent relationships are already nullified when parents are removed.
      //
      // Stats (ListeningHistory, SongPlayStatistics) are intentionally KEPT.

      // SyncedLyric — depends on LibrarySong.id, must go first
      deleteAll(SyncedLyric.self)

      // PlaybackState — references song UUIDs; clear so no dangling references
      deleteAll(PlaybackState.self)

      // LibrarySong — nullifies Album.songs and Playlist.songs via inverse relationships
      deleteAll(LibrarySong.self)

      // Album, Artist, Playlist — safe to delete once songs are gone
      deleteAll(Album.self)
      deleteAll(Artist.self)
      deleteAll(Playlist.self)

      // ── 2. Save ───────────────────────────────────────────────────────────
      do {
        try modelContext.save()
        print("[DEBUG] SettingsView.resetLibrary: SwiftData save successful")
      } catch {
        print("[DEBUG] SettingsView.resetLibrary: SwiftData save error — \(error)")
      }

      // ── 3. Clear in-memory library state ──────────────────────────────────
      // Must happen before loadSongs() so the isLoaded guard doesn't skip the fetch.
      library.resetInMemoryState()

      // ── 4. Delete physical files & artwork cache ───────────────────────────
      clearCache()
      library.deleteAllFiles()

      // ── 5. Clear UserDefaults keys that would skip the next startup scan ──
      // lastDiskScanTime makes indexOnStartup skip if the directory looks unchanged.
      // Clearing it forces a full scan on next launch so no ghost data re-appears.
      let ud = UserDefaults.standard
      ud.removeObject(forKey: "com.ampwave.lastDiskScanTime")
      // One-time metadata backfill flag — let it re-run after a fresh import
      ud.removeObject(forKey: "Ampwave.fullMetadataBackfill.v1")
      // Also reset the indexing guard in SongLibrary so indexOnStartup runs cleanly
      ud.synchronize()

      // ── 6. Reload from (now empty) SwiftData ──────────────────────────────
      await library.loadSongs(force: true)
      await playlistManager.loadPlaylists()

      // ── 7. Reset onboarding + notify tab view ─────────────────────────────
      // OpenTabView's .libraryDidReset handler increments libraryResetID (tears
      // down all NavigationStacks), switches to Home, and after a short delay
      // presents OnboardingView — all from the stable, long-lived OpenTabView.
      OnboardingState.reset()
      NotificationCenter.default.post(name: .libraryDidReset, object: nil)

      isResetting = false
      print("[DEBUG] SettingsView.resetLibrary: Full reset completed")
    }
  }

  /// Fetch-and-delete every record of a given SwiftData model type.
  /// Using individual deletes (rather than the batch `delete(model:)` API) avoids
  /// silent failures from relationship constraint errors in SwiftData.
  private func deleteAll<T: PersistentModel>(_ type: T.Type) {
    do {
      let records = try modelContext.fetch(FetchDescriptor<T>())
      print("[DEBUG] SettingsView.resetLibrary: Deleting \(records.count) \(T.self) records")
      for record in records { modelContext.delete(record) }
    } catch {
      print("[DEBUG] SettingsView.resetLibrary: Error fetching \(T.self) — \(error)")
    }
  }

  private func resetStats() {
    isResetting = true

    // Delete history and statistics
    print(
      "[DEBUG] SettingsView.resetLibrary: Deleting history and stats"
    )
    do {
      let historyDescriptor = FetchDescriptor<ListeningHistory>()
      let allHistory = try modelContext.fetch(historyDescriptor)
      for history in allHistory {
        modelContext.delete(history)
      }
    } catch {
      print(
        "[DEBUG] SettingsView.resetLibrary: Error fetching history/stats: \(error)"
      )
    }

    // Reset listening history
    print("[DEBUG] SettingsView.resetStats: Resetting listening history")
    let statsDescriptor = FetchDescriptor<SongPlayStatistics>()
    do {
      let allStats = try modelContext.fetch(statsDescriptor)

      for stats in allStats {
        modelContext.delete(stats)
      }
    } catch {
      print(
        "[DEBUG] SettingsView.resetStats: Error fetching history/stats: \(error)"
      )
    }

    // Save and reload
    print("[DEBUG] SettingsView.resetStats: Saving changes")
    do {
      try modelContext.save()
      print("[DEBUG] SettingsView.resetStats: Save successful")
    } catch {
      print("[DEBUG] SettingsView.resetStats: Save error: \(error)")
    }
    print(
      "[DEBUG] SettingsView.resetStats: Listening history reset completed"
    )
    isResetting = false
  }

  private func saveSettings() {
    try? modelContext.save()
  }

  private func formatListeningTime(_ time: TimeInterval) -> String {
    let hours = Int(time) / 3600
    let minutes = (Int(time) % 3600) / 60

    if hours > 0 {
      return "\(hours)h \(minutes)m"
    } else {
      return "\(minutes)m"
    }
  }
}

// MARK: - Custom Theme Views

struct AddThemeView: View {
  @Environment(\.modelContext) private var modelContext
  @Query private var preferencesList: [UserPreferences]
  @Environment(ThemeManager.self) private var themeManager

  private var userPreferences: UserPreferences? {
    preferencesList.first
  }

  var body: some View {
    Form {
      if let preferences = userPreferences {
        Section("Theme Details") {
          Picker(
            "Color Scheme",
            selection: Binding(
              get: { preferences.customColorScheme ?? .dark },
              set: { preferences.customColorScheme = $0 }
            )
          ) {
            Text("Light").tag(ColorScheme.light)
            Text("Dark").tag(ColorScheme.dark)
          }
        }
        .listRowBackground(themeManager.cardBackgroundColor)

        Section("Custom Colors") {
          ColorPicker(
            "Accent Color",
            selection: Binding(
              get: { preferences.customAccentColorHex.map { Color(hex: $0) } ?? .pink },
              set: { preferences.customAccentColorHex = $0.toHex() }
            ))

          ColorPicker(
            "Background Color",
            selection: Binding(
              get: { preferences.customBackgroundColorHex.map { Color(hex: $0) } ?? .black },
              set: { preferences.customBackgroundColorHex = $0.toHex() }
            ))

          ColorPicker(
            "Card Background",
            selection: Binding(
              get: {
                preferences.customCardBackgroundColorHex.map { Color(hex: $0) } ?? Color(white: 0.1)
              },
              set: { preferences.customCardBackgroundColorHex = $0.toHex() }
            ))
        }
        .listRowBackground(themeManager.cardBackgroundColor)

        Section("Preview") {
          VStack(spacing: 12) {
            RoundedRectangle(cornerRadius: 12)
              .fill(
                preferences.customCardBackgroundColorHex.map { Color(hex: $0) } ?? Color(white: 0.1)
              )
              .frame(height: 60)
              .overlay {
                HStack {
                  Circle()
                    .fill(preferences.customAccentColorHex.map { Color(hex: $0) } ?? .pink)
                    .frame(width: 30, height: 30)
                  VStack(alignment: .leading) {
                    Text("Song Title")
                      .foregroundStyle(preferences.customColorScheme == .light ? .black : .white)
                    Text("Artist Name")
                      .font(.caption)
                      .foregroundStyle(.secondary)
                  }
                  Spacer()
                  Image(systemName: "play.fill")
                    .foregroundStyle(
                      preferences.customAccentColorHex.map { Color(hex: $0) } ?? .pink)
                }
                .padding()
              }
          }
          .padding(.vertical)
          .frame(maxWidth: .infinity)
          .background(preferences.customBackgroundColorHex.map { Color(hex: $0) } ?? .black)
          .clipShape(RoundedRectangle(cornerRadius: 16))
        }
        .listRowBackground(Color.clear)  // Keep preview clear

        Section {
          Button("Reset to Defaults") {
            preferences.customAccentColorHex = nil
            preferences.customBackgroundColorHex = nil
            preferences.customCardBackgroundColorHex = nil
          }
          .foregroundStyle(.red)
        }
        .listRowBackground(themeManager.cardBackgroundColor)
      }
    }
    .background(themeManager.backgroundColor)
    .scrollContentBackground(.hidden)
    .tint(themeManager.accentColor)
    .navigationTitle("Custom Colors")
    #if os(iOS)
      .navigationBarTitleDisplayMode(.inline)
    #endif
  }
}

// MARK: - Network Status View

struct NetworkStatusView: View {
  private let monitor = NetworkMonitor.shared

  var body: some View {
    HStack(spacing: 4) {
      Circle()
        .fill(statusColor)
        .frame(width: 8, height: 8)

      Text(statusText)
        .font(.system(size: 12))
    }
  }

  private var statusColor: Color {
    switch monitor.status {
    case .online: return .green
    case .offline: return .red
    case .unknown: return .gray
    }
  }

  private var statusText: String {
    switch monitor.status {
    case .online: return "Online"
    case .offline: return "Offline"
    case .unknown: return "Unknown"
    }
  }
}

// MARK: - Extensions

extension ShuffleMode {
  var displayName: String {
    switch self {
    case .off: return "Off"
    case .on: return "On"
    }
  }
}

extension RepeatMode {
  var displayName: String {
    switch self {
    case .off: return "Off"
    case .one: return "One"
    case .all: return "All"
    }
  }
}

// MARK: - Theme Selector View

struct ThemeSelectorView: View {
  @Environment(\.modelContext) private var modelContext
  @Environment(ThemeManager.self) private var themeManager
  @Query private var preferencesList: [UserPreferences]
  private var userPreferences: UserPreferences? { preferencesList.first }

  private let columns = [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())]

  var body: some View {
    ScrollView {
      VStack(spacing: 24) {
        // ── Theme grid ──────────────────────────────────────────────────────
        LazyVGrid(columns: columns, spacing: 12) {
          ForEach(AppTheme.allCases.filter { $0 != .custom }, id: \.self) { theme in
            themeCell(theme)
          }
        }
        .padding(.horizontal)

        // ── Custom theme ────────────────────────────────────────────────────
        NavigationLink {
          AddThemeView()
        } label: {
          HStack(spacing: 14) {
            ZStack {
              RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(themeManager.cardBackgroundColor)
                .frame(width: 52, height: 44)
              Image(systemName: "paintbrush.pointed.fill")
                .font(.system(size: 18))
                .foregroundStyle(themeManager.accentColor)
            }

            VStack(alignment: .leading, spacing: 2) {
              Text("Custom")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.primary)
              Text("Create your own colors")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            }

            Spacer()

            if userPreferences?.selectedTheme == .custom {
              Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(themeManager.accentColor)
                .font(.system(size: 20))
            }

            Image(systemName: "chevron.right")
              .font(.system(size: 12, weight: .semibold))
              .foregroundStyle(.tertiary)
          }
          .padding(14)
          .background(themeManager.cardBackgroundColor)
          .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
          .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
              .stroke(
                userPreferences?.selectedTheme == .custom
                  ? themeManager.accentColor : Color.clear,
                lineWidth: 1.5
              )
          }
        }
        .buttonStyle(.plain)
        .simultaneousGesture(TapGesture().onEnded {
          userPreferences?.selectedTheme = .custom
        })
        .padding(.horizontal)
      }
      .padding(.vertical)
    }
    .background(themeManager.backgroundColor)
    .scrollContentBackground(.hidden)
    .navigationTitle("Appearance")
    #if os(iOS)
      .navigationBarTitleDisplayMode(.large)
    #endif
  }

  private func themeCell(_ theme: AppTheme) -> some View {
    let config = theme.colors(isDark: true)
    let isSelected = userPreferences?.selectedTheme == theme

    return Button {
      userPreferences?.selectedTheme = theme
    } label: {
      VStack(spacing: 6) {
        // Colour preview
        ZStack {
          RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(config.background)
            .frame(height: 50)
          HStack(spacing: 5) {
            Circle().fill(config.accent).frame(width: 16, height: 16)
            Circle().fill(config.cardBackground).frame(width: 10, height: 10)
          }
        }
        .overlay(alignment: .topTrailing) {
          if isSelected {
            Image(systemName: "checkmark.circle.fill")
              .foregroundStyle(themeManager.accentColor)
              .font(.system(size: 15, weight: .bold))
              .offset(x: 4, y: -4)
              .shadow(color: .black.opacity(0.2), radius: 2)
          }
        }

        Text(theme.displayName)
          .font(.system(size: 11, weight: .semibold))
          .foregroundStyle(.primary)
          .lineLimit(1)
          .minimumScaleFactor(0.8)
      }
      .padding(8)
      .background(
        isSelected ? themeManager.accentColor.opacity(0.12) : themeManager.cardBackgroundColor
      )
      .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
      .overlay {
        RoundedRectangle(cornerRadius: 14, style: .continuous)
          .stroke(isSelected ? themeManager.accentColor : Color.clear, lineWidth: 1.5)
      }
    }
    .buttonStyle(.plain)
    .animation(.spring(duration: 0.2), value: isSelected)
  }
}

#Preview {
  NavigationStack {
    SettingsView()
  }
}
