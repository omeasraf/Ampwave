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
    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    .shadow(color: .black.opacity(0.1), radius: 6, x: 0, y: 3)
    .task {
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
    guard let url = PathManager.resolve(artworkPath) else { return }

    do {
      let data = try Data(contentsOf: url)
      #if os(iOS)
        if let loadedImage = UIImage(data: data) {
          await MainActor.run {
            self.image = loadedImage
          }
        }
      #else
        if let loadedImage = NSImage(data: data) {
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
