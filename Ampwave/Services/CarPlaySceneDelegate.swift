//
//  CarPlaySceneDelegate.swift
//  Ampwave
//
//  Handles CarPlay scene connection and interface.
//

#if os(iOS)
import CarPlay
import SwiftData
import UIKit

@MainActor
class CarPlaySceneDelegate: UIResponder, CPTemplateApplicationSceneDelegate {
    var interfaceController: CPInterfaceController?
    private var observers: [Any] = []
    
    // Use the shared services
    private let playback = PlaybackController.shared
    private let library = SongLibrary.shared
    private let playlistManager = PlaylistManager.shared
    
    func templateApplicationScene(_ scene: CPTemplateApplicationScene, didConnect controller: CPInterfaceController) {
        print("[DEBUG] CarPlay: Connected")
        self.interfaceController = controller
        
        setupObservers()
        
        // Setup initial interface
        updateRootTemplate()
        
        // Trigger loading if library is empty
        if library.songs.isEmpty {
            Task {
                await library.loadSongs()
            }
        }
        
        if playlistManager.playlists.isEmpty {
            Task {
                await playlistManager.loadPlaylists()
            }
        }
    }
    
    func templateApplicationScene(_ scene: CPTemplateApplicationScene, didDisconnectFrom controller: CPInterfaceController) {
        print("[DEBUG] CarPlay: Disconnected")
        self.interfaceController = nil
        observers.removeAll()
    }
    
    private func setupObservers() {
        observers.append(NotificationCenter.default.addObserver(forName: SongLibrary.libraryDidUpdateNotification, object: nil, queue: .main) { [weak self] _ in
            print("[DEBUG] CarPlay: Library updated, refreshing root template")
            self?.updateRootTemplate()
        })
        
        observers.append(NotificationCenter.default.addObserver(forName: PlaylistManager.playlistsDidUpdateNotification, object: nil, queue: .main) { [weak self] _ in
            print("[DEBUG] CarPlay: Playlists updated, refreshing root template")
            self?.updateRootTemplate()
        })
        
        observers.append(NotificationCenter.default.addObserver(forName: PlaybackController.playbackStateDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            print("[DEBUG] CarPlay: Playback state changed, updating lyrics")
            self?.updateLyricsTab()
        })
        
        observers.append(NotificationCenter.default.addObserver(forName: PlaybackController.lyricIndexDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.updateLyricsTab()
        })
    }
    
    private func updateLyricsTab() {
        guard let interfaceController = interfaceController,
              let tabBar = interfaceController.rootTemplate as? CPTabBarTemplate else { return }
        
        // Find the lyrics template in the tab bar
        guard let lyricsTemplate = tabBar.templates.first(where: { $0.tabTitle == "Lyrics" }) as? CPListTemplate else { return }
        
        guard let song = playback.currentItem else {
            let section = CPListSection(items: [CPListItem(text: "Not Playing", detailText: nil)])
            lyricsTemplate.updateSections([section])
            return
        }
        
        guard let lyrics = playback.currentLyrics, !lyrics.lines.isEmpty else {
            let section = CPListSection(items: [CPListItem(text: "No lyrics available for this song", detailText: nil)])
            lyricsTemplate.updateSections([section])
            return
        }
        
        let currentIndex = playback.currentLyricIndex ?? 0
        
        // Show a window of lyrics around the current line for better at-a-glance viewing in CarPlay
        // This also avoids issues with long lists and ensures the current line is always visible
        let windowSize = 6
        let halfWindow = windowSize / 2
        
        var start = max(0, currentIndex - halfWindow)
        let end = min(lyrics.lines.count, start + windowSize)
        
        // Adjust start if we are near the end
        if end == lyrics.lines.count {
            start = max(0, end - windowSize)
        }
        
        let windowedLines = lyrics.lines[start..<end]
        
        let items = windowedLines.enumerated().map { offset, line in
            let index = start + offset
            let item = CPListItem(text: line.text, detailText: nil)
            if index == currentIndex {
                item.setImage(UIImage(systemName: "play.fill"))
                // Optional: add a visual indicator in text too
                item.setText("▶ \(line.text)")
            }
            return item
        }
        
        let section = CPListSection(items: items)
        
        // Add a "Show All Lyrics" item if we are windowing
        var footerItems: [CPListItem] = []
        if lyrics.lines.count > windowSize {
            let moreItem = CPListItem(text: "... more lyrics ...", detailText: "See full lyrics on iPhone")
            moreItem.isEnabled = false
            footerItems.append(moreItem)
        }
        
        var sections = [section]
        if !footerItems.isEmpty {
            sections.append(CPListSection(items: footerItems))
        }
        
        lyricsTemplate.updateSections(sections)
    }
    
