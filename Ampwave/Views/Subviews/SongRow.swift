//
//  SongRow.swift
//  Ampwave
//
//  Reusable song row component with artwork, title, and artist.
//

internal import SwiftUI

/// The "E" marker Apple Music and Spotify use for explicit tracks.
struct ExplicitBadge: View {
  var size: CGFloat = 12

  var body: some View {
    Image(systemName: "e.square.fill")
      .font(.system(size: size))
      .foregroundStyle(.secondary)
      .accessibilityLabel("Explicit")
  }
}

struct SongRow: View {
  let song: LibrarySong
  let isCurrent: Bool
  var showArtwork: Bool = true

  @State private var playback = PlaybackController.shared

  var body: some View {
    HStack(spacing: 12) {
      if showArtwork {
        ArtworkImage(artworkPath: song.effectiveArtworkPath, size: 50, cornerRadius: 6)
      }

      VStack(alignment: .leading, spacing: 3) {
        Text(song.title)
          .font(.system(size: 16, weight: isCurrent ? .semibold : .regular))
          .lineLimit(1)

        HStack(spacing: 4) {
          if song.isExplicit { ExplicitBadge(size: 12) }
          Text(song.artist)
            .font(.system(size: 14))
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }
      }

      Spacer()

      if song.shouldSyncToWatch {
        Image(systemName: "applewatch")
          .font(.system(size: 12))
          .foregroundStyle(.secondary)
      }

      if isCurrent {
        AmpwaveEqualizerMark(isAnimated: playback.isPlaying)
          .frame(width: 22, height: 18)
          .accessibilityLabel(playback.isPlaying ? "Now playing" : "Current song, paused")
      }
    }
    .padding(.vertical, 4)
    .songContextMenu(song: song)
  }
}

// MARK: - Compact Song Row

struct CompactSongRow: View {
  let song: LibrarySong
  let isCurrent: Bool
  @State private var playback = PlaybackController.shared

  var body: some View {
    HStack(spacing: 12) {
      ArtworkImage(artworkPath: song.effectiveArtworkPath, size: 40, cornerRadius: 4)

      VStack(alignment: .leading, spacing: 2) {
        Text(song.title)
          .font(.system(size: 15, weight: isCurrent ? .semibold : .medium))
          .lineLimit(1)

        HStack(spacing: 4) {
          if song.isExplicit { ExplicitBadge(size: 11) }
          Text(song.artist)
            .font(.system(size: 13))
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }
      }

      Spacer()

      if isCurrent {
        AmpwaveEqualizerMark(isAnimated: playback.isPlaying)
          .frame(width: 20, height: 15)
          .accessibilityLabel(playback.isPlaying ? "Now playing" : "Current song, paused")
      }
    }
    .padding(.vertical, 4)
    .songContextMenu(song: song)
  }
}

// MARK: - Song Row with Number

struct NumberedSongRow: View {
  let number: Int
  let song: LibrarySong
  let isCurrent: Bool
  @State private var playback = PlaybackController.shared

  var body: some View {
    HStack(spacing: 12) {
      // Number or playing indicator
      if isCurrent {
        AmpwaveEqualizerMark(isAnimated: playback.isPlaying)
          .frame(width: 22, height: 16)
          .frame(width: 28, alignment: .center)
          .accessibilityLabel(playback.isPlaying ? "Now playing" : "Current song, paused")
      } else {
        Text("\(number)")
          .font(.system(size: 14, weight: .medium))
          .foregroundStyle(.secondary)
          .frame(width: 28, alignment: .center)
      }

      ArtworkImage(artworkPath: song.effectiveArtworkPath, size: 40, cornerRadius: 4)

      VStack(alignment: .leading, spacing: 2) {
        Text(song.title)
          .font(.system(size: 15, weight: isCurrent ? .semibold : .regular))
          .lineLimit(1)

        HStack(spacing: 4) {
          if song.isExplicit { ExplicitBadge(size: 11) }
          Text(song.artist)
            .font(.system(size: 13))
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }
      }

      Spacer()
    }
    .padding(.vertical, 4)
    .songContextMenu(song: song)
  }
}
