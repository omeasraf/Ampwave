//
//  ArtworkBackgroundView.swift
//  Ampwave
//
//  Created by Ome Asraf on 4/3/26.
//

internal import SwiftUI
import ImageIO

struct ArtworkBackgroundView: View {
  let artworkPath: String
  #if os(iOS)
    @State private var image: UIImage?
  #else
    @State private var image: NSImage?
  #endif

  var body: some View {
    // GeometryReader pins the backdrop to exactly the space it was given.
    // Without it the `.fill` image reports its *own* (much larger) size — a
    // square cover asked to fill a tall screen comes back roughly as wide as
    // the screen is tall — which inflates the enclosing ZStack and pushes the
    // lyrics off to the side.
    GeometryReader { proxy in
      Group {
        if let image = image {
          imageView(image)
            .scaleEffect(1.12)
            .blur(radius: 48, opaque: true)
            .frame(width: proxy.size.width, height: proxy.size.height)
            .clipped()
            .overlay(
              LinearGradient(
                colors: [
                  .black.opacity(0.28),
                  .black.opacity(0.62),
                  .black.opacity(0.86),
                ],
                startPoint: .top,
                endPoint: .bottom
              )
            )
        } else {
          Color.black
        }
      }
      .frame(width: proxy.size.width, height: proxy.size.height)
    }
    .ignoresSafeArea()
    .task(id: artworkPath) {
      image = nil
      await loadImage()
    }
  }

  @ViewBuilder
  private func imageView(_ image: Any) -> some View {
    #if os(iOS)
      if let uiImage = image as? UIImage {
        Image(uiImage: uiImage)
          .resizable()
          .aspectRatio(contentMode: .fill)
      }
    #else
      if let nsImage = image as? NSImage {
        Image(nsImage: nsImage)
          .resizable()
          .aspectRatio(contentMode: .fill)
      }
    #endif
  }

  private func loadImage() async {
    let cacheKey = "lyrics-background:\(artworkPath)"
    if let cached = ImageCache.shared.image(for: cacheKey) {
      image = cached
      return
    }
    guard let artworkURL = PathManager.resolve(artworkPath) else { return }

    let loadedImage = await Task.detached(priority: .userInitiated) {
      () -> PlatformImage? in
      guard let source = CGImageSourceCreateWithURL(artworkURL as CFURL, nil)
      else {
        return nil
      }

      let options: [CFString: Any] = [
        kCGImageSourceCreateThumbnailFromImageAlways: true,
        kCGImageSourceCreateThumbnailWithTransform: true,
        kCGImageSourceShouldCacheImmediately: true,
        kCGImageSourceThumbnailMaxPixelSize: 1400,
      ]
      guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(
        source,
        0,
        options as CFDictionary
      ) else {
        return nil
      }

      #if os(iOS)
        return UIImage(cgImage: thumbnail)
      #else
        return NSImage(cgImage: thumbnail, size: .zero)
      #endif
    }.value

    guard !Task.isCancelled, let loadedImage else { return }
    ImageCache.shared.insert(loadedImage, for: cacheKey)
    withAnimation(.easeInOut(duration: 0.3)) {
      image = loadedImage
    }
  }
}
