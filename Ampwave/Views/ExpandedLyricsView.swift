//
//  ExpandedLyricsView.swift
//  Ampwave
//
//  Created by Ome Asraf on 4/3/26.
//

internal import SwiftUI

#if os(iOS)
  import UIKit
#endif

struct ExpandedLyricsView: View {
  @Binding var isExpanded: Bool
  @State private var isUserScrolling = false
  @State private var isProgrammaticScroll = false
  @State private var scrollTimeout: Timer?
  @Environment(ThemeManager.self) private var themeManager

  @Bindable private var playback = PlaybackController.shared

  var body: some View {
    NavigationStack {
      ZStack {
        // Background blur with artwork
        if let artworkPath = playback.currentItem?.artworkPath {
          ArtworkBackgroundView(artworkPath: artworkPath)
        } else {
          themeManager.backgroundColor.ignoresSafeArea()
        }

        // Lyrics content
        Group {
          if let lyrics = playback.currentLyrics, lyrics.hasLyrics {
            ScrollViewReader { proxy in
              ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 20) {
                  // Top spacer for centering first line
                  Color.clear
                    .frame(height: 200)

                  ForEach(
                    Array(lyrics.lines.enumerated()),
                    id: \.element.timestamp
                  ) { index, line in
                    LyricLineView(
                      line: line,
                      index: index,
                      isCurrent: isCurrentLine(index),
                      playback: playback
                    )
                  }

                  // Bottom spacer for centering last line
                  Color.clear
                    .frame(height: 200)
                }
                #if os(iOS)
                  .frame(width: UIScreen.main.bounds.width)
                #else
                  .frame(maxWidth: .infinity)
                #endif
              }
              .id(playback.currentItem?.id)
              .onChange(of: playback.currentLyricIndex) { _, newIndex in
                guard let idx = newIndex, !isUserScrolling else {
                  return
                }
                isProgrammaticScroll = true
                withAnimation(.easeInOut(duration: 0.35)) {
                  proxy.scrollTo(idx, anchor: .center)
                }
              }
              .onScrollPhaseChange { _, newPhase in
                switch newPhase {
                case .idle:
                  if isProgrammaticScroll {
                    isProgrammaticScroll = false
                    return
                  }
                  scrollTimeout?.invalidate()
                  scrollTimeout = Timer.scheduledTimer(
                    withTimeInterval: 1.5,
                    repeats: false
                  ) { _ in
                    isUserScrolling = false
                    if let currentIndex = playback.currentLyricIndex {
                      isProgrammaticScroll = true
                      withAnimation(.easeInOut(duration: 0.35)) {
                        proxy.scrollTo(
                          currentIndex,
                          anchor: .center
                        )
                      }
                    }
                  }
                default:
                  if !isProgrammaticScroll {
                    isUserScrolling = true
                    scrollTimeout?.invalidate()
                  }
                }
              }
            }
          } else if let plainLyrics = playback.currentItem?.lyrics,
            !plainLyrics.isEmpty
          {
            ScrollView(.vertical, showsIndicators: false) {
              VStack(spacing: 30) {
                Color.clear.frame(height: 200)

                ForEach(plainLyrics.cleanedLRC.components(separatedBy: "\n"), id: \.self) { line in
                  Text(line)
                    .font(.system(size: 24, weight: .medium))
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
                }

                Color.clear.frame(height: 200)
              }
              #if os(iOS)
                .frame(width: UIScreen.main.bounds.width)
              #else
                .frame(maxWidth: .infinity)
              #endif
            }
          } else if playback.isLoading {
            ProgressView()
              .controlSize(.large)
              .tint(.white)
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
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .navigationTitle(playback.currentItem?.title ?? "")
      #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)

        .toolbar {
          ToolbarItem(placement: .navigation) {
            Button {
              isExpanded = false
            } label: {
              Image(systemName: "chevron.down")
              .font(.system(size: 18, weight: .semibold))
              .foregroundStyle(.white)
            }
          }
        }
      #endif
      .onAppear {
        #if os(iOS)
          UIApplication.shared.isIdleTimerDisabled = true
        #endif
      }
      .onDisappear {
        #if os(iOS)
          UIApplication.shared.isIdleTimerDisabled = false
        #endif
      }
    }
  }

  private func isCurrentLine(_ index: Int) -> Bool {
    playback.currentLyricIndex == index
  }

}

// MARK: - String+LRC
extension String {
  /// Returns true if the string looks like an LRC lyrics file (has timestamp tags like [00:00.00]).
  fileprivate var isLRCFormatted: Bool {
    let lrcPattern = #/^\[\d{2}:\d{2}[.:]\d{2,3}\]/#
    return self.split(separator: "\n").prefix(10).contains { line in
      line.trimmingCharacters(in: .whitespaces).firstMatch(of: lrcPattern) != nil
    }
  }

