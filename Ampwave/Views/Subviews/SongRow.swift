//
//  SongRow.swift
//  Ampwave
//
//  Reusable song row component with artwork, title, and artist.
//

internal import SwiftUI

struct SongRow: View {
  let song: LibrarySong
  let isCurrent: Bool
  var showArtwork: Bool = true

  private var playback: PlaybackController { PlaybackController.shared }

  var body: some View {
    HStack(spacing: 12) {
      if showArtwork {
        ArtworkImage(artworkPath: song.artworkPath, size: 50, cornerRadius: 6)
      }

      VStack(alignment: .leading, spacing: 3) {
        Text(song.title)
          .font(.system(size: 16, weight: isCurrent ? .semibold : .regular))
          .lineLimit(1)

        Text(song.artist)
          .font(.system(size: 14))
          .foregroundStyle(.secondary)
          .lineLimit(1)
      }

      Spacer()

      if song.shouldSyncToWatch {
        Image(systemName: "applewatch")
          .font(.system(size: 12))
          .foregroundStyle(.secondary)
      }

      if isCurrent {
        Image(systemName: "waveform")
          .font(.system(size: 14))
          .foregroundStyle(.pink)
          .symbolEffect(.pulse, options: .repeating)
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

  private var playback: PlaybackController { PlaybackController.shared }

  var body: some View {
    HStack(spacing: 12) {
      ArtworkImage(artworkPath: song.artworkPath, size: 40, cornerRadius: 4)

      VStack(alignment: .leading, spacing: 2) {
        Text(song.title)
          .font(.system(size: 15, weight: isCurrent ? .semibold : .medium))
          .lineLimit(1)

        Text(song.artist)
          .font(.system(size: 13))
          .foregroundStyle(.secondary)
          .lineLimit(1)
      }

      Spacer()

      if isCurrent {
        Image(systemName: "waveform")
          .font(.system(size: 12))
          .foregroundStyle(.pink)
          .symbolEffect(.pulse, options: .repeating)
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

  private var playback: PlaybackController { PlaybackController.shared }

  var body: some View {
    HStack(spacing: 12) {
      // Number or playing indicator
      if isCurrent {
        Image(systemName: "waveform")
          .font(.system(size: 12))
          .foregroundStyle(.pink)
          .symbolEffect(.pulse, options: .repeating)
          .frame(width: 28, alignment: .center)
      } else {
        Text("\(number)")
          .font(.system(size: 14, weight: .medium))
          .foregroundStyle(.secondary)
          .frame(width: 28, alignment: .center)
      }

      ArtworkImage(artworkPath: song.artworkPath, size: 40, cornerRadius: 4)

      VStack(alignment: .leading, spacing: 2) {
        Text(song.title)
          .font(.system(size: 15, weight: isCurrent ? .semibold : .regular))
          .lineLimit(1)

        Text(song.artist)
          .font(.system(size: 13))
          .foregroundStyle(.secondary)
          .lineLimit(1)
      }

      Spacer()
    }
    .padding(.vertical, 4)
    .songContextMenu(song: song)
  }
}
