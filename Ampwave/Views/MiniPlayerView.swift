//
//  MiniPlayerView.swift
//  Ampwave
//

internal import SwiftUI

struct MiniPlayerView: View {
  @Binding var isExpanded: Bool

  private var playback: PlaybackController { PlaybackController.shared }

  var body: some View {
    HStack(spacing: 12) {
      // Artwork
      FixedArtworkThumbnail(
        artworkPath: playback.currentItem?.artworkPath,
        size: 48
      )

      // Track info
      VStack(alignment: .leading, spacing: 2) {
        Text(playback.currentItem?.title ?? "Ampwave")
          .font(.system(size: 15, weight: .bold))
          .lineLimit(1)

        Text(playback.currentItem?.artist ?? (playback.currentItem == nil ? "Not Playing" : ""))
          .font(.system(size: 13))
          .foregroundStyle(.secondary)
          .lineLimit(1)
      }

      Spacer()

      // Controls
      HStack(spacing: 16) {
        if playback.currentItem != nil {
          Button {
            playback.playPause()
          } label: {
            Image(systemName: playback.isPlaying ? "pause.fill" : "play.fill")
              .font(.system(size: 22, weight: .bold))
              .frame(width: 32, height: 32)
          }
          .contentTransition(.symbolEffect(.replace))

          Button {
            playback.playNext()
          } label: {
            Image(systemName: "forward.fill")
              .font(.system(size: 18, weight: .bold))
          }
        } else {
          Image(systemName: "music.note")
            .font(.system(size: 18))
            .foregroundStyle(.secondary)
        }
      }
      .foregroundStyle(.primary)
    }
    .padding(.horizontal, 16)
    .padding(.vertical, 12)
    .background {
      RoundedRectangle(cornerRadius: 20, style: .continuous)
        .fill(.ultraThinMaterial)
        .overlay(
          RoundedRectangle(cornerRadius: 20, style: .continuous)
            .stroke(.white.opacity(0.1), lineWidth: 0.5)
        )
    }
    .shadow(color: .black.opacity(0.15), radius: 10, x: 0, y: 5)
    .onTapGesture {
      if playback.currentItem != nil {
        withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) {
          isExpanded = true
        }
      }
    }
  }
}
