//
//  OpenPlayerMiniView.swift
//  Ampwave
//
//  Mini player view shown at the bottom of the screen.
//  Apple Music style design.
//

internal import SwiftUI

struct OpenPlayerMiniView: View {
  private var playback: PlaybackController { PlaybackController.shared }

  var body: some View {
    HStack(spacing: 12) {
      // Artwork
      ArtworkThumbnail(
        artworkPath: playback.currentItem?.artworkPath,
        size: 44
      )

      // Track info
      VStack(alignment: .leading, spacing: 2) {
        Text(playback.currentItem?.title ?? "Not Playing")
          .font(.system(size: 15, weight: .semibold))
          .lineLimit(1)

        Text(playback.currentItem?.artist ?? "")
          .font(.system(size: 13))
          .foregroundStyle(.secondary)
          .lineLimit(1)
      }
      .frame(maxWidth: .infinity, alignment: .leading)

      // Controls
      HStack(spacing: 20) {
        Button {
          playback.playPrevious()
        } label: {
          Image(systemName: "backward.fill")
            .font(.system(size: 18))
        }

        Button {
          playback.playPause()
        } label: {
          Image(systemName: playback.isPlaying ? "pause.fill" : "play.fill")
            .font(.system(size: 24))
        }
        .contentTransition(.symbolEffect(.replace))

        Button {
          playback.playNext()
        } label: {
          Image(systemName: "forward.fill")
            .font(.system(size: 18))
        }
      }
      .foregroundStyle(.primary)
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 10)
    .background(.ultraThinMaterial)
    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    .shadow(color: .black.opacity(0.12), radius: 12, x: 0, y: 4)
  }
}

#Preview {
  OpenPlayerMiniView()
    .padding()
}
