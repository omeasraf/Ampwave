//
//  FullScreenPlayerView.swift
//  Ampwave
//

internal import SwiftUI

#if os(iOS)
  import UIKit
#else
  import AppKit
#endif

struct OpenPlayerView: View {
  @Environment(\.dismiss) private var dismiss
  @State private var selectedTab: PlayerTab = .lyrics
  @State private var showingQueue = false
  @State private var isLyricsExpanded = false

  private var playback: PlaybackController { PlaybackController.shared }

  enum PlayerTab: String, CaseIterable {
    case lyrics = "Lyrics"
    case queue = "Queue"
  }

  var body: some View {
    NavigationStack {
      ScrollView {
        VStack(spacing: 28) {
          // Large Artwork
          LargeFixedArtworkView(artworkPath: playback.currentItem?.artworkPath)

          // Track info
          trackInfoSection

          // Progress
          progressSection

          // Playback controls
          playbackControls

          // Extra controls
          extraControls

          // Lyrics/Queue tabs
          tabSection
        }
        .padding(.horizontal, 24)
        .padding(.top, 20)
        .padding(.bottom, 40)
      }
      .background(.ultraThinMaterial)
      .navigationTitle("Now Playing")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .navigationBarLeading) {
          Button {
            dismiss()
          } label: {
            Image(systemName: "chevron.down")
              .font(.system(size: 18, weight: .semibold))
          }
        }

        ToolbarItem(placement: .navigationBarTrailing) {
          Menu {
            Button {
              // Share
            } label: {
              Label("Share", systemImage: "square.and.arrow.up")
            }

            Button {
              // Add to playlist
            } label: {
              Label("Add to Playlist", systemImage: "text.badge.plus")
            }

            Divider()

            Button {
              Task {
                await playback.refreshLyrics()
              }
            } label: {
              Label("Refresh Lyrics", systemImage: "arrow.clockwise")
            }
          } label: {
            Image(systemName: "ellipsis")
              .font(.system(size: 18, weight: .semibold))
          }
        }
      }
    }
    .fullScreenCover(isPresented: $isLyricsExpanded) {
      ExpandedLyricsView(isExpanded: $isLyricsExpanded)
    }
  }

  private var trackInfoSection: some View {
    HStack {
      VStack(alignment: .leading, spacing: 6) {
        Text(playback.currentItem?.title ?? "Not Playing")
          .font(.system(size: 22, weight: .bold))
          .lineLimit(1)

        Text(playback.currentItem?.artist ?? "")
          .font(.system(size: 18))
          .foregroundStyle(.secondary)
          .lineLimit(1)
      }

      Spacer()

      if let song = playback.currentItem {
        Button {
          PlaylistManager.shared.toggleLike(song: song)
        } label: {
          Image(systemName: PlaylistManager.shared.isLiked(song: song) ? "heart.fill" : "heart")
            .font(.system(size: 24))
            .foregroundStyle(PlaylistManager.shared.isLiked(song: song) ? .pink : .primary)
        }
        .contentTransition(.symbolEffect(.replace))
      }
    }
  }

  private var progressSection: some View {
    let duration = max(playback.duration, 0.001)
    let progress = duration > 0 ? min(max(playback.currentTime / duration, 0), 1) : 0.0

    return VStack(spacing: 8) {
      Slider(
        value: Binding(
          get: { progress },
          set: { newValue in
            playback.seek(to: newValue * duration)
          }
        ),
        in: 0...1
      )
      .tint(.primary)

      HStack {
        Text(formatTime(playback.currentTime))
          .font(.system(size: 12, design: .monospaced))
          .foregroundStyle(.secondary)

        Spacer()

        Text(formatTime(duration))
          .font(.system(size: 12, design: .monospaced))
          .foregroundStyle(.secondary)
      }
    }
  }

  private var playbackControls: some View {
    HStack(spacing: 44) {
      Button {
        playback.playPrevious()
      } label: {
        Image(systemName: "backward.fill")
          .font(.system(size: 28))
      }

      Button {
        playback.playPause()
      } label: {
        Image(systemName: playback.isPlaying ? "pause.circle.fill" : "play.circle.fill")
          .font(.system(size: 72))
      }
      .contentTransition(.symbolEffect(.replace))

      Button {
        playback.playNext()
      } label: {
        Image(systemName: "forward.fill")
          .font(.system(size: 28))
      }
    }
    .foregroundStyle(.primary)
  }

  private var extraControls: some View {
    HStack(spacing: 48) {
      Button {
        playback.toggleShuffle()
      } label: {
        Image(systemName: "shuffle")
          .font(.system(size: 22))
          .foregroundStyle(playback.shuffleMode != .off ? .pink : .secondary)
      }

      Button {
        playback.cycleRepeatMode()
      } label: {
        Image(systemName: repeatIcon)
          .font(.system(size: 22))
          .foregroundStyle(repeatColor)
      }

      Button {
        showingQueue = true
      } label: {
        Image(systemName: "list.bullet")
          .font(.system(size: 22))
      }
      .sheet(isPresented: $showingQueue) {
        QueueSheetView()
      }
    }
  }

  private var repeatIcon: String {
    switch playback.repeatMode {
    case .off: return "repeat"
    case .all: return "repeat"
    case .one: return "repeat.1"
    }
  }

  private var repeatColor: Color {
    playback.repeatMode == .off ? .secondary : .pink
  }

  private var tabSection: some View {
    VStack(spacing: 16) {
      Picker("View", selection: $selectedTab) {
        ForEach(PlayerTab.allCases, id: \.self) { tab in
          Text(tab.rawValue).tag(tab)
        }
      }
      .pickerStyle(.segmented)

      var artworkColor: Color = dominantColor(from: playback.currentItem?.artworkPath) ?? .clear

      switch selectedTab {
      case .lyrics:
        CompactLyricsView(
          artworkColor: artworkColor,
          onExpand: {
            isLyricsExpanded = true
          })
      case .queue:
        QueueListView(
          artworkColor: artworkColor,
          songs: playback.upNext,
          currentIndex: nil
        )
      }
    }
  }

  private func formatTime(_ seconds: TimeInterval) -> String {
    let s = Int(seconds)
    let m = s / 60
    let sec = s % 60
    return String(format: "%d:%02d", m, sec)
  }

  func dominantColor(from path: String?) -> Color? {
    if path == nil { return .clear }
    guard let url = PathManager.resolve(path),
      let data = try? Data(contentsOf: url)
    else { return .clear }

    #if os(iOS)
      guard let image = UIImage(data: data) else { return .clear }
      return image.dominantColor()?.opacity(0.3)
    #else
      guard let image = NSImage(data: data) else { return .clear }
      return image.dominantColor()?.opacity(0.3)
    #endif
  }
}