    private func updateRootTemplate() {
        let recentlyPlayed = createRecentlyPlayedTemplate()
        let libraryTemplate = createLibraryTemplate()
        let playlistsTemplate = createPlaylistsTemplate()
        let searchTab = createSearchTabTemplate()
        let lyricsTab = createLyricsTabTemplate()
        
        let tabBar = CPTabBarTemplate(templates: [recentlyPlayed, libraryTemplate, playlistsTemplate, lyricsTab, searchTab])
        interfaceController?.setRootTemplate(tabBar, animated: true, completion: nil)
        
        // Initial update for lyrics if something is already playing
        updateLyricsTab()
    }
    
    // MARK: - Templates
    
    private func createLyricsTabTemplate() -> CPListTemplate {
        let template = CPListTemplate(title: "Lyrics", sections: [])
        template.tabImage = UIImage(systemName: "quote.bubble.fill")
        template.tabTitle = "Lyrics"
        
        // We will update this template dynamically when it's about to appear
        return template
    }
    
    private func createSearchTabTemplate() -> CPListTemplate {
        let item = CPListItem(text: "Search", detailText: "Search your library")
        item.setImage(UIImage(systemName: "magnifyingglass"))
        item.handler = { [weak self] _, completion in
            let searchTemplate = CPSearchTemplate()
            searchTemplate.delegate = self
            self?.interfaceController?.pushTemplate(searchTemplate, animated: true, completion: nil)
            completion()
        }
        
        let section = CPListSection(items: [item])
        let template = CPListTemplate(title: "Search", sections: [section])
        template.tabImage = UIImage(systemName: "magnifyingglass")
        return template
    }
    
    private func createRecentlyPlayedTemplate() -> CPListTemplate {
        let songs = ListeningHistoryTracker.shared.getRecentlyPlayed(limit: 20)
        
        let items = songs.map { song in
            let item = CPListItem(text: song.title, detailText: song.artist)
            item.accessoryType = .none
            item.setImage(loadUIImage(from: song.artworkPath))
            item.handler = { [weak self] _, completion in
                Task { @MainActor in
                    PlaybackController.shared.play(song, from: .library)
                    completion()
                }
            }
            return item
        }
        
        let section = CPListSection(items: items)
        let template = CPListTemplate(title: "Recent", sections: [section])
        template.tabImage = UIImage(systemName: "clock.fill")
        return template
    }
    
    private func createLibraryTemplate() -> CPListTemplate {
        let items = [
            createLibraryItem(title: "Songs", systemImage: "music.note", action: { [weak self] in self?.showAllSongs() }),
            createLibraryItem(title: "Artists", systemImage: "music.mic", action: { [weak self] in self?.showArtists() }),
            createLibraryItem(title: "Albums", systemImage: "square.stack", action: { [weak self] in self?.showAlbums() })
        ]
        
        let section = CPListSection(items: items)
        let template = CPListTemplate(title: "Library", sections: [section])
        template.tabImage = UIImage(systemName: "music.note.list")
        return template
    }
    
    private func createLibraryItem(title: String, systemImage: String, action: @escaping () -> Void) -> CPListItem {
        let item = CPListItem(text: title, detailText: nil)
        item.setImage(UIImage(systemName: systemImage))
        item.accessoryType = .disclosureIndicator
        item.handler = { _, completion in
            Task { @MainActor in
                action()
                completion()
            }
        }
        return item
    }
    
    private func showAllSongs() {
        let songs = library.songs.prefix(100)
        let items = songs.map { song in
            let item = CPListItem(text: song.title, detailText: song.artist)
            item.setImage(loadUIImage(from: song.artworkPath))
            item.handler = { _, completion in
                Task { @MainActor in
                    PlaybackController.shared.play(song, from: .library)
                    completion()
                }
            }
            return item
        }
        let section = CPListSection(items: items)
        let template = CPListTemplate(title: "All Songs", sections: [section])
        interfaceController?.pushTemplate(template, animated: true, completion: nil)
    }
    
    private func showArtists() {
        let artists = Array(Set(library.songs.map { $0.artist })).sorted()
        let items = artists.map { artistName in
            let item = CPListItem(text: artistName, detailText: nil)
            item.accessoryType = .disclosureIndicator
            item.handler = { [weak self] _, completion in
                Task { @MainActor in
                    self?.showSongsByArtist(artistName)
                    completion()
                }
            }
            return item
        }
        let section = CPListSection(items: items)
        let template = CPListTemplate(title: "Artists", sections: [section])
        interfaceController?.pushTemplate(template, animated: true, completion: nil)
    }
    
