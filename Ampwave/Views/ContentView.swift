//
//  ContentView.swift
//  Ampwave
//
//  Main content view with mini player and full-screen player presentation.
//

import SwiftData
internal import SwiftUI

struct ContentView: View {
  @Environment(\.modelContext) private var modelContext
  @Environment(\.colorScheme) private var colorScheme
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(ThemeManager.self) private var themeManager
  @State private var isPlayerExpanded = false
  @State private var isShowingLaunchSplash = true
  @State private var servicesInitialized = false
  @State private var isPreparingUnlockedApp = false
  @State private var purchases = EntitlementManager.shared

  private var widgetThemeSignature: String {
    let preferences = themeManager.userPreferences
    let theme = themeManager.currentTheme.rawValue
    let background = preferences?.customBackgroundColorHex ?? ""
    let accent = preferences?.customAccentColorHex ?? ""
    let card = preferences?.customCardBackgroundColorHex ?? ""
    let primaryText = preferences?.customPrimaryTextColorHex ?? ""
    let secondaryText = preferences?.customSecondaryTextColorHex ?? ""
    let scheme = preferences?.customColorSchemeRaw ?? ""
    let resolvedScheme = themeManager.themeConfig.isDark ? "dark" : "light"
    return [theme, background, accent, card, primaryText, secondaryText, scheme, resolvedScheme]
      .joined(separator: "|")
  }

  var body: some View {
    ZStack {
      #if os(iOS)
        if isShowingLaunchSplash || (purchases.access.isUnlocked && !servicesInitialized) {
          LaunchSplashView()
            .transition(.opacity)
            .zIndex(1)
            .allowsHitTesting(true)
        } else if purchases.access.isUnlocked {
          appContent
            .transition(.opacity)
        } else {
          AccessGateView()
            .transition(.opacity)
        }
      #else
        appContent
      #endif
    }
    .onAppear {
      ThemeManager.shared.ampwaveColorScheme = colorScheme
      WidgetSyncService.shared.refreshTheme()
      print("[DEBUG] ContentView appeared")
    }
    .onChange(of: colorScheme) { _, newValue in
      ThemeManager.shared.ampwaveColorScheme = newValue
      WidgetSyncService.shared.refreshTheme()
    }
    .onChange(of: widgetThemeSignature) { _, _ in
      WidgetSyncService.shared.refreshTheme()
    }
    .onChange(of: purchases.access.isUnlocked) { _, isUnlocked in
      if isUnlocked {
        Task { await prepareUnlockedApp() }
      } else {
        PlaybackController.shared.pause()
        SiriPlaybackRouter.shared.stopExternalPlayback()
        isPlayerExpanded = false
      }
    }
    #if os(iOS)
      .task {
        await purchases.refresh()
        if purchases.access.isUnlocked {
          await prepareUnlockedApp()
        } else {
          withAnimation(.easeInOut(duration: 0.2)) { isShowingLaunchSplash = false }
        }
      }
    #endif
  }

  private var appContent: some View {
    ZStack {
      themeManager.backgroundColor.ignoresSafeArea()
      OpenTabView(isPlayerExpanded: $isPlayerExpanded)
    }
    #if os(iOS)
      .fullScreenCover(isPresented: $isPlayerExpanded) {
        OpenPlayerView()
      }
    #else
      .sheet(isPresented: $isPlayerExpanded) {
        OpenPlayerView()
      }
    #endif
  }

  private func waitForSplashDuration(_ nanoseconds: UInt64) async {
    try? await Task.sleep(nanoseconds: nanoseconds)
  }

  private func prepareUnlockedApp() async {
    guard !isPreparingUnlockedApp, purchases.access.isUnlocked else { return }
    isPreparingUnlockedApp = true
    defer { isPreparingUnlockedApp = false }
    isShowingLaunchSplash = true
    let delay: UInt64 = reduceMotion ? 850_000_000 : 1_850_000_000
    async let minimumSplashTime: Void = waitForSplashDuration(delay)
    if !servicesInitialized { await initializeServices() }
    await minimumSplashTime
    guard purchases.access.isUnlocked else { return }
    withAnimation(.easeInOut(duration: reduceMotion ? 0.15 : 0.42)) {
      isShowingLaunchSplash = false
    }
    startDeferredServices()
  }

  /// Loads the saved library before revealing the app. Keeping
  /// the tab hierarchy unmounted prevents Home recommendation tasks from
  /// competing with the splash animation during launch.
  private func initializeServices() async {
    guard !servicesInitialized else { return }
    servicesInitialized = true

    // Let SwiftUI commit and animate the first splash frame before touching
    // the persistent store.
    await Task.yield()

    SongLibrary.shared.setModelContext(modelContext, loadImmediately: false)
    PlaylistManager.shared.setModelContext(modelContext)
    ListeningHistoryTracker.shared.setModelContext(modelContext)
    LyricsService.shared.setModelContext(modelContext)
    MetadataService.shared.setModelContext(modelContext)
    RecommendationEngine.shared.setModelContext(modelContext)
    RadioMixGenerator.shared.setModelContext(modelContext)
    UserPreferences.sharedContextForNetworkCheck = modelContext
    LastFMScrobbler.shared.setModelContext(modelContext)
    WatchSyncService.shared.setModelContext(modelContext)
    RemoteLibraryService.shared.setModelContext(modelContext)
    _ = UserPreferences.getOrCreate(in: modelContext)
    WidgetSyncService.shared.refreshTheme()

    // Read saved records here. Provider scans and audio metadata extraction
    // must not hold the launch screen open; playback checks source availability
    // independently before restoring or starting any player item.
    // Songs are the only collection needed before the first interactive frame.
    // Albums/artists are loaded by finishDeferredLoading after the splash fade,
    // avoiding three back-to-back SwiftData fetches during the animation.
    await SongLibrary.shared.loadSongs(
      performMaintenance: false,
      includeCollections: false
    )
    WatchSyncService.shared.songLibraryDidLoad()
    PlaybackController.shared.setModelContext(modelContext)
  }

  private func startDeferredServices() {
    let generation = SongLibrary.shared.importGeneration
    Task {
      // Let the splash fade finish before beginning optional online work.
      try? await Task.sleep(nanoseconds: 500_000_000)
      guard !Task.isCancelled, generation == SongLibrary.shared.importGeneration,
        !SongLibrary.shared.isResetting else { return }
      await SongLibrary.shared.finishDeferredLoading()
      guard generation == SongLibrary.shared.importGeneration,
        !SongLibrary.shared.isResetting else { return }
      await RemoteLibraryService.shared.refreshAll(syncIfNeeded: true)
      guard generation == SongLibrary.shared.importGeneration,
        !SongLibrary.shared.isResetting else { return }
      LibraryMonitorService.shared.start()
      PlaybackController.shared.restoreStateAfterLoading()
      await SongLibrary.shared.indexOnStartup(performAutomaticMetadataFetch: false)
      LibraryMonitorService.shared.start()
      guard SongLibrary.shared.hasPendingMetadataWork else { return }
      Task.detached(priority: .background) {
        await SongLibrary.shared.resumeIncompleteMetadataFetches()
      }
    }
  }
}

#Preview {
  ContentView()
}
