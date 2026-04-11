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
            Image(systemName: "music.note")
              .font(.system(size: size * 0.4))
              .foregroundStyle(.secondary)
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
        RoundedRectangle(cornerRadius: 24, style: .continuous)
          .fill(.gray.opacity(0.15))
          .overlay(
            Image(systemName: "music.note")
              .font(.system(size: 80))
              .foregroundStyle(.secondary)
          )
      }
    }
    .frame(maxWidth: 320, maxHeight: 320)
    .aspectRatio(1, contentMode: .fit)
    .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
    .shadow(color: .black.opacity(0.15), radius: 20, x: 0, y: 10)
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
