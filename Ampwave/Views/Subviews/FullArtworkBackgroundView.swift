//
//  FullArtworkBackgroundView.swift
//  Ampwave
//
//  Created by Gemini on 4/24/26.
//

internal import SwiftUI
import SwiftData

struct FullArtworkBackgroundView: View {
  let artworkPath: String?
  @State private var image: PlatformImage?
  @Environment(\.theme) private var theme
  @Query private var preferencesList: [UserPreferences]
  
  private var userPreferences: UserPreferences? {
    preferencesList.first
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
          // The "bottom blue" and "feathering"
          LinearGradient(
            stops: [
              .init(color: .clear, location: 0),
              .init(color: .clear, location: 0.8),
              .init(color: theme.accent.opacity(0.15), location: 0.9),
              .init(color: theme.accent.opacity(0.25), location: 0.95),
              .init(color: theme.background.opacity(0.9), location: 0.99),
              .init(color: theme.background, location: 1.0)
            ],
            startPoint: .top,
            endPoint: .bottom
          )
        }
      }
    }
    .frame(height: 520) // Slightly taller for better effect
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
