//
//  FullArtworkBackgroundView.swift
//  Ampwave
//

internal import SwiftUI
import SwiftData

struct FullArtworkBackgroundView: View {
  let artworkPath: String?
  @State private var image: PlatformImage?
  private var theme: ThemeManager { ThemeManager.shared }
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

        if theme.showFullArtworkGradient {
            // The "bottom" gradient to blend with background
            LinearGradient(
              stops: [
                .init(color: .clear, location: 0),
                .init(color: .clear, location: 0.4), // Start higher to cover more artwork
                .init(color: theme.backgroundColor.opacity(0.1), location: 0.55),
                .init(color: theme.backgroundColor.opacity(0.3), location: 0.7),
                .init(color: theme.backgroundColor.opacity(0.6), location: 0.85),
                .init(color: theme.backgroundColor.opacity(0.85), location: 0.93),
                .init(color: theme.backgroundColor.opacity(0.95), location: 0.98),
                .init(color: theme.backgroundColor, location: 1.0)
              ],
              startPoint: .top,
              endPoint: .bottom
            )
        }
      }
    }
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
