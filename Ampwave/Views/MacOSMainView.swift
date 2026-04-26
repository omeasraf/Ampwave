//
//  MacOSMainView.swift
//  Ampwave
//
//  MacOS-native root view with sidebar and top playback controls.
//

internal import SwiftUI
import SwiftData

struct MacOSMainView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.openWindow) private var openWindow
    @State private var selection: SidebarItem? = .home
    @State private var servicesInitialized = false
    
    @Bindable private var playback = PlaybackController.shared
    
    private var library: SongLibrary { SongLibrary.shared }
    private var playlistManager: PlaylistManager { PlaylistManager.shared }
    private var historyTracker: ListeningHistoryTracker { ListeningHistoryTracker.shared }
    private var lyricsService: LyricsService { LyricsService.shared }
    private var metadataService: MetadataService { MetadataService.shared }
    private var recommendationEngine: RecommendationEngine { RecommendationEngine.shared }
    
    enum SidebarItem: Hashable {
        case home
        case search
        case library
        case artists
        case albums
        case songs
        case playlists
        case playlist(Playlist)
        case settings
    }
    
    var body: some View {
        NavigationSplitView {
            SidebarView(selection: $selection)
        } detail: {
            DetailView(selection: $selection)
        }
        .toolbar {
            ToolbarItemGroup(placement: .navigation) {
                playbackControls
            }
            
            ToolbarItem(placement: .principal) {
                nowPlayingInfo
            }
            
            ToolbarItemGroup(placement: .primaryAction) {
                volumeControl
                
                Button {
                    openWindow(id: "lyrics")
                } label: {
                    Image(systemName: "quote.bubble")
                }
                .help("Lyrics")
            }
        }
        .onAppear {
            setupServices()
        }
    }
    
    private func setupServices() {
        guard !servicesInitialized else { return }
        servicesInitialized = true
        
        Task.detached(priority: .userInitiated) {
            await MainActor.run {
                if library.modelContext == nil { library.setModelContext(modelContext) }
                if playlistManager.modelContext == nil { playlistManager.setModelContext(modelContext) }
                if historyTracker.modelContext == nil { historyTracker.setModelContext(modelContext) }
                if lyricsService.modelContext == nil { lyricsService.setModelContext(modelContext) }
                if metadataService.modelContext == nil { metadataService.setModelContext(modelContext) }
                if recommendationEngine.modelContext == nil { recommendationEngine.setModelContext(modelContext) }
            }
            
            await library.loadSongs()
            
            await MainActor.run {
                playback.setModelContext(modelContext)
            }
            
            await library.indexOnStartup()
        }
    }
    
    private var playbackControls: some View {
        HStack(spacing: 8) {
            Button {
                playback.playPrevious()
            } label: {
                Image(systemName: "backward.fill")
            }
            
            Button {
                playback.playPause()
            } label: {
                Image(systemName: playback.isPlaying ? "pause.fill" : "play.fill")
            }
            .font(.title3)
            
            Button {
                playback.playNext()
            } label: {
                Image(systemName: "forward.fill")
            }
        }
        .buttonStyle(.plain)
        .frame(width: 100)
    }
    
    private var nowPlayingInfo: some View {
        VStack(spacing: 2) {
            if let item = playback.currentItem {
                HStack(spacing: 8) {
                    FixedArtworkThumbnail(artworkPath: item.artworkPath, size: 24)
                        .cornerRadius(4)
                    
                    VStack(alignment: .leading, spacing: 0) {
                        Text(item.title)
                            .font(.system(size: 11, weight: .semibold))
                            .lineLimit(1)
                        Text(item.artist)
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }
                .frame(width: 160)
                
                progressView
            } else {
                Text("Not Playing")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .frame(width: 160)
            }
        }
        .frame(width: 180)
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(Color.primary.opacity(0.06))
        .cornerRadius(6)
    }
    
    private var progressView: some View {
        let duration = playback.duration
        let progress = duration > 0 ? min(max(playback.currentTime / duration, 0), 1) : 0.0
        
        return Slider(
            value: Binding(
                get: { progress },
                set: { newValue in
                    playback.seek(to: newValue * duration)
                }
            ),
            in: 0...1
        )
        .controlSize(.mini)
        .frame(width: 160)
    }
    
    private var volumeControl: some View {
        HStack(spacing: 4) {
            Image(systemName: "speaker.fill")
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
            Slider(value: Binding(
                get: { Double(playback.volume) },
                set: { playback.volume = Float($0) }
            ), in: 0...1)
                .controlSize(.mini)
                .frame(width: 60)
            Image(systemName: "speaker.wave.3.fill")
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
        }
        .frame(width: 100)
    }
}

struct SidebarView: View {
    @Binding var selection: MacOSMainView.SidebarItem?
    @Query(sort: \Playlist.name) private var playlists: [Playlist]
    
    var body: some View {
        List(selection: $selection) {
            Section("Apple Music") {
                NavigationLink(value: MacOSMainView.SidebarItem.home) {
                    Label("Home", systemImage: "house")
                }
                NavigationLink(value: MacOSMainView.SidebarItem.search) {
                    Label("Search", systemImage: "magnifyingglass")
                }
            }
            
            Section("Library") {
                NavigationLink(value: MacOSMainView.SidebarItem.artists) {
                    Label("Artists", systemImage: "music.mic")
                }
                NavigationLink(value: MacOSMainView.SidebarItem.albums) {
                    Label("Albums", systemImage: "square.stack")
                }
                NavigationLink(value: MacOSMainView.SidebarItem.songs) {
                    Label("Songs", systemImage: "music.note")
                }
            }
            
            Section("Playlists") {
                ForEach(playlists) { playlist in
                    NavigationLink(value: MacOSMainView.SidebarItem.playlist(playlist)) {
                        Label(playlist.name, systemImage: "music.note.list")
                    }
                }
            }
            
            Section {
                NavigationLink(value: MacOSMainView.SidebarItem.settings) {
                    Label("Settings", systemImage: "gearshape")
                }
            }
        }
        .listStyle(.sidebar)
    }
}

struct DetailView: View {
    @Binding var selection: MacOSMainView.SidebarItem?
    @Query private var settings: [AppSettings]
    @Environment(\.modelContext) private var modelContext
    
    private var appSettings: AppSettings {
        settings.first ?? AppSettings.getOrCreate(in: modelContext)
    }
    
    var body: some View {
        NavigationStack {
            Group {
                switch selection {
                case .home:
                    HomeView()
                case .search:
                    SearchView()
                case .artists:
                    ArtistsListView(searchText: "")
                        .navigationTitle("Artists")
                        .toolbar {
                            LibrarySortMenu(selectedTab: .artists, appSettings: appSettings)
                        }
                case .albums:
                    AlbumsGridView(searchText: "")
                        .navigationTitle("Albums")
                        .toolbar {
                            LibrarySortMenu(selectedTab: .albums, appSettings: appSettings)
                        }
                case .songs:
                    SongsListView(searchText: "")
                        .navigationTitle("Songs")
                        .toolbar {
                            LibrarySortMenu(selectedTab: .songs, appSettings: appSettings)
                        }
                case .playlists:
                    PlaylistsListView()
                case .playlist(let playlist):
                    PlaylistView(playlist: playlist)
                case .settings:
                    SettingsView()
                case .none:
                    Text("Select an item")
                        .foregroundStyle(.secondary)
                case .library:
                    LibraryView()
                }
            }
        }
    }
}
