//
//  ExpandedLyricsView.swift
//  Ampwave
//
//  Created by Ome Asraf on 4/3/26.
//

internal import SwiftUI

struct ExpandedLyricsView: View {
  @Binding var isExpanded: Bool
  @State private var isUserScrolling = false
  @State private var scrollTimeout: Timer?

  private var playback: PlaybackController { PlaybackController.shared }

  var body: some View {
    NavigationStack {
      ZStack {
        // Background blur with artwork
        if let artworkPath = playback.currentItem?.artworkPath {
          ArtworkBackgroundView(artworkPath: artworkPath)
        } else {
          Color.clear.ignoresSafeArea()
        }

        // Lyrics content
        if let lyrics = playback.currentLyrics, lyrics.hasLyrics {
          ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: false) {
              VStack(spacing: 20) {
                // Top spacer for centering first line
                Spacer()
                  .frame(height: 200)

                ForEach(Array(lyrics.lines.enumerated()), id: \.element.timestamp) { index, line in
                  Text(line.text)
                    .font(
                      .system(
                        size: isCurrentLine(index) ? 28 : 18,
                        weight: isCurrentLine(index) ? .bold : .semibold)
                    )
                    .foregroundStyle(isCurrentLine(index) ? .white : .white.opacity(0.4))
                    .multilineTextAlignment(.center)
                    .lineLimit(nil)
                    .lineSpacing(2)
                    .opacity(isCurrentLine(index) ? 1.0 : 0.6)
                    .frame(maxWidth: 320, alignment: .center)
                    .id(index)
                    .onTapGesture {
                      playback.seek(to: line.timestamp)
                    }
                    .animation(.easeInOut(duration: 0.3), value: playback.currentLyricIndex)
                }

                // Bottom spacer for centering last line
                Spacer()
                  .frame(height: 200)
              }
              .frame(maxWidth: .infinity)
              .padding(.horizontal, 40)
            }
            .id(playback.currentItem?.id)
            .id(playback.currentItem?.id)
            .onChange(of: playback.currentLyricIndex) { _, newIndex in
              guard let idx = newIndex else { return }
              if !isUserScrolling {
                withAnimation(.easeInOut(duration: 0.35)) {
                  proxy.scrollTo(idx, anchor: .center)
                }
              }
            }
            .onScrollPhaseChange { _, newPhase in
              switch newPhase {
              case .idle:
                scrollTimeout?.invalidate()
                scrollTimeout = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: false) { _ in
                  isUserScrolling = false
                }
              default:
                isUserScrolling = true
                scrollTimeout?.invalidate()
              }
            }
          }
        } else {
          VStack(spacing: 20) {
            Image(systemName: "text.quote")
              .font(.system(size: 80))
              .foregroundStyle(.secondary)

            Text("No Lyrics Available")
              .font(.title2.bold())
              .foregroundStyle(.white)
          }
        }
      }
      .navigationTitle(playback.currentItem?.title ?? "")
      .navigationBarTitleDisplayMode(.inline)
      .onChange(of: playback.currentItem?.id) { _, _ in
        // When song changes, lyrics view will automatically update due to @Observable
      }
      .toolbar {
        ToolbarItem(placement: .navigationBarLeading) {
          Button {
            isExpanded = false
          } label: {
            Image(systemName: "chevron.down")
              .font(.system(size: 18, weight: .semibold))
              .foregroundStyle(.white)
          }
        }

        ToolbarItem(placement: .navigationBarTrailing) {
          Button {
            Task {
              await playback.refreshLyrics()
            }
          } label: {
            Image(systemName: "arrow.clockwise")
              .font(.system(size: 18))
              .foregroundStyle(.white)
          }
        }
      }
      .preferredColorScheme(.dark)
    }
  }

  private func isCurrentLine(_ index: Int) -> Bool {
    playback.currentLyricIndex == index
  }
}

// MARK: - Compact Lyrics View (Apple Music Style)

struct CompactLyricsView: View {
  let artworkColor: Color?
  let onExpand: () -> Void
  @State private var isUserScrolling = false
  @State private var scrollTimeout: Timer?

  private var playback: PlaybackController { PlaybackController.shared }

  var body: some View {
    VStack {
      if let lyrics = playback.currentLyrics, lyrics.hasLyrics {
        ScrollViewReader { proxy in
          ScrollView(.vertical, showsIndicators: false) {
            VStack(spacing: 12) {
              // Top spacer for centering
              Spacer()
                .frame(height: 60)

              ForEach(Array(lyrics.lines.enumerated()), id: \.element.timestamp) { index, line in
                Text(line.text)
                  .font(
                    .system(
                      size: isCurrentLine(index) ? 18 : 14,
                      weight: isCurrentLine(index) ? .semibold : .regular)
                  )
                  .foregroundStyle(isCurrentLine(index) ? .primary : .secondary)
                  .multilineTextAlignment(.center)
                  .frame(maxWidth: .infinity)
                  .lineLimit(nil)
                  .opacity(isCurrentLine(index) ? 1.0 : 0.5)
                  .id(index)
                  .onTapGesture {
                    playback.seek(to: line.timestamp)
                  }
                  .animation(.easeInOut(duration: 0.2), value: playback.currentLyricIndex)
              }

              // Bottom spacer for centering
              Spacer()
                .frame(height: 60)
            }
            .padding(.horizontal, 16)
          }
          .onChange(of: playback.currentLyricIndex) { _, newIndex in
            guard let index = newIndex else { return }
            if !isUserScrolling {
              withAnimation(.easeInOut(duration: 0.3)) {
                proxy.scrollTo(index, anchor: .center)
              }
            }
          }
          .onScrollPhaseChange { _, newPhase in
            switch newPhase {
            case .idle:
              scrollTimeout?.invalidate()
              scrollTimeout = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: false) { _ in
                isUserScrolling = false
                // Auto-scroll back to current line when timeout expires
                if let currentIndex = playback.currentLyricIndex {
                  withAnimation(.easeInOut(duration: 0.3)) {
                    proxy.scrollTo(currentIndex, anchor: .center)
                  }
                }
              }
            default:
              isUserScrolling = true
              scrollTimeout?.invalidate()
            }
          }
        }
        .frame(height: 200)
        .background(artworkColor)
        .cornerRadius(10)
        .contentShape(Rectangle())
        .onTapGesture {
          onExpand()
        }
      } else {
        VStack(spacing: 16) {
          Spacer()

          Image(systemName: "text.quote")
            .font(.system(size: 60))
            .foregroundStyle(.secondary)

          Text("No Lyrics Available")
            .font(.system(size: 18, weight: .semibold))

          Text("Lyrics will appear here when available")
            .font(.system(size: 15))
            .foregroundStyle(.secondary)

          // Fetch lyrics button (only if there's a current item)
          //   if playback.currentItem != nil {
          //     Button {
          //       Task {
          //         await playback.refreshLyrics()
          //       }
          //     } label: {
          //       Label("Fetch Lyrics", systemImage: "arrow.down.circle")
          //     }
          //     .padding(.top)
          //   }

          Spacer()
        }
        .frame(minHeight: 200)
      }
    }
  }

  private func isCurrentLine(_ index: Int) -> Bool {
    playback.currentLyricIndex == index
  }
}
