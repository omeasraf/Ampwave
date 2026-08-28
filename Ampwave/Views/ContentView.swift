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

  private var widgetThemeSignature: String {
    let preferences = themeManager.userPreferences
    return [
      themeManager.currentTheme.rawValue,
      preferences?.customBackgroundColorHex ?? "",
      preferences?.customAccentColorHex ?? "",
      preferences?.customCardBackgroundColorHex ?? "",
      preferences?.customColorSchemeRaw ?? "",
      themeManager.themeConfig.isDark ? "dark" : "light",
    ].joined(separator: "|")
  }

  var body: some View {
    ZStack {
      #if os(iOS)
        if isShowingLaunchSplash {
          LaunchSplashView()
            .transition(.opacity)
            .zIndex(1)
            .allowsHitTesting(true)
        } else {
          appContent
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
    #if os(iOS)
      .task {
        guard isShowingLaunchSplash else { return }
        let delay: UInt64 = reduceMotion ? 850_000_000 : 1_850_000_000
        async let minimumSplashTime: Void = waitForSplashDuration(delay)
        await initializeServices()
        await minimumSplashTime
        withAnimation(.easeInOut(duration: reduceMotion ? 0.15 : 0.42)) {
          isShowingLaunchSplash = false
        }
        startDeferredServices()
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

  /// Loads and reconciles the local library before revealing the app. Keeping
  /// the tab hierarchy unmounted prevents Home recommendation tasks from
  /// competing with the splash animation during launch.
  private func initializeServices() async {
    guard !servicesInitialized else { return }
    servicesInitialized = true

    // Let SwiftUI commit and animate the first splash frame before touching
    // the persistent store.
    await Task.yield()

    SongLibrary.shared.setModelContext(modelContext)
    PlaylistManager.shared.setModelContext(modelContext)
    ListeningHistoryTracker.shared.setModelContext(modelContext)
    LyricsService.shared.setModelContext(modelContext)
    MetadataService.shared.setModelContext(modelContext)
    RecommendationEngine.shared.setModelContext(modelContext)
    RadioMixGenerator.shared.setModelContext(modelContext)
    UserPreferences.sharedContextForNetworkCheck = modelContext
    LastFMScrobbler.shared.setModelContext(modelContext)
    WatchSyncService.shared.setModelContext(modelContext)
    _ = UserPreferences.getOrCreate(in: modelContext)
    WidgetSyncService.shared.refreshTheme()

    // Fetch the visible library, reconcile Ampwave's managed directory, then
    // reconcile live-monitored folders while the launch animation remains on
    // screen. Network metadata is deliberately deferred below.
    await SongLibrary.shared.loadSongs(performMaintenance: false)
    await SongLibrary.shared.indexOnStartup(performAutomaticMetadataFetch: false)
    await LibraryMonitorService.shared.startAndWaitForInitialReconciliation()
    PlaybackController.shared.setModelContext(modelContext)
    PlaybackController.shared.restoreStateAfterLoading()
  }

  private func startDeferredServices() {
    Task {
      // Let the splash fade finish before beginning optional online work.
      try? await Task.sleep(nanoseconds: 500_000_000)

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
