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

class CarPlaySceneDelegate: UIResponder, CPTemplateApplicationSceneDelegate {
    var interfaceController: CPInterfaceController?
    
    // Use the shared services
    private let playback = PlaybackController.shared
    private let library = SongLibrary.shared
    private let playlistManager = PlaylistManager.shared
    
    func templateApplicationScene(_ scene: CPTemplateApplicationScene, didConnect controller: CPInterfaceController) {
        print("[DEBUG] CarPlay: Connected")
        self.interfaceController = controller
        
        // Setup initial interface
        updateRootTemplate()
    }
    
    private func updateRootTemplate() {
        let recentlyPlayed = createRecentlyPlayedTemplate()
        let libraryTemplate = createLibraryTemplate()
        let playlistsTemplate = createPlaylistsTemplate()
        let searchTemplate = CPSearchTemplate()
        searchTemplate.delegate = self
        
        let tabBar = CPTabBarTemplate(templates: [recentlyPlayed, libraryTemplate, playlistsTemplate, searchTemplate])
        interfaceController?.setRootTemplate(tabBar, animated: true, completion: nil)
    }
    
    // MARK: - Templates
    
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
