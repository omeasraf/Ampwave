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
  import ImageIO

  public class CarPlaySceneDelegate: UIResponder, CPTemplateApplicationSceneDelegate {
    var interfaceController: CPInterfaceController?

    // Use the shared services
    private let playback = PlaybackController.shared
    private let library = SongLibrary.shared
    private let playlistManager = PlaylistManager.shared

    // Observation storage
    private var nowPlayingButtons: [CPNowPlayingButton] = []
    private var accessObserver: NSObjectProtocol?
    private var libraryObservers: [NSObjectProtocol] = []
    private var playlistsTemplate: CPListTemplate?

    public func templateApplicationScene(
      _ scene: CPTemplateApplicationScene, didConnect controller: CPInterfaceController
    ) {
      print("[DEBUG] CarPlay: Connected")
      self.interfaceController = controller

      accessObserver = NotificationCenter.default.addObserver(
        forName: .ampwaveAccessDidChange, object: nil, queue: .main
      ) { [weak self] _ in
        Task { @MainActor [weak self] in self?.updateRootTemplate() }
      }
      libraryObservers = [.playlistLibraryDidChange, .songLibraryDidChange].map { name in
        NotificationCenter.default.addObserver(
          forName: name, object: nil, queue: .main
        ) { [weak self] _ in
          Task { @MainActor [weak self] in self?.refreshPlaylistsTemplate() }
        }
      }

      // Configure standard Now Playing experience
      setupNowPlaying()

      // Setup initial interface
      updateRootTemplate()
    }

    public func templateApplicationScene(
      _ scene: CPTemplateApplicationScene,
      didDisconnectInterfaceController controller: CPInterfaceController
    ) {
      print("[DEBUG] CarPlay: Disconnected")
      CPNowPlayingTemplate.shared.remove(self)
      self.interfaceController = nil
      if let accessObserver {
        NotificationCenter.default.removeObserver(accessObserver)
        self.accessObserver = nil
      }
      libraryObservers.forEach(NotificationCenter.default.removeObserver)
      libraryObservers = []
      playlistsTemplate = nil
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

    private var playbackObservationTask: Task<Void, Never>?

    private func observePlaybackChanges() {
      playbackObservationTask?.cancel()
      playbackObservationTask = Task { @MainActor in
        while !Task.isCancelled {
          _ = withObservationTracking {
            playback.currentItem
          } onChange: {
            Task { @MainActor in
              self.updateNowPlayingButtons()
            }
          }
          // Wait for next change or cancellation
          try? await Task.sleep(nanoseconds: 1_000_000_000) // Poll every second as fallback, though Observation handles it
          if Task.isCancelled { break }
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
      guard EntitlementManager.shared.access.isUnlocked else {
        let item = CPListItem(
          text: "Open Ampwave to restore access",
          detailText: "Your music is safe on your iPhone"
        )
        let template = CPListTemplate(
          title: "Ampwave", sections: [CPListSection(items: [item])]
        )
        interfaceController?.setRootTemplate(template, animated: true, completion: nil)
        return
      }
      let recentlyPlayed = createRecentlyPlayedTemplate()
      let libraryTemplate = createLibraryTemplate()
      let playlistsTemplate = createPlaylistsTemplate()

      let tabBar = CPTabBarTemplate(templates: [
        recentlyPlayed, playlistsTemplate, libraryTemplate,
      ])
      interfaceController?.setRootTemplate(tabBar, animated: true, completion: nil)
    }

    // MARK: - Templates

    private func createRecentlyPlayedTemplate() -> CPListTemplate {
      let songs = library.visibleSongs(
        from: ListeningHistoryTracker.shared.getRecentlyPlayed(limit: 24)
      )

      let items = songs.enumerated().map { index, song in
        let item = CPListItem(text: song.title, detailText: song.artist)
        item.setImage(loadUIImage(from: song.effectiveArtworkPath, size: 60))
        item.accessoryType = .none
        item.handler = { _, completion in
          Task { @MainActor in
            PlaybackController.shared.playQueue(songs, startingAt: index, from: .library)
            completion()
          }
        }
        return item
      }

      let sections = playbackSections(for: songs, items: items, source: .library)
      let template = CPListTemplate(title: "Listen Now", sections: sections)
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
        createLibraryNavigationItem(title: "Search", systemImage: "magnifyingglass") { [weak self] in
          self?.showSearch()
        },
      ]

      let section = CPListSection(items: items)
      let template = CPListTemplate(title: "Library", sections: [section])
      template.tabImage = UIImage(systemName: "music.note.list")
      return template
    }

    private func showSearch() {
      let searchTemplate = CPSearchTemplate()
      searchTemplate.delegate = self
      interfaceController?.pushTemplate(searchTemplate, animated: true, completion: nil)
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
      // Optimization: Get artist names more efficiently if possible, but for now just ensure it's on a background task if it were bigger.
      // Since library.songs is already in memory, this is mostly CPU bound.
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
      let songs = library.visibleSongs(from: album.songs).sorted(by: LibrarySong.albumTrackOrder)
      let items = songs.enumerated().map { index, song in
        let item = CPListItem(text: song.title, detailText: nil)
        item.handler = { _, completion in
          Task { @MainActor in
            PlaybackController.shared.playQueue(songs, startingAt: index, from: .album)
            completion()
          }
        }
        return item
      }

      let sections = playbackSections(for: songs, items: items, source: .album)
      let template = CPListTemplate(title: album.name, sections: sections)
      interfaceController?.pushTemplate(template, animated: true, completion: nil)
    }

    private func showAllSongs() {
      let songs = Array(library.songs.sorted { $0.title < $1.title }.prefix(200))
      let items = songs.enumerated().map { index, song in
        let item = CPListItem(text: song.title, detailText: song.artist)
        item.setImage(loadUIImage(from: song.effectiveArtworkPath, size: 60))
        item.handler = { _, completion in
          Task { @MainActor in
            PlaybackController.shared.playQueue(songs, startingAt: index, from: .library)
            completion()
          }
        }
        return item
      }

      let sections = playbackSections(for: songs, items: items, source: .library)
      let template = CPListTemplate(title: "Songs", sections: sections)
      interfaceController?.pushTemplate(template, animated: true, completion: nil)
    }

    private func createPlaylistsTemplate() -> CPListTemplate {
      let template = CPListTemplate(title: "Playlists", sections: playlistSections())
      template.tabImage = UIImage(systemName: "music.note.house.fill")
      playlistsTemplate = template
      return template
    }

    private func refreshPlaylistsTemplate() {
      playlistsTemplate?.updateSections(playlistSections())
    }

    private func playlistSections() -> [CPListSection] {
      let playlists = playlistManager.playlists
      guard !playlists.isEmpty else {
        let item = CPListItem(
          text: playlistManager.modelContext == nil ? "Loading playlists…" : "No playlists yet",
          detailText: playlistManager.modelContext == nil
            ? "Your playlists will appear automatically"
            : "Create a playlist in Ampwave on your iPhone"
        )
        item.isEnabled = false
        return [CPListSection(items: [item])]
      }

      let items = playlists.map { playlist in
        let item = CPListItem(
          text: playlist.name, detailText: "\(playlist.orderedSongs.count) songs")
        item.accessoryType = .disclosureIndicator
        item.handler = { [weak self] _, completion in
          Task { @MainActor in
            self?.showPlaylistSongs(playlist)
            completion()
          }
        }
        return item
      }
      return [CPListSection(items: items)]
    }

    private func showPlaylistSongs(_ playlist: Playlist) {
      let songs = library.visibleSongs(from: playlist.orderedSongs)
      let items = songs.enumerated().map { index, song in
        let item = CPListItem(text: song.title, detailText: song.artist)
        item.setImage(loadUIImage(from: song.effectiveArtworkPath, size: 60))
        item.handler = { _, completion in
          Task { @MainActor in
            PlaybackController.shared.playQueue(
              songs, startingAt: index, from: .playlist, playlistId: playlist.id
            )
            completion()
          }
        }
        return item
      }

      let sections = playbackSections(
        for: songs, items: items, source: .playlist, playlistId: playlist.id
      )
      let template = CPListTemplate(title: playlist.name, sections: sections)
      interfaceController?.pushTemplate(template, animated: true, completion: nil)
    }

    // MARK: - Helpers

    private func playbackSections(
      for songs: [LibrarySong],
      items: [CPListItem],
      source: PlaySource,
      playlistId: UUID? = nil
    ) -> [CPListSection] {
      guard !songs.isEmpty else {
        let empty = CPListItem(text: "No songs available", detailText: nil)
        empty.isEnabled = false
        return [CPListSection(items: [empty])]
      }

      let playAll = CPListItem(text: "Play All", detailText: "\(songs.count) songs")
      playAll.setImage(UIImage(systemName: "play.fill"))
      playAll.handler = { _, completion in
        Task { @MainActor in
          PlaybackController.shared.playQueue(
            songs, startingAt: 0, from: source, playlistId: playlistId
          )
          completion()
        }
      }
      return [CPListSection(items: [playAll]), CPListSection(items: items)]
    }

    private func loadUIImage(from path: String?, size: CGFloat) -> UIImage? {
      guard let path = path, !path.isEmpty else { return nil }

      // Try to get from cache first
      if let cached = ImageCache.shared.image(for: path) {
        return cached
      }

      // Resolve and load from disk
      guard let url = PathManager.resolve(path) else { return nil }

      // Optimization: Use CGImageSource to downsample without loading the full image into memory
      let options: [CFString: Any] = [
        kCGImageSourceCreateThumbnailFromImageAlways: true,
        kCGImageSourceCreateThumbnailWithTransform: true,
        kCGImageSourceShouldCacheImmediately: true,
        kCGImageSourceThumbnailMaxPixelSize: 180, // Max size for CarPlay @3x
      ]

      guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
        let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
      else {
        return nil
      }

      let resizedImage = UIImage(cgImage: cgImage)

      // Insert into cache for next time
      ImageCache.shared.insert(resizedImage, for: path)
      return resizedImage
    }
  }

  extension CarPlaySceneDelegate: CPNowPlayingTemplateObserver {
    public func nowPlayingTemplateUpNextButtonTapped(_ nowPlayingTemplate: CPNowPlayingTemplate) {
      // Show Queue
      let songs = PlaybackController.shared.upNext
      let items = songs.map { song in
        let item = CPListItem(text: song.title, detailText: song.artist)
        item.setImage(loadUIImage(from: song.effectiveArtworkPath, size: 60))
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
      let filteredSongs = Array(library.songs.filter {
        $0.title.localizedCaseInsensitiveContains(searchText)
          || $0.artist.localizedCaseInsensitiveContains(searchText)
      }.prefix(24))

      let items = filteredSongs.enumerated().map { index, song in
        let item = CPListItem(text: song.title, detailText: song.artist)
        item.setImage(loadUIImage(from: song.effectiveArtworkPath, size: 60))
        item.handler = { _, completion in
          Task { @MainActor in
            PlaybackController.shared.playQueue(
              filteredSongs, startingAt: index, from: .search
            )
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
