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

  var body: some View {
    Group {
      if let url = PathManager.resolve(artworkPath),
        let data = try? Data(contentsOf: url)
      {
        loadedImageView(data: data)
      } else {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
          .fill(.gray.opacity(0.2))
          .overlay(
            Image(systemName: "music.note")
              .font(.system(size: size * 0.4))
              .foregroundStyle(.secondary)
          )
      }
    }
    .frame(width: size, height: size)
    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    .shadow(color: .black.opacity(0.1), radius: 4, x: 0, y: 2)
  }

  @ViewBuilder
  private func loadedImageView(data: Data) -> some View {
    #if os(iOS)
      if let uiImage = UIImage(data: data) {
        Image(uiImage: uiImage)
          .resizable()
          .aspectRatio(contentMode: .fill)
      }
    #else
      if let nsImage = NSImage(data: data) {
        Image(nsImage: nsImage)
          .resizable()
          .aspectRatio(contentMode: .fill)
      }
    #endif
  }
}

struct LargeArtworkImageView: View {
  let artworkPath: String?

  var body: some View {
    Group {
      if let url = PathManager.resolve(artworkPath),
        let data = try? Data(contentsOf: url)
      {
        loadedImageView(data: data)
      } else {
        RoundedRectangle(cornerRadius: 24, style: .continuous)
          .fill(.gray.opacity(0.2))
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
    .shadow(color: .black.opacity(0.2), radius: 20, x: 0, y: 10)
  }

  @ViewBuilder
  private func loadedImageView(data: Data) -> some View {
    #if os(iOS)
      if let uiImage = UIImage(data: data) {
        Image(uiImage: uiImage)
          .resizable()
          .aspectRatio(contentMode: .fill)
      }
    #else
      if let nsImage = NSImage(data: data) {
        Image(nsImage: nsImage)
          .resizable()
          .aspectRatio(contentMode: .fill)
      }
    #endif
  }
}

// MARK: - Legacy / Helper wrappers

struct ArtworkThumbnail: View {
  let artworkPath: String?
  let size: CGFloat

  var body: some View {
    ArtworkImageView(artworkPath: artworkPath, size: size)
      .id(PlaybackController.shared.currentItem?.id ?? UUID())
  }
}

struct LargeArtworkView: View {
  let artworkPath: String?

  var body: some View {
    LargeArtworkImageView(artworkPath: artworkPath)
      .id(PlaybackController.shared.currentItem?.id ?? UUID())
  }
}

struct LargeFixedArtworkView: View {
  let artworkPath: String?
  var body: some View {
    LargeArtworkImageView(artworkPath: artworkPath)
      .id(PlaybackController.shared.currentItem?.id ?? UUID())
  }
}
