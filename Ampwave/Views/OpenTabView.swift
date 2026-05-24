//
//  OpenTabView.swift
//  Ampwave
//
//  Main tab view with Home, Search, Library, and Settings tabs.
//  iOS 26 Liquid Glass floating tab bar style.
//

import SwiftData
internal import SwiftUI

struct OpenTabView: View {
  @Environment(\.modelContext) private var modelContext
  @Environment(ThemeManager.self) private var themeManager
  @Binding var isPlayerExpanded: Bool
  @State private var selectedTab: AppTab = .home
  @State private var servicesInitialized = false
  @State private var showOnboarding = OnboardingState.shouldShow

  private var library: SongLibrary { SongLibrary.shared }
  private var playlistManager: PlaylistManager { PlaylistManager.shared }
  private var historyTracker: ListeningHistoryTracker { ListeningHistoryTracker.shared }
  private var lyricsService: LyricsService { LyricsService.shared }
  private var metadataService: MetadataService { MetadataService.shared }
  private var recommendationEngine: RecommendationEngine { RecommendationEngine.shared }
  private var playbackController: PlaybackController { PlaybackController.shared }

  enum AppTab: String, CaseIterable {
    case home = "Home"
    case library = "Library"
    case settings = "Settings"
    case search = "Search"
    case playlists = "Playlists"

    var icon: String {
      switch self {
      case .home: return "house.fill"
      case .library: return "square.stack.fill"
      case .settings: return "gearshape.fill"
      case .search: return "magnifyingglass"
      case .playlists: return "list.bullet.rectangle.portrait.fill"
      }
    }
  }

  var body: some View {
    TabView(selection: $selectedTab) {

      // Home
      Tab(
        AppTab.home.rawValue,
        systemImage: AppTab.home.icon,
        value: AppTab.home
      ) {
        NavigationStack {
          HomeView()
        }
        .background(themeManager.backgroundColor)
      }

      // Library
      Tab(
        AppTab.library.rawValue,
        systemImage: AppTab.library.icon,
        value: AppTab.library
      ) {
        NavigationStack {
          LibraryView()
        }
        .background(themeManager.backgroundColor)
      }

      // Playlists
      Tab(
        AppTab.playlists.rawValue,
        systemImage: AppTab.playlists.icon,
        value: AppTab.playlists
      ) {
        NavigationStack {
          PlaylistsListView()
        }
        .background(themeManager.backgroundColor)
      }

      // Settings
      Tab(
        AppTab.settings.rawValue,
        systemImage: AppTab.settings.icon,
        value: AppTab.settings
      ) {
        NavigationStack {
          SettingsView()
        }
        .background(themeManager.backgroundColor)
      }

      //       Search tab (special role)
      Tab(value: AppTab.search, role: .search) {
        NavigationStack {
          SearchView()
        }
        .background(themeManager.backgroundColor)
      }
    }

    #if os(iOS)
      .tabBarMinimizeBehavior(.onScrollDown)
      .tabViewBottomAccessory {
        MiniPlayerView(isExpanded: $isPlayerExpanded)
      }
    #else
      .safeAreaInset(edge: .bottom) {
        MiniPlayerView(isExpanded: $isPlayerExpanded)
          .background(.ultraThinMaterial)
      }
    #endif
    .ignoresSafeArea(.keyboard)
    //    .safeAreaInset(edge: .top, spacing: 0) {
    //      IndexingStatusView()
    //    }
    .overlay(alignment: .top) {
      IndexingStatusView()
    }
    .onAppear {
      // Only setup once to avoid redundant work
      guard !servicesInitialized else { return }
      servicesInitialized = true

      print("[DEBUG] OpenTabView.onAppear - Starting on thread: \(Thread.current.name)")

      // Structured initialization sequence
      Task {
        // 1. Initial Context Setup (MainActor)
        print("[DEBUG] Setting model contexts...")
        self.library.setModelContext(self.modelContext)
        self.playlistManager.setModelContext(self.modelContext)
        self.historyTracker.setModelContext(self.modelContext)
        self.lyricsService.setModelContext(self.modelContext)
        self.metadataService.setModelContext(self.modelContext)
        self.recommendationEngine.setModelContext(self.modelContext)
        #if os(iOS)
          WatchSyncService.shared.setModelContext(self.modelContext)
        #endif

        // Setup preferences and theme
        _ = UserPreferences.getOrCreate(in: self.modelContext)

        // 2. Load songs first (needed for restoration)
        print("[DEBUG] Loading songs...")
        await library.loadSongs()

        // 3. Restore playback state
        print("[DEBUG] Restoring playback state...")
        self.playbackController.setModelContext(self.modelContext)

        // 4. Perform indexing in background
        Task.detached(priority: .background) {
          print("[DEBUG] Starting background index...")
          await SongLibrary.shared.indexOnStartup()
          await SongLibrary.shared.runGenreBackfillOncePerInstall()
          print("[DEBUG] Background indexing complete")
        }

        print("[DEBUG] Service initialization complete")
      }
    }
    #if os(iOS)
      .fullScreenCover(isPresented: $showOnboarding) {
        Group {
          OnboardingView()
        }
        .environment(ThemeManager.shared)
      }
    #else
      .sheet(isPresented: $showOnboarding) {
        Group {
          OnboardingView()
        }
        .environment(ThemeManager.shared)
      }
    #endif
  }
}

// Custom floating tab bar removed in favor of native TabView

#Preview {
  OpenTabView(isPlayerExpanded: .constant(false))
}
