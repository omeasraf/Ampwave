//
//  CarPlaySceneDelegate.swift
//  Ampwave
//
//  Handles CarPlay scene connection and interface.
//

import CarPlay
import UIKit
import SwiftData

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
    
    func templateApplicationScene(_ scene: CPTemplateApplicationScene, didDisconnect controller: CPInterfaceController) {
        print("[DEBUG] CarPlay: Disconnected")
        self.interfaceController = nil
    }
    
    private func updateRootTemplate() {
        let recentlyPlayed = createRecentlyPlayedTemplate()
        let libraryTemplate = createLibraryTemplate()
        let playlistsTemplate = createPlaylistsTemplate()
        
        let tabBar = CPTabBarTemplate(templates: [recentlyPlayed, libraryTemplate, playlistsTemplate])
        interfaceController?.setRootTemplate(tabBar, animated: true, completion: nil)
    }
    
    // MARK: - Templates
    
    private func createRecentlyPlayedTemplate() -> CPListTemplate {
        let songs = ListeningHistoryTracker.shared.getRecentlyPlayed(limit: 20)
        
        let items = songs.map { song in
            let item = CPListItem(text: song.title, detailText: song.artist)
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
        // Just show a subset of songs for safety/performance in CarPlay
        let songs = library.songs.prefix(50)
        
        let items = songs.map { song in
            let item = CPListItem(text: song.title, detailText: song.artist)
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
        let template = CPListTemplate(title: "Library", sections: [section])
        template.tabImage = UIImage(systemName: "music.note.list")
        return template
    }
    
    private func createPlaylistsTemplate() -> CPListTemplate {
        let playlists = playlistManager.playlists
        
        let items = playlists.map { playlist in
            let item = CPListItem(text: playlist.name, detailText: "\(playlist.songs.count) songs")
            
            // Handle playlist selection - show songs in playlist
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
            item.handler = { [weak self] _, completion in
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
        return UIImage(contentsOfFile: url.path)
    }
}
