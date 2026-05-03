//
//  FullArtworkBackgroundView.swift
//  Ampwave
//

import SwiftData
internal import SwiftUI

struct FullArtworkBackgroundView: View {
  let artworkPath: String?
  @State private var image: PlatformImage?
  @Environment(ThemeManager.self) private var themeManager
  @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion
  @Query private var preferencesList: [UserPreferences]

  private var userPreferences: UserPreferences? { preferencesList.first }

  init(artworkPath: String?) {
    self.artworkPath = artworkPath
  }

  var body: some View {
    GeometryReader { geometry in
      let size = geometry.size
      ZStack(alignment: .bottom) {
        if let image = image {
          #if os(iOS)
            Image(uiImage: image)
              .resizable()
              .aspectRatio(contentMode: .fill)
              .frame(width: size.width, height: size.height)
              .clipped()
          #else
            Image(nsImage: image)
              .resizable()
              .aspectRatio(contentMode: .fill)
              .frame(width: size.width, height: size.height)
              .clipped()
          #endif
        } else {
          Color.gray.opacity(0.2)
            .overlay(
              Image(systemName: "music.note")
                .font(.system(size: 100))
                .foregroundStyle(.secondary)
            )
        }

        if userPreferences?.showFullArtworkGradient ?? true {
          if accessibilityReduceMotion {
            LinearGradient(
              stops: [
                .init(color: .clear, location: 0),
                .init(color: themeManager.backgroundColor.opacity(0.88), location: 1),
              ],
              startPoint: .top,
              endPoint: .bottom
            )
          } else {
            // Bottom feathering: accent wash then blend into app background
            LinearGradient(
              stops: [
                .init(color: .clear, location: 0),
                .init(color: .clear, location: 0.2),
                .init(color: themeManager.accentColor.opacity(0.03), location: 0.4),
                .init(color: themeManager.accentColor.opacity(0.1), location: 0.6),
                .init(color: themeManager.backgroundColor.opacity(0.3), location: 0.75),
                .init(color: themeManager.backgroundColor.opacity(0.6), location: 0.85),
                .init(color: themeManager.backgroundColor.opacity(0.85), location: 0.93),
                .init(color: themeManager.backgroundColor.opacity(0.95), location: 0.97),
                .init(color: themeManager.backgroundColor, location: 1.0),
              ],
              startPoint: .top,
              endPoint: .bottom
            )
          }
        }
      }
    }
    .frame(height: 500)
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
