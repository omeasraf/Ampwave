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
  @Environment(\.displayScale) private var displayScale

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
            AmpwaveEqualizerMark(isAnimated: false, monochromeColor: .secondary)
              .frame(width: size * 0.46, height: size * 0.31)
          )
      }
    }
    .frame(width: size, height: size)
    .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    .task(id: loadKey) {
      await loadImage()
    }
  }

  private var loadKey: String {
    "\(artworkPath ?? "")#\(Int(ceil(size * displayScale)))"
  }

  private func loadImage() async {
    guard let path = artworkPath, !path.isEmpty else { return }

    guard let url = PathManager.resolve(path) else { return }
    let loadedImage = await ImageCache.shared.thumbnail(
      for: path,
      url: url,
      maxPixelSize: Int(ceil(size * displayScale))
    )
    guard !Task.isCancelled else { return }
    self.image = loadedImage
  }
}

// MARK: - Artist Image View

struct ArtistImageView: View {
  let artworkPath: String?
  let size: CGFloat

  @State private var image: PlatformImage?
  @Environment(\.displayScale) private var displayScale

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
    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    .task(id: loadKey) {
      await loadImage()
    }
  }

  private var loadKey: String {
    "\(artworkPath ?? "")#\(Int(ceil(size * displayScale)))"
  }

  private func loadImage() async {
    guard let path = artworkPath, !path.isEmpty else { return }

    guard let url = PathManager.resolve(path) else { return }
    let loadedImage = await ImageCache.shared.thumbnail(
      for: path,
      url: url,
      maxPixelSize: Int(ceil(size * displayScale))
    )
    guard !Task.isCancelled else { return }
    self.image = loadedImage
  }
}
