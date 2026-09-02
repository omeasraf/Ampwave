//
//  PlaylistArtworkView.swift
//  Ampwave
//
//  Created by Ome Asraf on 4/9/26.
//

internal import SwiftUI

struct PlaylistArtworkView: View {
  let size: CGFloat
  private let artworkType: PlaylistArtworkType
  private let artworkPaths: [String]
  private let customArtworkPath: String?
  private let iconName: String
  private let iconColor: Color
  private let isLikedSongs: Bool
  @Environment(ThemeManager.self) private var themeManager

  init(playlist: Playlist, size: CGFloat) {
    self.size = size
    artworkType = playlist.artworkType
    artworkPaths = playlist.getArtworkPaths()
    customArtworkPath = playlist.artworkPath
    iconName = playlist.icon?.icon ?? "music.note"
    iconColor = playlist.icon?.color ?? .secondary
    isLikedSongs = playlist.playlistType == .likedSongs
  }

  var body: some View {
    Group {
      switch artworkType {
      case .grid:
        // A collage needs four *different* covers to read as one. With fewer
        // distinct albums, show a single cover rather than tiling one image.
        if artworkPaths.count >= 4 {
          GridArtworkView(paths: Array(artworkPaths.prefix(4)), size: size)
        } else if let firstPath = artworkPaths.first {
          SingleArtworkView(artworkPath: firstPath, size: size)
        } else {
          placeholderView
        }
      case .single:
        if let firstPath = artworkPaths.first {
          SingleArtworkView(artworkPath: firstPath, size: size)
        } else {
          placeholderView
        }
      case .custom:
        if let artworkPath = customArtworkPath {
          SingleArtworkView(artworkPath: artworkPath, size: size)
        } else {
          placeholderView
        }
      case .icon:
        placeholderView
      }
    }
    .frame(width: size, height: size)
    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    .shadow(color: .accent.opacity(0.1), radius: 6, x: 0, y: 3)
  }

  private var placeholderView: some View {
    let color: Color =
      isLikedSongs
        ? themeManager.accentColor
        : iconColor

    return RoundedRectangle(cornerRadius: 8, style: .continuous)
      .fill(color.opacity(0.15))
      .overlay {
        if iconName == "music.note" {
          AmpwaveEqualizerMark(isAnimated: false, monochromeColor: color)
            .frame(width: size * 0.46, height: size * 0.31)
        } else {
          Image(systemName: iconName)
            .font(.system(size: size * 0.35))
            .foregroundStyle(color)
        }
      }
  }
}

struct SingleArtworkView: View {
  let artworkPath: String
  let size: CGFloat

  @State private var image: PlatformImage?

  var body: some View {
    Group {
      if let image = image {
        #if os(iOS)
          Image(uiImage: image)
            .resizable()
            .aspectRatio(contentMode: .fill)
        #else
          Image(nsImage: image)
            .resizable()
            .aspectRatio(contentMode: .fill)
        #endif
      } else {
        Rectangle()
          .fill(Color.gray.opacity(0.2))
          .overlay(ProgressView().scaleEffect(0.5))
      }
    }
    .frame(width: size, height: size)
    .task {
      await loadImage()
    }
  }

  private func loadImage() async {
    guard let url = PathManager.resolve(artworkPath) else { return }
    do {
      let data = try Data(contentsOf: url)
      if let loadedImage = PlatformImage(data: data) {
        await MainActor.run { self.image = loadedImage }
      }
    } catch {}
  }
}

struct GridArtworkView: View {
  let paths: [String]
  let size: CGFloat

  var body: some View {
    VStack(spacing: 0) {
      HStack(spacing: 0) {
        GridItemView(path: paths[0], size: size / 2)
        GridItemView(path: paths[1], size: size / 2)
      }
      HStack(spacing: 0) {
        GridItemView(path: paths[2], size: size / 2)
        GridItemView(path: paths[3], size: size / 2)
      }
    }
  }
}

struct GridItemView: View {
  let path: String
  let size: CGFloat
  @State private var image: PlatformImage?

  var body: some View {
    Group {
      if let image = image {
        #if os(iOS)
          Image(uiImage: image)
            .resizable()
            .aspectRatio(contentMode: .fill)
        #else
          Image(nsImage: image)
            .resizable()
            .aspectRatio(contentMode: .fill)
        #endif
      } else {
        Rectangle()
          .fill(Color.gray.opacity(0.2))
      }
    }
    .frame(width: size, height: size)
    .clipped()
    .task {
      await loadImage()
    }
  }

  private func loadImage() async {
    guard let url = PathManager.resolve(path) else { return }
    do {
      let data = try Data(contentsOf: url)
      if let loadedImage = PlatformImage(data: data) {
        await MainActor.run { self.image = loadedImage }
      }
    } catch {}
  }
}
