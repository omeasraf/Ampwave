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
  @Binding var isPlayerExpanded: Bool
  @State private var selectedTab: AppTab = .home
  @State private var servicesInitialized = false

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

    var icon: String {
      switch self {
      case .home: return "house.fill"
      case .library: return "square.stack.fill"
      case .settings: return "gearshape.fill"
      case .search: return "magnifyingglass"
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
      }

      // Search tab (special role)
      Tab(value: AppTab.search, role: .search) {
        NavigationStack {
          SearchView()
        }
      }
    }

    .tabViewBottomAccessory {
      MiniPlayerView(isExpanded: $isPlayerExpanded)
    }
    .ignoresSafeArea(.keyboard)
    .safeAreaInset(edge: .top, spacing: 0) {
      IndexingStatusView()
    }
    .onAppear {
      // Only setup once to avoid redundant work
      guard !servicesInitialized else { return }
      servicesInitialized = true

      print("[DEBUG] OpenTabView.onAppear - Starting on thread: \(Thread.current.name)")

      // Minimal deferred setup - avoid blocking UI
      Task.detached(priority: .userInitiated) { [self] in
        print("[DEBUG] Background task started on thread: \(Thread.current.name)")

        // 1. Initial Context Setup
        await MainActor.run {
          print("[DEBUG] Setting model contexts on MainActor...")
          if self.library.modelContext == nil {
            self.library.setModelContext(self.modelContext)
          }
          if self.playlistManager.modelContext == nil {
            self.playlistManager.setModelContext(self.modelContext)
          }
          if self.historyTracker.modelContext == nil {
            self.historyTracker.setModelContext(self.modelContext)
          }
          if self.lyricsService.modelContext == nil {
            self.lyricsService.setModelContext(self.modelContext)
          }
          if self.metadataService.modelContext == nil {
            self.metadataService.setModelContext(self.modelContext)
          }
          if self.recommendationEngine.modelContext == nil {
            self.recommendationEngine.setModelContext(self.modelContext)
          }
        }

        // 2. Load songs first (needed for restoration)
        print("[DEBUG] Performing initial song load...")
        await library.loadSongs()

        // 3. Restore playback state on MainActor
        await MainActor.run {
          print("[DEBUG] Setting playbackController context and restoring state...")
          self.playbackController.setModelContext(self.modelContext)
        }

        // 4. Perform indexing
        print("[DEBUG] Starting indexOnStartup")
        await library.indexOnStartup()

        print("[DEBUG] Service initialization complete")
      }
    }
  }
}

// Custom floating tab bar removed in favor of native TabView

#Preview {
  OpenTabView(isPlayerExpanded: .constant(false))
}