    private func showSongsByArtist(_ artistName: String) {
        let songs = library.songs.filter { $0.artist == artistName }
        let items = songs.map { song in
            let item = CPListItem(text: song.title, detailText: song.album)
            item.setImage(loadUIImage(from: song.artworkPath))
            item.handler = { _, completion in
                Task { @MainActor in
                    PlaybackController.shared.play(song, from: .library)
                    completion()
                }
            }
            return item
        }
        let section = CPListSection(items: items)
        let template = CPListTemplate(title: artistName, sections: [section])
        interfaceController?.pushTemplate(template, animated: true, completion: nil)
    }
    
    private func showAlbums() {
        let albums = Array(Set(library.songs.compactMap { $0.album })).sorted()
        let items = albums.map { albumName in
            let item = CPListItem(text: albumName, detailText: nil)
            item.accessoryType = .disclosureIndicator
            item.handler = { [weak self] _, completion in
                Task { @MainActor in
                    self?.showSongsInAlbum(albumName)
                    completion()
                }
            }
            return item
        }
        let section = CPListSection(items: items)
        let template = CPListTemplate(title: "Albums", sections: [section])
        interfaceController?.pushTemplate(template, animated: true, completion: nil)
    }
    
    private func showSongsInAlbum(_ albumName: String) {
        let songs = library.songs.filter { $0.album == albumName }
        let items = songs.map { song in
            let item = CPListItem(text: song.title, detailText: song.artist)
            item.setImage(loadUIImage(from: song.artworkPath))
            item.handler = { _, completion in
                Task { @MainActor in
                    PlaybackController.shared.play(song, from: .library)
                    completion()
                }
            }
            return item
        }
        let section = CPListSection(items: items)
        let template = CPListTemplate(title: albumName, sections: [section])
        interfaceController?.pushTemplate(template, animated: true, completion: nil)
    }
    
    private func createPlaylistsTemplate() -> CPListTemplate {
        let playlists = playlistManager.playlists
        
        let items = playlists.map { playlist in
            let item = CPListItem(text: playlist.name, detailText: "\(playlist.songs.count) songs")
            item.accessoryType = .disclosureIndicator
            item.handler = { [weak self] _, completion in
                Task { @MainActor in
                    self?.showPlaylistSongs(playlist)
                    completion()
                }
            }
            return item
        }
        
        let section = CPListSection(items: items)
        let template = CPListTemplate(title: "Playlists", sections: [section])
        template.tabImage = UIImage(systemName: "music.note.house.fill")
        return template
    }
    
    private func showPlaylistSongs(_ playlist: Playlist) {
        let items = playlist.songs.map { song in
            let item = CPListItem(text: song.title, detailText: song.artist)
            item.setImage(loadUIImage(from: song.artworkPath))
            item.handler = { _, completion in
                Task { @MainActor in
                    PlaybackController.shared.play(song, from: .playlist, playlistId: playlist.id)
                    completion()
                }
            }
            return item
        }
        
        let section = CPListSection(items: items)
        let listTemplate = CPListTemplate(title: playlist.name, sections: [section])
        interfaceController?.pushTemplate(listTemplate, animated: true, completion: nil)
    }
    
    // MARK: - Helpers
    
    private func loadUIImage(from path: String?) -> UIImage? {
        guard let path = path, let url = PathManager.resolve(path) else { return nil }
        // Use a smaller size for CarPlay to improve performance
        if let data = try? Data(contentsOf: url), let image = UIImage(data: data) {
            return image
        }
        return nil
    }
}

extension CarPlaySceneDelegate: CPSearchTemplateDelegate {
    func searchTemplate(_ searchTemplate: CPSearchTemplate, updatedSearchText searchText: String, completionHandler completion: @escaping ([CPListItem]) -> Void) {
        let songs = library.songs.filter { 
            $0.title.localizedCaseInsensitiveContains(searchText) || 
            $0.artist.localizedCaseInsensitiveContains(searchText)
        }.prefix(20)
        
        let items = songs.map { song in
            let item = CPListItem(text: song.title, detailText: song.artist)
            item.setImage(loadUIImage(from: song.artworkPath))
            item.handler = { _, completion in
                Task { @MainActor in
                    PlaybackController.shared.play(song, from: .library)
                    completion()
                }
            }
            return item
        }
        completion(Array(items))
    }
    
    func searchTemplate(_ searchTemplate: CPSearchTemplate, selectedResult item: CPListItem, completionHandler completion: @escaping () -> Void) {
        // Handle selection if needed, although we already have handlers on the items.
        // The item's handler will be called automatically by CarPlay if it's a CPListItem.
        completion()
    }
}
#endif
