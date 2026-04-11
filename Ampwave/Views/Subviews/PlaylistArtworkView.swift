//
//  PlaylistArtworkView.swift
//  Ampwave
//
//  Created by Ome Asraf on 4/9/26.
//

internal import SwiftUI

#if os(iOS)
  typealias PlatformImage = UIImage
#else
  typealias PlatformImage = NSImage
#endif

struct PlaylistArtworkView: View {
  let playlist: Playlist
  let size: CGFloat

  var body: some View {
    Group {
      switch playlist.artworkType {
      case .grid:
        let paths = playlist.getArtworkPaths()
        if paths.count >= 4 {
          GridArtworkView(paths: paths, size: size)
        } else if paths.count > 0 && paths.count < 4 {
          // Fill up with repeated elements if less than 4 but grid is wanted
          let filledPaths = (0..<4).map { paths[$0 % paths.count] }
          GridArtworkView(paths: filledPaths, size: size)
        } else if let firstPath = paths.first {
          SingleArtworkView(artworkPath: firstPath, size: size)
        } else {
          placeholderView
        }
      case .single:
        if let firstPath = playlist.getArtworkPaths().first {
          SingleArtworkView(artworkPath: firstPath, size: size)
        } else {
          placeholderView
        }
      case .custom:
        if let artworkPath = playlist.artworkPath {
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
    let color = playlist.icon?.color ?? .secondary
    let iconName = playlist.icon?.icon ?? "music.note"

    return RoundedRectangle(cornerRadius: 8, style: .continuous)
      .fill(
        color.opacity(0.15)
      )
      .overlay(
        Image(systemName: iconName)
          .font(.system(size: size * 0.35))
          .foregroundStyle(color)
      )
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
