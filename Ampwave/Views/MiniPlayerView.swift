//
//  MiniPlayerView.swift
//  Ampwave
//

import SwiftData
internal import SwiftUI

struct MiniPlayerView: View {
  @Binding var isExpanded: Bool

  private var playback: PlaybackController { PlaybackController.shared }

  @Environment(ThemeManager.self) private var themeManager
  @Query private var preferencesList: [UserPreferences]
  private var userPreferences: UserPreferences? { preferencesList.first }

  var body: some View {
    let isFloating = userPreferences?.miniPlayerFloating ?? true

    HStack(spacing: 12) {
      // Artwork
      FixedArtworkThumbnail(
        artworkPath: playback.currentItem?.effectiveArtworkPath,
        size: 40
      )
      .clipShape(RoundedRectangle(cornerRadius: 8))
      .shadow(radius: 2)

      // Track info
      VStack(alignment: .leading, spacing: 2) {
        Text(playback.currentItem?.title ?? "Ampwave")
          .font(.system(size: 15, weight: .bold))
          .lineLimit(1)
          .foregroundStyle(.primary)

        Text(
          playback.currentItem?.artist
            ?? (playback.currentItem == nil ? "Your music, unlocked" : "")
        )
        .font(.system(size: 13))
        .foregroundStyle(.secondary)
        .lineLimit(1)
      }

      Spacer()

      // Controls
      HStack(spacing: 20) {
        if playback.currentItem != nil {
          Button {
            playback.playPause()
          } label: {
            Image(systemName: playback.isPlaying ? "pause.fill" : "play.fill")
              .font(.system(size: 24, weight: .bold))
              .foregroundStyle(themeManager.accentColor)
              .frame(width: 32, height: 32)
          }
          .contentTransition(.symbolEffect(.replace))

          Button {
            playback.playNext()
          } label: {
            Image(systemName: "forward.fill")
              .font(.system(size: 20, weight: .bold))
              .foregroundStyle(.primary)
          }
        } else {
          Image(systemName: "music.note")
            .font(.system(size: 18))
            .foregroundStyle(.secondary)
        }
      }
    }
    .padding(.horizontal, 16)
    .padding(.vertical, isFloating ? 10 : 14)
    .background(themeManager.cardBackgroundColor)
    .clipShape(RoundedRectangle(cornerRadius: isFloating ? 16 : 0))
    .padding(.horizontal, isFloating ? 12 : 0)
    .padding(.bottom, isFloating ? 8 : 0)
    .shadow(color: .black.opacity(isFloating ? 0.15 : 0), radius: 10, x: 0, y: 5)
    .onTapGesture {
      if playback.currentItem != nil {
        withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) {
          isExpanded = true
        }
      }
    }
  }
}
