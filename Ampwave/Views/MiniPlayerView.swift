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
      // Artwork thumbnail
      FixedArtworkThumbnail(
        artworkPath: playback.currentItem?.effectiveArtworkPath,
        size: 38
      )
      .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
      .shadow(color: .black.opacity(0.3), radius: 6, x: 0, y: 3)

      // Track info
      VStack(alignment: .leading, spacing: 2) {
        Text(playback.currentItem?.title ?? "Ampwave")
          .font(.system(size: 15, weight: .semibold))
          .lineLimit(1)
          .foregroundStyle(.primary)

        Text(
          playback.currentItem?.artist
            ?? (playback.currentItem == nil ? "Your music, in motion" : "")
        )
        .font(.system(size: 13, weight: .regular))
        .foregroundStyle(.secondary)
        .lineLimit(1)
      }

      Spacer(minLength: 0)

      // Controls
      HStack(spacing: 18) {
        if playback.currentItem != nil {
          Button {
            playback.playPause()
          } label: {
            Image(systemName: playback.isPlaying ? "pause.fill" : "play.fill")
              .font(.system(size: 24, weight: .bold))
              .foregroundStyle(themeManager.accentColor)
              .frame(width: 32, height: 32)
          }
          .buttonStyle(.plain)
          .contentTransition(.symbolEffect(.replace))

          Button {
            playback.playNext()
          } label: {
            Image(systemName: "forward.fill")
              .font(.system(size: 18, weight: .semibold))
              .foregroundStyle(.primary)
              .frame(width: 36, height: 36)
          }
          .buttonStyle(.plain)
        } else {
          Image(systemName: "music.note")
            .font(.system(size: 18))
            .foregroundStyle(.secondary)
            .frame(width: 36, height: 36)
        }
      }
      .padding(.trailing, 4)
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 10)
    .padding(.horizontal, isFloating ? 12 : 0)
    .padding(.bottom, isFloating ? 8 : 0)
    // Without this the stack is only hittable where it actually draws, so the
    // gap between the track title and the buttons swallowed taps.
    .contentShape(Rectangle())
    .onTapGesture {
      if playback.currentItem != nil {
        withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) {
          isExpanded = true
        }
      }
    }
    // Horizontal swipe changes track, matching the gesture people expect from
    // every other music app. `minimumDistance` keeps it from competing with
    // the tap, and the vertical check stops a scroll from skipping a song.
    .simultaneousGesture(
      DragGesture(minimumDistance: 24)
        .onEnded { value in
          guard playback.currentItem != nil else { return }
          let horizontal = value.translation.width
          guard abs(horizontal) > abs(value.translation.height) else { return }
          if horizontal < 0 {
            playback.playNext()
          } else {
            playback.playPrevious()
          }
          HapticManager.shared.select()
        }
    )
  }
}
