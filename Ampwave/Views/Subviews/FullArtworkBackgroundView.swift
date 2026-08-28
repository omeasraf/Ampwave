//
//  FullArtworkBackgroundView.swift
//  Ampwave
//

import SwiftData
internal import SwiftUI

struct FullArtworkBackgroundView: View {
  let artworkPath: String?
  var animatedArtworkURL: URL? = nil
  var isPlaying: Bool = false
  @State private var image: PlatformImage?
  @Environment(ThemeManager.self) private var themeManager
  @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion
  @Query private var preferencesList: [UserPreferences]

  private var userPreferences: UserPreferences? { preferencesList.first }

  init(
    artworkPath: String?,
    animatedArtworkURL: URL? = nil,
    isPlaying: Bool = false
  ) {
    self.artworkPath = artworkPath
    self.animatedArtworkURL = animatedArtworkURL
    self.isPlaying = isPlaying
  }

  var body: some View {
    GeometryReader { geometry in
      let size = geometry.size
      ZStack(alignment: .center) {
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
              AmpwaveEqualizerMark(isAnimated: false, monochromeColor: .secondary)
                .frame(width: 140, height: 94)
            )
        }

        #if os(iOS)
          if let animatedArtworkURL, !accessibilityReduceMotion {
            LoopingArtworkPlayerView(url: animatedArtworkURL, isPlaying: isPlaying)
              .frame(width: size.width, height: size.height)
              .clipped()
              .allowsHitTesting(false)
              .transition(.opacity)
          }
        #endif
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