  /// Removes LRC tags from the string.
  fileprivate var cleanedLRC: String {
    let pattern = #"\[\d{2}:\d{2}[.:]\d{2,3}\]"#
    return self.replacingOccurrences(
      of: pattern,
      with: "",
      options: .regularExpression
    )
    .trimmingCharacters(in: .whitespacesAndNewlines)
  }
}

struct CompactLyricsView: View {
  let artworkColor: Color?
  let onExpand: () -> Void
  @State private var isUserScrolling = false
  @State private var isProgrammaticScroll = false
  @State private var scrollTimeout: Timer?

  @Bindable private var playback = PlaybackController.shared

  var body: some View {
    VStack {
      if let lyrics = playback.currentLyrics, lyrics.hasLyrics {
        ScrollViewReader { proxy in
          ScrollView(.vertical, showsIndicators: false) {
            VStack(spacing: 12) {
              // Top spacer for centering
              Color.clear
                .frame(height: 60)

              ForEach(
                Array(lyrics.lines.enumerated()),
                id: \.element.timestamp
              ) { index, line in
                Text(line.text)
                  .font(
                    .system(
                      size: 15,
                      weight: isCurrentLine(index)
                        ? .bold : .regular
                    )
                  )
                  .foregroundStyle(
                    isCurrentLine(index)
                      ? .primary : .secondary
                  )
                  .multilineTextAlignment(.center)
                  .lineLimit(nil)
                  .fixedSize(
                    horizontal: false,
                    vertical: true
                  )
                  .padding(.horizontal, 16)
                  .frame(
                    minWidth: 0,
                    maxWidth: .infinity,
                    alignment: .center
                  )
                  .scaleEffect(
                    isCurrentLine(index) ? 1.08 : 1.0,
                    anchor: .center
                  )
                  .id(index)
                  .onTapGesture {
                    playback.seek(to: line.timestamp)
                    if !playback.isPlaying {
                      playback.play()
                    }
                  }
                  .animation(
                    .spring(
                      response: 0.3,
                      dampingFraction: 0.7
                    ),
                    value: playback.currentLyricIndex
                  )
              }

              // Bottom spacer for centering
              Color.clear
                .frame(height: 60)
            }
            .padding(.horizontal, 16)
          }
          .onChange(of: playback.currentLyricIndex) { _, newIndex in
            guard let index = newIndex, !isUserScrolling else {
              return
            }
            isProgrammaticScroll = true
            withAnimation(.easeInOut(duration: 0.3)) {
              proxy.scrollTo(index, anchor: .center)
            }
          }
          .onScrollPhaseChange { _, newPhase in
            switch newPhase {
            case .idle:
              if isProgrammaticScroll {
                isProgrammaticScroll = false
                return
              }
              scrollTimeout?.invalidate()
              scrollTimeout = Timer.scheduledTimer(
                withTimeInterval: 1.5,
                repeats: false
              ) { _ in
                isUserScrolling = false
                if let currentIndex = playback.currentLyricIndex {
                  isProgrammaticScroll = true
                  withAnimation(.easeInOut(duration: 0.3)) {
                    proxy.scrollTo(
                      currentIndex,
                      anchor: .center
                    )
                  }
                }
              }
            default:
              if !isProgrammaticScroll {
                isUserScrolling = true
                scrollTimeout?.invalidate()
              }
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
      } else if let plainLyrics = playback.currentItem?.lyrics,
        !plainLyrics.isEmpty
      {
        // Plain text fallback
        ScrollView(.vertical, showsIndicators: false) {
          VStack(spacing: 12) {
            Color.clear.frame(height: 40)
            Text(plainLyrics.cleanedLRC)
              .font(
                .system(
                  size: 15,
                  weight: .regular
                )
              )
              .foregroundStyle(.secondary)
              .multilineTextAlignment(.center)
              .lineLimit(nil)
              .fixedSize(
                horizontal: false,
                vertical: true
              )
              .padding(.horizontal, 16)
              .frame(
                minWidth: 0,
                maxWidth: .infinity,
                alignment: .center
              )
            Color.clear.frame(height: 40)
          }
          .frame(maxWidth: .infinity)
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

#Preview {
  let mockSong = LibrarySong(
    title: "Unknown Track",
    artist: "The Mockers",
    fileName: "nonsense.mp3",
    fileHash: "abc",
    size: 1024,
    duration: 180
  )

  let mockLines = [
    LyricLine(timestamp: 0, text: "Welcome to the nonsense track"),
    LyricLine(timestamp: 5, text: "This is the second line of the song"),
    LyricLine(
      timestamp: 10,
      text:
        "A very long line to test wrapping and padding in the expanded view to see if it works correctly"
    ),
    LyricLine(timestamp: 15, text: "Everything seems to be working now"),
    LyricLine(timestamp: 20, text: "The current line should be bold and bright"),
    LyricLine(timestamp: 25, text: "While others are dimmed and semibold"),
    LyricLine(timestamp: 30, text: "Scrolling should happen automatically"),
    LyricLine(timestamp: 35, text: "End of the preview"),
  ]

  let mockLyrics = SyncedLyric(
    songId: mockSong.id,
    lines: mockLines,
    source: .local
  )

  let _ = {
    PlaybackController.shared.setupMockPlayback(
      song: mockSong,
      lyrics: mockLyrics,
      time: 12
    )
  }()

  return ExpandedLyricsView(isExpanded: .constant(true))
}

struct LyricLineView: View {
  let line: LyricLine
  let index: Int
  let isCurrent: Bool
  @Bindable var playback: PlaybackController
  @Environment(ThemeManager.self) private var themeManager

  var body: some View {
    Group {
      if isCurrent, themeManager.userPreferences?.wordSyncedLyricsEnabled ?? true,
        let words = line.wordOffsets,
        !words.isEmpty
      {
        WordByWordLyricView(
          words: words,
          currentTime: playback.currentTime,
          isCurrent: true
        )
      } else {
        Text(line.text)
          .font(
            .system(
              size: 24,
              weight: isCurrent ? .bold : .semibold
            )
          )
          .foregroundStyle(
            isCurrent ? .white : .white.opacity(0.35)
          )
      }
    }
    .multilineTextAlignment(.center)
    .lineLimit(nil)
    .fixedSize(horizontal: false, vertical: true)
    .lineSpacing(4)
    .padding(.horizontal, 32)
    #if os(iOS)
      .frame(maxWidth: UIScreen.main.bounds.width - 64)
    #else
      .frame(maxWidth: .infinity)
    #endif
    .scaleEffect(
      isCurrent ? 1.05 : 1.0,
      anchor: .center
    )
    .id(index)
    .onTapGesture {
      playback.seek(to: line.timestamp)
      if !playback.isPlaying {
        playback.play()
      }
    }
    .animation(
      .spring(response: 0.3, dampingFraction: 0.7),
      value: playback.currentLyricIndex
    )
  }
}

struct WordByWordLyricView: View {
  let words: [WordOffset]
  let currentTime: TimeInterval
  let isCurrent: Bool

  var body: some View {
    // Flowing layout for words
    // We use a simple wrap-around approach by joining Text views or using a custom layout
    // For simplicity and best visual effect, we can use a Canvas or just multiple Text views in a container.
    // SwiftUI's Text concatenation is great for this.
    
    words.reduce(Text("")) { (result, word) in
      let isWordPassed = currentTime >= word.timestamp
      return result + Text(word.text)
        .font(.system(size: 24, weight: .bold))
        .foregroundStyle(isWordPassed ? .white : .white.opacity(0.35))
    }
  }
}
