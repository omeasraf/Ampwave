//
//  ArtworkImage.swift
//  Ampwave
//
//  Reusable artwork image component with async loading.
//

internal import SwiftUI

struct ArtworkImage: View {
  let artworkPath: String?
  let size: CGFloat
  let cornerRadius: CGFloat
  #if os(iOS)
    @State private var image: UIImage?
  #else
    @State private var image: NSImage?
  #endif

  init(artworkPath: String?, size: CGFloat, cornerRadius: CGFloat = 8) {
    self.artworkPath = artworkPath
    self.size = size
    self.cornerRadius = cornerRadius
  }

  var body: some View {
    Group {
      if let image = image {
        imageView(image)
      } else {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
          .fill(.gray.opacity(0.2))
          .overlay(
            Image(systemName: "music.note")
              .font(.system(size: size * 0.3))
              .foregroundStyle(.secondary)
          )
      }
    }
    .frame(width: size, height: size)
    .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
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

// MARK: - Artist Image View

struct ArtistImageView: View {
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
        Circle()
          .fill(.gray.opacity(0.2))
          .overlay(
            Image(systemName: "person.fill")
              .font(.system(size: size * 0.4))
              .foregroundStyle(.secondary)
          )
      }
    }
    .frame(width: size, height: size)
    .clipShape(Circle())
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
