//
//  SettingsView.swift
//  Ampwave
//

import SwiftData
internal import SwiftUI
import UniformTypeIdentifiers

enum ImportType {
  case file
  case folder
  case playlist
}

struct SettingsView: View {
  @Environment(\.modelContext) private var modelContext
  @State private var importType: ImportType?
  @State private var isShowingImporter = false
  @State private var importError: String?
  @State private var isImporting = false
  @State private var importProgress: Double = 0
  @State private var settings: AppSettings?
  @State private var userPreferences: UserPreferences?
  @State private var showingClearCacheConfirmation = false
  @State private var showingResetConfirmation = false
  @State private var showingResetStatsConfirmation = false
  @State private var isResetting = false

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

  private var allowedContentTypesForImport: [UTType] {
    switch importType {
    case .file:
      return [.audio]
    case .folder:
      return [.folder]
    case .playlist:
      return PlaylistImportExport.importableContentTypes
    case .none:
      return [.audio]
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
    .fileImporter(
      isPresented: $isShowingImporter,
      allowedContentTypes: allowedContentTypesForImport,
      allowsMultipleSelection: importType != .folder && importType != .playlist
    ) { result in
      let currentType = importType
      
      Task { @MainActor in
        switch currentType {
        case .file:
          await handleFileImport(result)
        case .folder:
          await handleFolderImport(result)
        case .playlist:
          await handlePlaylistImport(result)
        case .none:
          break
        }
        importType = nil
        isShowingImporter = false
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
      if let preferences = userPreferences {
        Picker(
          "App Theme",
          selection: Binding(
            get: { preferences.selectedTheme },
            set: { preferences.selectedTheme = $0 }
          )
        ) {
          ForEach(AppTheme.allCases) { theme in
            Text(theme.displayName).tag(theme)
          }
        }

        if preferences.selectedTheme == .custom {
          NavigationLink("Custom Colors") {
            AddThemeView()
          }
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

        if preferences.fullArtworkBackground ?? false {
          Toggle(
            "Show Background Gradient",
            isOn: Binding(
              get: { preferences.showFullArtworkGradient ?? false },
              set: { preferences.showFullArtworkGradient = $0 }
            ))
        }

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
        importType = .file
        isShowingImporter = true
      } label: {
        Label("Import Songs", systemImage: "square.and.arrow.down")
      }
      .disabled(isImporting)

      Button {
        importType = .folder
        isShowingImporter = true
      } label: {
        Label("Import Folder", systemImage: "folder.badge.plus")
      }
      .disabled(isImporting)

      Button {
        importType = .playlist
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
      Text(
        "Import audio files (MP3, FLAC, WAV, etc.) to your library. Files are copied to the app's storage."
      )
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
      }
    } header: {
      Text("Library")
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
      // Delete all Library Songs
      print("[DEBUG] SettingsView.resetLibrary: Deleting songs")
      for song in library.songs {
        modelContext.delete(song)
      }

      // Delete all Albums
      print("[DEBUG] SettingsView.resetLibrary: Deleting albums")
      for album in library.albums {
        modelContext.delete(album)
      }

      // Delete custom and smart playlists
      print("[DEBUG] SettingsView.resetLibrary: Deleting playlists")
      for playlist in playlistManager.playlists {
        if playlist.playlistType == .custom
          || playlist.playlistType == .smart
          || playlist.playlistType == .likedSongs
        {
          modelContext.delete(playlist)
        }
      }

      // Clear artwork cache and song files
      print(
        "[DEBUG] SettingsView.resetLibrary: Clearing artwork cache and song files"
      )
      clearCache()
      library.deleteAllFiles()

      // Save and reload
      print("[DEBUG] SettingsView.resetLibrary: Saving changes")
      do {
        try modelContext.save()
        print("[DEBUG] SettingsView.resetLibrary: Save successful")
      } catch {
        print("[DEBUG] SettingsView.resetLibrary: Save error: \(error)")
      }

      print(
        "[DEBUG] SettingsView.resetLibrary: Reloading library and playlists"
      )
      await library.loadSongs()
      await playlistManager.loadPlaylists()

      isResetting = false
      print("[DEBUG] SettingsView.resetLibrary: Full reset completed")
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
    .navigationBarTitleDisplayMode(.inline)
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

#Preview {
  NavigationStack {
    SettingsView()
  }
}
