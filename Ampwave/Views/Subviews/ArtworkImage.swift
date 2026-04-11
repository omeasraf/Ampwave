//
//  ArtworkImage.swift
//  Ampwave
//
//  Reusable artwork image component with async loading and caching.
//

internal import SwiftUI

struct ArtworkImage: View {
  let artworkPath: String?
  let size: CGFloat
  let cornerRadius: CGFloat
  
  @State private var image: PlatformImage?

  init(artworkPath: String?, size: CGFloat, cornerRadius: CGFloat = 8) {
    self.artworkPath = artworkPath
    self.size = size
    self.cornerRadius = cornerRadius
  }

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
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
          .fill(.gray.opacity(0.15))
          .overlay(
            Image(systemName: "music.note")
              .font(.system(size: size * 0.35))
              .foregroundStyle(.secondary)
          )
      }
    }
    .frame(width: size, height: size)
    .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    .task(id: artworkPath) {
      await loadImage()
    }
  }

  private func loadImage() async {
    guard let path = artworkPath, !path.isEmpty else { return }
    
    // Check memory cache first
    if let cached = await ImageCache.shared.image(for: path) {
      self.image = cached
      return
    }

    // Resolve path and load from disk in background
    let task = Task.detached(priority: .userInitiated) { () -> PlatformImage? in
      guard let url = PathManager.resolve(path) else { return nil }
      
      do {
        let data = try Data(contentsOf: url)
        #if os(iOS)
        return UIImage(data: data)
        #else
        return NSImage(data: data)
        #endif
      } catch {
        return nil
      }
    }
    
    if let loadedImage = await task.value {
      await ImageCache.shared.insert(loadedImage, for: path)
      self.image = loadedImage
    }
  }
}

// MARK: - Artist Image View

struct ArtistImageView: View {
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
        Circle()
          .fill(.gray.opacity(0.15))
          .overlay(
            Image(systemName: "person.fill")
              .font(.system(size: size * 0.4))
              .foregroundStyle(.secondary)
          )
      }
    }
    .frame(width: size, height: size)
    .clipShape(Circle())
    .task(id: artworkPath) {
      await loadImage()
    }
  }

  private func loadImage() async {
    guard let path = artworkPath, !path.isEmpty else { return }
    
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
      } catch {
        return nil
      }
    }
    
    if let loadedImage = await task.value {
      await ImageCache.shared.insert(loadedImage, for: path)
      self.image = loadedImage
    }
  }
}
