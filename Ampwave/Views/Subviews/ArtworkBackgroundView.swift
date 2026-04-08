//
//  ArtworkBackgroundView.swift
//  Ampwave
//
//  Created by Ome Asraf on 4/3/26.
//

internal import SwiftUI

struct ArtworkBackgroundView: View {
  let artworkPath: String
  #if os(iOS)
    @State private var image: UIImage?
  #else
    @State private var image: NSImage?
  #endif

  var body: some View {
    Group {
      if let image = image {
        imageView(image)
          .ignoresSafeArea()
          .overlay(
            LinearGradient(
              colors: [
                .black.opacity(0.3),
                .black.opacity(0.7),
                .black.opacity(0.9),
              ],
              startPoint: .top,
              endPoint: .bottom
            )
            .ignoresSafeArea()
          )
          .blur(radius: 60)
      } else {
        Color.black.ignoresSafeArea()
      }
    }
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
