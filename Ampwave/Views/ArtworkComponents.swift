internal import SwiftUI

#if os(iOS)
  import UIKit
#else
  import AppKit
#endif

// MARK: - Artwork View Components

struct ArtworkImageView: View {
  let artworkPath: String?
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
        RoundedRectangle(cornerRadius: 12, style: .continuous)
          .fill(.gray.opacity(0.15))
          .overlay(
            AmpwaveEqualizerMark(isAnimated: false, monochromeColor: .secondary)
              .frame(width: size * 0.46, height: size * 0.31)
          )
      }
    }
    .frame(width: size, height: size)
    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    .shadow(color: .black.opacity(0.05), radius: 4, x: 0, y: 2)
    .task(id: artworkPath) {
      await loadImage()
    }
  }

  private func loadImage() async {
    guard let path = artworkPath, !path.isEmpty else {
      image = nil
      return
    }

    if let cached = await ImageCache.shared.image(for: path) {
      self.image = cached
      return
    }

    let task = Task.detached(priority: .userInitiated) { () -> PlatformImage? in
      guard let url = PathManager.resolve(path) else { return nil }
      do {
        let data = try Data(contentsOf: url)
        #if os(iOS)
          return UIImage(data: data)
        #else
          return NSImage(data: data)
        #endif
      } catch { return nil }
    }

    if let loadedImage = await task.value {
      await ImageCache.shared.insert(loadedImage, for: path)
      self.image = loadedImage
    }
  }
}

struct LargeArtworkImageView: View {
  let artworkPath: String?
  var animatedArtworkURL: URL? = nil
  var isPlaying: Bool = false
  var shadowColor: Color = .black.opacity(0.15)
  var shadowRadius: CGFloat = 20
  @State private var image: PlatformImage?
  @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion

  var body: some View {
    ZStack {
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
        RoundedRectangle(cornerRadius: 24, style: .continuous)
          .fill(.gray.opacity(0.15))
          .overlay(
            AmpwaveEqualizerMark(isAnimated: false, monochromeColor: .secondary)
              .frame(width: 112, height: 76)
          )
      }

      #if os(iOS)
        if let animatedArtworkURL, !accessibilityReduceMotion {
          LoopingArtworkPlayerView(url: animatedArtworkURL, isPlaying: isPlaying)
            .allowsHitTesting(false)
            .transition(.opacity)
        }
      #endif
    }
    .frame(maxWidth: .infinity)
    .aspectRatio(1, contentMode: .fit)
    .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
    .shadow(color: shadowColor, radius: shadowRadius, x: 0, y: shadowRadius / 2)
    .task(id: artworkPath) {
      await loadImage()
    }
  }

  private func loadImage() async {
    guard let path = artworkPath, !path.isEmpty else {
      image = nil
      return
    }

    if let cached = await ImageCache.shared.image(for: path) {
      self.image = cached
      return
    }

    let task = Task.detached(priority: .userInitiated) { () -> PlatformImage? in
      guard let url = PathManager.resolve(path) else { return nil }
      do {
        let data = try Data(contentsOf: url)
        #if os(iOS)
          return UIImage(data: data)
        #else
          return NSImage(data: data)
        #endif
      } catch { return nil }
    }

    if let loadedImage = await task.value {
      await ImageCache.shared.insert(loadedImage, for: path)
      self.image = loadedImage
    }
  }
}

// MARK: - Legacy / Helper wrappers

struct ArtworkThumbnail: View {
  let artworkPath: String?
  let size: CGFloat

  var body: some View {
    ArtworkImageView(artworkPath: artworkPath, size: size)
  }
}

struct LargeArtworkView: View {
  let artworkPath: String?

  var body: some View {
    LargeArtworkImageView(artworkPath: artworkPath)
  }
}

struct LargeFixedArtworkView: View {
  let artworkPath: String?
  var body: some View {
    LargeArtworkImageView(artworkPath: artworkPath)
  }
}
