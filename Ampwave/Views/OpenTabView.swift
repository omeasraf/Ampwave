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
  @Environment(ThemeManager.self) private var themeManager
  @Binding var isPlayerExpanded: Bool
  @State private var selectedTab: AppTab = .home
  @State private var showOnboarding = OnboardingState.shouldShow
  @State private var capsuleImportError: String?
  /// Incremented on library reset — causes all tab content to be recreated,
  /// clearing every NavigationStack and flushing any stale in-memory data.
  @State private var libraryResetID: Int = 0


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
        .id(libraryResetID)
      }

      // Library
      Tab(
        AppTab.library.rawValue,
        systemImage: AppTab.library.icon,
        value: AppTab.library
      ) {
        @Bindable var navigator = AppNavigator.shared
        NavigationStack(path: $navigator.libraryPath) {
          LibraryView()
            // Lets the player hand navigation over to this stack after it
            // collapses, instead of pushing inside its own cover.
            .navigationDestination(for: AppNavigator.Destination.self) { destination in
              switch destination {
              case .artist(let artist): ArtistView(artist: artist)
              case .album(let album): AlbumView(album: album)
              }
            }
        }
        .background(themeManager.backgroundColor)
        .id(libraryResetID)
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
        .id(libraryResetID)
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
        .id(libraryResetID)
      }

      //       Search tab (special role)
      Tab(value: AppTab.search, role: .search) {
        NavigationStack {
          SearchView()
        }
        .background(themeManager.backgroundColor)
        .id(libraryResetID)
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
    // The player pushes onto the Library stack, so follow it there.
    .onChange(of: AppNavigator.shared.libraryPath) { oldPath, newPath in
      if newPath.count > oldPath.count { selectedTab = .library }
    }
    .onReceive(NotificationCenter.default.publisher(for: .libraryDidReset)) { notification in
      let isPreparingForReset =
        (notification.object as? [String: String])?["phase"] == "willReset"

      // 1. Tear down every tab's NavigationStack and jump to Home.
      //    Incrementing the ID forces SwiftUI to recreate all tab content views,
      //    clearing navigation stacks and flushing any stale @State referencing old data.
      // The path holds references to deleted models; recreating the tab isn't
      // enough because the navigator outlives it. During the preparation phase
      // clear that path but keep the current Settings view alive so its
      // non-dismissible reset progress overlay remains visible.
      AppNavigator.shared.reset()

      guard !isPreparingForReset else { return }

      libraryResetID += 1
      selectedTab = .home

      // The reset posts once before deleting SwiftData rows and once after the
      // new empty library has been loaded. Only the completion notification
      // should present onboarding.
      // 2. Show onboarding after a short delay so the tab recreation animation
      //    completes first. Presenting it here (on the stable OpenTabView) is
      //    reliable; setting it on SettingsView fails because SettingsView itself
      //    is recreated by the libraryResetID bump above.
      Task { @MainActor in
        try? await Task.sleep(nanoseconds: 400_000_000)  // 0.4 s
        showOnboarding = true
      }
    }
    .onReceive(NotificationCenter.default.publisher(for: .capsuleDidImport)) { _ in
      selectedTab = .playlists
    }
    .onReceive(NotificationCenter.default.publisher(for: .capsuleImportFailed)) { notification in
      capsuleImportError = notification.object as? String ?? "The Capsule could not be imported."
    }
    .alert("Couldn't Import Capsule", isPresented: capsuleImportAlertBinding) {
      Button("OK") { capsuleImportError = nil }
    } message: {
      Text(capsuleImportError ?? "The Capsule could not be imported.")
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

  private var capsuleImportAlertBinding: Binding<Bool> {
    Binding(
      get: { capsuleImportError != nil },
      set: { if !$0 { capsuleImportError = nil } }
    )
  }
}

// Custom floating tab bar removed in favor of native TabView

#Preview {
  OpenTabView(isPlayerExpanded: .constant(false))
}
