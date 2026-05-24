//
//  AlbumArtworkView.swift
//  Ampwave
//
//  Created by Ome Asraf on 4/9/26.
//

internal import SwiftUI

struct AlbumArtworkView: View {
  let artworkPath: String?
  let size: CGFloat
  var cornerRadius: CGFloat = 8
  #if os(iOS)
    @State private var image: UIImage?
  #else
    @State private var image: NSImage?
  #endif

  var body: some View {
    Group {
      if let image = image {
        imageView(image)
      } else {
        RoundedRectangle(cornerRadius: 8, style: .continuous)
          .fill(
            LinearGradient(
              colors: [.gray.opacity(0.3), .gray.opacity(0.15)],
              startPoint: .topLeading,
              endPoint: .bottomTrailing
            )
          )
          .overlay(
            Image(systemName: "music.note")
              .font(.system(size: size * 0.25))
              .foregroundStyle(.secondary)
          )
      }
    }
    .frame(width: size, height: size)
    .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    .shadow(color: .black.opacity(cornerRadius > 0 ? 0.1 : 0), radius: 6, x: 0, y: 3)
    .task(id: artworkPath) {
      await MainActor.run {
        self.image = nil
      }
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
    guard let path = artworkPath, !path.isEmpty else { return }

    // Check memory cache first
    if let cached = await ImageCache.shared.image(for: path) {
      await MainActor.run {
        self.image = cached
      }
      return
    }

    // Resolve path and load from disk
    guard let url = PathManager.resolve(path) else { return }

    do {
      let data = try Data(contentsOf: url)
      #if os(iOS)
        if let loadedImage = UIImage(data: data) {
          await ImageCache.shared.insert(loadedImage, for: path)
          await MainActor.run {
            self.image = loadedImage
          }
        }
      #else
        if let loadedImage = NSImage(data: data) {
          await ImageCache.shared.insert(loadedImage, for: path)
          await MainActor.run {
            self.image = loadedImage
          }
        }
      #endif
    } catch {}
  }
}

#Preview {
  AlbumArtworkView(artworkPath: nil, size: 50)
}
