//
//  CarPlaySceneDelegate.swift
//  Ampwave
//
//  Modernized CarPlay interface with clean navigation and enhanced Now Playing controls.
//

#if os(iOS)
  import CarPlay
  import SwiftData
  import UIKit
  import Observation

  public class CarPlaySceneDelegate: UIResponder, CPTemplateApplicationSceneDelegate {
    var interfaceController: CPInterfaceController?

    // Use the shared services
    private let playback = PlaybackController.shared
    private let library = SongLibrary.shared
    private let playlistManager = PlaylistManager.shared

    // Observation storage
    private var nowPlayingButtons: [CPNowPlayingButton] = []

    public func templateApplicationScene(
      _ scene: CPTemplateApplicationScene, didConnect controller: CPInterfaceController
    ) {
      print("[DEBUG] CarPlay: Connected")
      self.interfaceController = controller

      // Configure standard Now Playing experience
      setupNowPlaying()

      // Setup initial interface
      updateRootTemplate()
    }

    public func templateApplicationScene(
      _ scene: CPTemplateApplicationScene, didDisconnect controller: CPInterfaceController
    ) {
      print("[DEBUG] CarPlay: Disconnected")
      self.interfaceController = nil
    }

    private func setupNowPlaying() {
      let nowPlaying = CPNowPlayingTemplate.shared

      // Initial button setup
      updateNowPlayingButtons()

      // Observe playback changes to update buttons
      observePlaybackChanges()

      // Enable top-level supplemental buttons
      nowPlaying.isUpNextButtonEnabled = true
      nowPlaying.upNextTitle = "Queue"
      nowPlaying.isAlbumArtistButtonEnabled = true

      nowPlaying.add(self)
    }

    private func observePlaybackChanges() {
      _ = withObservationTracking {
        _ = playback.currentItem
      } onChange: {
        Task { @MainActor in
          self.updateNowPlayingButtons()
          self.observePlaybackChanges()
        }
      }
    }

    @MainActor
    private func updateNowPlayingButtons() {
      let nowPlaying = CPNowPlayingTemplate.shared

      let shuffleButton = CPNowPlayingShuffleButton { _ in
        Task { @MainActor in
          self.playback.toggleShuffle()
          self.updateNowPlayingButtons()
        }
      }

      let repeatButton = CPNowPlayingRepeatButton { _ in
        Task { @MainActor in
          self.playback.cycleRepeatMode()
          self.updateNowPlayingButtons()
        }
      }

      let isLiked: Bool
      if let song = playback.currentItem {
        isLiked = playlistManager.isLiked(song: song)
      } else {
        isLiked = false
      }

      let likeButton = CPNowPlayingImageButton(
        image: UIImage(systemName: isLiked ? "heart.fill" : "heart")!
      ) { _ in
        Task { @MainActor in
          if let song = self.playback.currentItem {
            _ = self.playlistManager.toggleLike(song: song)
            self.updateNowPlayingButtons()
          }
        }
      }

      self.nowPlayingButtons = [shuffleButton, repeatButton, likeButton]
      nowPlaying.updateNowPlayingButtons(nowPlayingButtons)
    }

    private func updateRootTemplate() {
      let recentlyPlayed = createRecentlyPlayedTemplate()
      let libraryTemplate = createLibraryTemplate()
      let playlistsTemplate = createPlaylistsTemplate()
      let searchTemplate = CPSearchTemplate()
      searchTemplate.delegate = self

      let tabBar = CPTabBarTemplate(templates: [
        recentlyPlayed, libraryTemplate, playlistsTemplate, searchTemplate,
      ])
      interfaceController?.setRootTemplate(tabBar, animated: true, completion: nil)
    }

    // MARK: - Templates

    private func createRecentlyPlayedTemplate() -> CPListTemplate {
      let songs = ListeningHistoryTracker.shared.getRecentlyPlayed(limit: 24)

      let items = songs.map { song in
        let item = CPListItem(text: song.title, detailText: song.artist)
        item.setImage(loadUIImage(from: song.artworkPath, size: 60))
        item.accessoryType = .none
        item.handler = { [weak self] _, completion in
          Task { @MainActor in
            PlaybackController.shared.play(song, from: .library)
            completion()
          }
        }
        return item
      }

      let section = CPListSection(items: items)
      let template = CPListTemplate(title: "Listen Now", sections: [section])
      template.tabImage = UIImage(systemName: "play.circle.fill")
      return template
    }

    private func createLibraryTemplate() -> CPListTemplate {
      let items = [
        createLibraryNavigationItem(title: "Artists", systemImage: "music.mic") { [weak self] in
          self?.showArtists()
        },
        createLibraryNavigationItem(title: "Albums", systemImage: "square.stack") { [weak self] in
          self?.showAlbums()
        },
        createLibraryNavigationItem(title: "Songs", systemImage: "music.note") { [weak self] in
          self?.showAllSongs()
        },
      ]

      let section = CPListSection(items: items)
      let template = CPListTemplate(title: "Library", sections: [section])
      template.tabImage = UIImage(systemName: "music.note.list")
      return template
    }

    private func createLibraryNavigationItem(
      title: String, systemImage: String, action: @escaping () -> Void
    ) -> CPListItem {
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

    private func showArtists() {
      let artistNames = Array(Set(library.songs.map { $0.artist })).sorted()
      let items = artistNames.map { artistName in
        let item = CPListItem(text: artistName, detailText: nil)
        item.accessoryType = .disclosureIndicator
        item.handler = { [weak self] _, completion in
          Task { @MainActor in
            self?.showAlbumsByArtist(artistName)
            completion()
          }
        }
        return item
      }

      let section = CPListSection(items: items)
      let template = CPListTemplate(title: "Artists", sections: [section])
      interfaceController?.pushTemplate(template, animated: true, completion: nil)
    }

    private func showAlbumsByArtist(_ artistName: String) {
      let albums = library.albums.filter { $0.artist == artistName }.sorted { $0.name < $1.name }
      let items = albums.map { album in
        let item = CPListItem(text: album.name, detailText: album.artist)
        item.setImage(loadUIImage(from: album.artworkPath, size: 60))
        item.accessoryType = .disclosureIndicator
        item.handler = { [weak self] _, completion in
          Task { @MainActor in
            self?.showSongsInAlbum(album)
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
      let albums = library.albums.sorted { $0.name < $1.name }
      let items = albums.map { album in
        let item = CPListItem(text: album.name, detailText: album.artist)
        item.setImage(loadUIImage(from: album.artworkPath, size: 60))
        item.accessoryType = .disclosureIndicator
        item.handler = { [weak self] _, completion in
          Task { @MainActor in
            self?.showSongsInAlbum(album)
            completion()
          }
        }
        return item
      }

      let section = CPListSection(items: items)
      let template = CPListTemplate(title: "Albums", sections: [section])
      interfaceController?.pushTemplate(template, animated: true, completion: nil)
    }

    private func showSongsInAlbum(_ album: Album) {
      let songs = album.songs.sorted { ($0.trackNumber ?? 0) < ($1.trackNumber ?? 0) }
      let items = songs.map { song in
        let item = CPListItem(text: song.title, detailText: nil)
        item.handler = { _, completion in
          Task { @MainActor in
            PlaybackController.shared.play(song, from: .album)
            completion()
          }
        }
        return item
      }

      let section = CPListSection(items: items)
      let template = CPListTemplate(title: album.name, sections: [section])
      interfaceController?.pushTemplate(template, animated: true, completion: nil)
    }

    private func showAllSongs() {
      let songs = library.songs.sorted { $0.title < $1.title }.prefix(200)
      let items = songs.map { song in
        let item = CPListItem(text: song.title, detailText: song.artist)
        item.setImage(loadUIImage(from: song.artworkPath, size: 60))
        item.handler = { _, completion in
          Task { @MainActor in
            PlaybackController.shared.play(song, from: .library)
            completion()
          }
        }
        return item
      }

      let section = CPListSection(items: items)
      let template = CPListTemplate(title: "Songs", sections: [section])
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
        item.setImage(loadUIImage(from: song.artworkPath, size: 60))
        item.handler = { _, completion in
          Task { @MainActor in
            PlaybackController.shared.play(song, from: .playlist, playlistId: playlist.id)
            completion()
          }
        }
        return item
      }

      let section = CPListSection(items: items)
      let template = CPListTemplate(title: playlist.name, sections: [section])
      interfaceController?.pushTemplate(template, animated: true, completion: nil)
    }

    // MARK: - Helpers

    private func loadUIImage(from path: String?, size: CGFloat) -> UIImage? {
      guard let path = path, !path.isEmpty else { return nil }

      // Try to get from cache first
      if let cached = ImageCache.shared.image(for: path) {
        return cached
      }

      // Resolve and load from disk
      guard let url = PathManager.resolve(path),
        let data = try? Data(contentsOf: url),
        let image = UIImage(data: data)
      else {
        return nil
      }

      // Insert into cache for next time
      ImageCache.shared.insert(image, for: path)
      return image
    }
  }

  extension CarPlaySceneDelegate: CPNowPlayingTemplateObserver {
    public func nowPlayingTemplateUpNextButtonTapped(_ nowPlayingTemplate: CPNowPlayingTemplate) {
      // Show Queue
      let songs = PlaybackController.shared.upNext
      let items = songs.map { song in
        let item = CPListItem(text: song.title, detailText: song.artist)
        item.setImage(loadUIImage(from: song.artworkPath, size: 60))
        return item
      }

      let section = CPListSection(items: items)
      let template = CPListTemplate(title: "Up Next", sections: [section])
      interfaceController?.pushTemplate(template, animated: true, completion: nil)
    }

    public func nowPlayingTemplateAlbumArtistButtonTapped(
      _ nowPlayingTemplate: CPNowPlayingTemplate
    ) {
      // Show current album
      guard let song = PlaybackController.shared.currentItem,
        let album = library.albums.first(where: {
          $0.name == song.album && $0.artist == song.artist
        })
      else {
        return
      }
      showSongsInAlbum(album)
    }
  }

  extension CarPlaySceneDelegate: CPSearchTemplateDelegate {
    public func searchTemplate(
      _ searchTemplate: CPSearchTemplate, updatedSearchText searchText: String,
      completionHandler completion: @escaping ([CPListItem]) -> Void
    ) {
      guard searchText.count >= 2 else {
        completion([])
        return
      }

      // Filter songs based on search text
      let filteredSongs = library.songs.filter {
        $0.title.localizedCaseInsensitiveContains(searchText)
          || $0.artist.localizedCaseInsensitiveContains(searchText)
      }.prefix(24)

      let items = filteredSongs.map { song in
        let item = CPListItem(text: song.title, detailText: song.artist)
        item.setImage(loadUIImage(from: song.artworkPath, size: 60))
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

    public func searchTemplate(
      _ searchTemplate: CPSearchTemplate, selectedResult item: CPListItem,
      completionHandler completion: @escaping () -> Void
    ) {
      // Selection is handled by the item's handler
      completion()
    }
  }
#endif
