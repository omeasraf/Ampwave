internal import SwiftUI

//
//  FixedArtworkThumbnail.swift
//  Ampwave
//
//  Created by Ome Asraf on 4/3/26.
//
#if os(iOS)
  import UIKit
#else
  import AppKit
#endif

struct FixedArtworkThumbnail: View {
  let artworkPath: String?
  let size: CGFloat
  private var playback: PlaybackController { PlaybackController.shared }

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
    .id(playback.currentItem?.id ?? UUID())
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
