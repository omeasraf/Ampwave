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
  @State private var isVisible = false
  @State private var scrollTimeout: Timer?
  @Environment(ThemeManager.self) private var themeManager

  @Bindable private var playback = PlaybackController.shared

  var body: some View {
    NavigationStack {
      ZStack {
        // Background blur with artwork
        if let artworkPath = playback.currentItem?.effectiveArtworkPath {
          ArtworkBackgroundView(artworkPath: artworkPath)
        } else {
          themeManager.backgroundColor.ignoresSafeArea()
        }

        // Ambient orbs — slow colour blobs between the background and text
        LyricsAmbientOrbs(color: themeManager.accentColor)
          .ignoresSafeArea()

        // Lyrics content
        Group {
          if let lyrics = playback.currentLyrics, lyrics.hasLyrics {
            ScrollViewReader { proxy in
              ScrollView(.vertical, showsIndicators: false) {
                LazyVStack(spacing: 20) {
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
                guard isVisible, let idx = newIndex, !isUserScrolling, !playback.isScrubbing else {
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

          ToolbarItem(placement: .primaryAction) {
            Button {
              withAnimation(.spring(response: 0.4, dampingFraction: 0.75)) {
                playback.toggleVocalSlider()
              }
            } label: {
                Image(systemName: "waveform.path")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(
                        (playback.isVocalSliderVisible || playback.vocalLevel < 1.0)
                        ? themeManager.accentColor
                        : .white.opacity(0.6)
                    )
            }
          }
        }
      #endif
      .onAppear {
        isVisible = true
        #if os(iOS)
          UIApplication.shared.isIdleTimerDisabled = true
        #endif
      }
      .onDisappear {
        isVisible = false
        #if os(iOS)
          UIApplication.shared.isIdleTimerDisabled = false
        #endif
      }
    }
    .overlay(alignment: .topTrailing) {
      if playback.isVocalSliderVisible {
        VocalSlider(value: $playback.vocalLevel)
          .padding(.top, 64)  // Safe area + toolbar height
          .padding(.trailing, 16)
          .transition(
            .asymmetric(
              insertion: .move(edge: .top).combined(with: .opacity),
              removal: .opacity.combined(with: .scale(scale: 0.9))
            )
          )
          .zIndex(100)
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
  @State private var isVisible = false
  @State private var scrollTimeout: Timer?

  @Bindable private var playback = PlaybackController.shared

  var body: some View {
    VStack {
      if let lyrics = playback.currentLyrics, lyrics.hasLyrics {
        ScrollViewReader { proxy in
          ScrollView(.vertical, showsIndicators: false) {
            LazyVStack(spacing: 12) {
              // Top spacer for centering
              Color.clear
                .frame(height: 60)

              ForEach(
                Array(lyrics.lines.enumerated()),
                id: \.element.timestamp
              ) { index, line in
                // currentTime is NOT read here — it's read only inside LiveWordSyncView
                // (via CompactLyricLineView) for the current line. This means the
                // ForEach only re-renders when currentLyricIndex changes (infrequently),
                // not on every timer tick.
                CompactLyricLineView(
                  line: line,
                  isCurrent: isCurrentLine(index),
                  wordSyncEnabled: line.wordOffsets != nil
                    && (ThemeManager.shared.userPreferences?.wordSyncedLyricsEnabled ?? false)
                )
                .id(index)
                .onTapGesture {
                  playback.seek(to: line.timestamp)
                  if !playback.isPlaying { playback.play() }
                }
              }

              // Bottom spacer for centering
              Color.clear
                .frame(height: 60)
            }
            .padding(.horizontal, 16)
          }
          .onChange(of: playback.currentLyricIndex) { _, newIndex in
            guard isVisible, let index = newIndex, !isUserScrolling, !playback.isScrubbing else {
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
        .cornerRadius(16)
//        .contentShape(Rectangle())
        .onTapGesture {
          onExpand()
        }
        .onAppear { isVisible = true }
        .onDisappear { isVisible = false }
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
        .cornerRadius(16)
//        .contentShape(Rectangle())
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

  private var wordSyncEnabled: Bool {
    themeManager.userPreferences?.wordSyncedLyricsEnabled ?? false
  }

  // True only when this line is active AND karaoke data is available.
  // Drives the content crossfade independently from the line's own scale/opacity.
  private var showKaraoke: Bool {
    isCurrent && wordSyncEnabled && !(line.wordOffsets?.isEmpty ?? true)
  }

  private var mergedWords: [WordOffset] {
    guard let offsets = line.wordOffsets else { return [] }
    return LRCParser.mergeSyllables(offsets)
  }

  var body: some View {
    // ZStack (not Group) gives SwiftUI a stable container identity so that
    // the .transition(.opacity) on each branch actually fires.
    ZStack {
      if showKaraoke {
        // LiveWordSyncView isolates currentTime observation so only this small
        // view re-renders at the high-frequency timer rate, not the full line list.
        LiveWordSyncView(
          words: mergedWords,
          fontSize: 24,
          activeColor: .white
        )
        .transition(.opacity)
      } else {
        plainLineText
          .transition(.opacity)
      }
    }
    // Inner animation: crossfades the content (plain ↔ karaoke) with a smooth
    // ease so the text never pops in or out abruptly.
    .animation(.easeInOut(duration: 0.35), value: showKaraoke)
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
    .opacity(isCurrent ? 1.0 : 0.28)
    .scaleEffect(isCurrent ? 1.08 : 1.0, anchor: .center)
    .id(index)
    .onTapGesture {
      playback.seek(to: line.timestamp)
      if !playback.isPlaying { playback.play() }
    }
    // Outer animation: the scale + opacity breathe when the line becomes current.
    .animation(.spring(response: 0.45, dampingFraction: 0.75), value: isCurrent)
  }

  private var plainLineText: some View {
    Text(displayText)
      .font(.system(size: 24, weight: isCurrent ? .bold : .semibold))
      .foregroundStyle(.white)
  }

  /// Display text derived from (merged) wordOffsets so stale cached
  /// line.text values and unmerged syllable fragments are never shown.
  private var displayText: String {
    guard let offsets = line.wordOffsets, !offsets.isEmpty else { return line.text }
    return LRCParser.mergeSyllables(offsets).map(\.text).joined(separator: " ")
  }
}

/// Single word token — Apple Music style.
///
/// Three layered transitions fire together on a spring when `isActive` flips:
///   • Blur  2.5 → 0     words come *into focus* (the "breathe in" sensation)
///   • Scale 0.92 → 1.0  each word gently expands as it activates
///   • Opacity 0.22 → 1.0 dim → full brightness
///
/// `scaleEffect` is a visual-only transform in SwiftUI — it never affects
/// layout, so neighbouring words in the wrapping grid cannot shift.
private struct WordToken: View {
  let text: String
  let isActive: Bool
  let activeColor: Color
  let fontSize: CGFloat
  let isScrubbing: Bool

  // Slight overshoot (dampingFraction 0.62) gives the activation a tiny
  // elastic "pop" that reads as a breath rather than a mechanical toggle.
  private let spring = Animation.spring(response: 0.45, dampingFraction: 0.62)

  var body: some View {
    Text(text)
      .font(.system(size: fontSize, weight: .bold))
      .foregroundStyle(activeColor)
      .opacity(isScrubbing ? 0.38 : isActive ? 1.0 : 0.22)
      .scaleEffect(isActive && !isScrubbing ? 1.0 : 0.92, anchor: .center)
      .animation(spring, value: isActive)
      .animation(.easeOut(duration: 0.2), value: isScrubbing)
  }
}

struct WordByWordLyricView: View {
  let words: [WordOffset]
  let currentTime: TimeInterval
  let fontSize: CGFloat
  let activeColor: Color
  var isScrubbing: Bool = false

  /// Index of the word whose timestamp has most recently been crossed.
  private var activeUpToIndex: Int {
    var idx = -1
    for (i, word) in words.enumerated() {
      if currentTime >= word.timestamp { idx = i } else { break }
    }
    return idx
  }

  var body: some View {
    WrappingWordsLayout(
      horizontalSpacing: max(5, fontSize * 0.3),
      verticalSpacing:   max(4, fontSize * 0.22)
    ) {
      ForEach(Array(words.enumerated()), id: \.offset) { index, word in
        WordToken(
          text: word.text.trimmingCharacters(in: .whitespacesAndNewlines),
          isActive: index <= activeUpToIndex,
          activeColor: activeColor,
          fontSize: fontSize,
          isScrubbing: isScrubbing
        )
      }
    }
    // NOTE: drawingGroup() is intentionally omitted. It composites everything
    // into a single Metal texture which prevents the per-word spring animations
    // from working — the whole point of the karaoke highlight effect.
  }
}

/// Isolated view that reads PlaybackController.currentTime independently.
/// By confining the high-frequency observation here, the parent lyric-list views
/// only re-render when currentLyricIndex changes (once per line, every few seconds).
private struct LiveWordSyncView: View {
  @Bindable private var playback = PlaybackController.shared
  let words: [WordOffset]
  let fontSize: CGFloat
  let activeColor: Color

  var body: some View {
    WordByWordLyricView(
      words: words,
      currentTime: playback.currentTime,       // high-frequency — only THIS view re-renders
      fontSize: fontSize,
      activeColor: activeColor,
      isScrubbing: playback.isScrubbing
    )
  }
}

private struct CompactLyricLineView: View {
  let line: LyricLine
  let isCurrent: Bool
  let wordSyncEnabled: Bool

  var body: some View {
    Group {
      if isCurrent, wordSyncEnabled, let words = line.wordOffsets, !words.isEmpty {
        // LiveWordSyncView isolates high-frequency currentTime reads so only
        // this word view re-renders on every timer tick, not the full scroll list.
        LiveWordSyncView(
          words: LRCParser.mergeSyllables(words),
          fontSize: 15,
          activeColor: .primary
        )
      } else {
        Text(displayText)
          .font(.system(size: 15, weight: isCurrent ? .semibold : .regular))
          .foregroundStyle(isCurrent ? Color.primary : Color.secondary)
      }
    }
    .multilineTextAlignment(.center)
    .lineLimit(nil)
    .fixedSize(horizontal: false, vertical: true)
    .padding(.horizontal, 16)
    .frame(minWidth: 0, maxWidth: .infinity, alignment: .center)
    .opacity(isCurrent ? 1.0 : 0.55)
    .scaleEffect(isCurrent ? 1.05 : 1.0, anchor: .center)
    .animation(.spring(response: 0.3, dampingFraction: 0.75), value: isCurrent)
  }

  private var displayText: String {
    guard let offsets = line.wordOffsets, !offsets.isEmpty else { return line.text }
    return LRCParser.mergeSyllables(offsets).map(\.text).joined(separator: " ")
  }
}

// MARK: - Ambient background orbs

/// Slow-moving colour blobs that sit between the blurred artwork and the
/// lyrics text, mimicking the ambient gradient effect in Apple Music's
/// full-screen lyrics view. They breathe independently at different rates
/// so the result never looks mechanical.
private struct LyricsAmbientOrbs: View {
  let color: Color
  @State private var phase = false

  var body: some View {
    ZStack {
      // Primary orb — top-left, largest
      Circle()
        .fill(color.opacity(0.5))
        .frame(width: 360)
        .blur(radius: 100)
        .offset(x: phase ? -60 : -100, y: phase ? -200 : -260)
        .scaleEffect(phase ? 1.2 : 0.8)
        .animation(
          .easeInOut(duration: 8).repeatForever(autoreverses: true),
          value: phase
        )

      // Secondary orb — top-right, medium
      Circle()
        .fill(color.opacity(0.35))
        .frame(width: 280)
        .blur(radius: 85)
        .offset(x: phase ? 110 : 70, y: phase ? -140 : -190)
        .scaleEffect(phase ? 0.85 : 1.15)
        .animation(
          .easeInOut(duration: 6.5).repeatForever(autoreverses: true),
          value: phase
        )

      // Accent orb — lower-centre, small
      Circle()
        .fill(color.opacity(0.25))
        .frame(width: 200)
        .blur(radius: 70)
        .offset(x: phase ? 20 : -30, y: phase ? 60 : 20)
        .scaleEffect(phase ? 1.1 : 0.88)
        .animation(
          .easeInOut(duration: 9).repeatForever(autoreverses: true),
          value: phase
        )
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    .allowsHitTesting(false)
    .onAppear { phase = true }
  }
}

private struct WrappingWordsLayout: Layout {
  var horizontalSpacing: CGFloat
  var verticalSpacing: CGFloat

  func sizeThatFits(
    proposal: ProposedViewSize,
    subviews: Subviews,
    cache: inout Void
  ) -> CGSize {
    let rows = arrangedRows(proposal: proposal, subviews: subviews)
    let width = rows.map(\.width).max() ?? 0
    let height = rows.last.map { $0.y + $0.height } ?? 0
    return CGSize(width: width, height: height)
  }

  func placeSubviews(
    in bounds: CGRect,
    proposal: ProposedViewSize,
    subviews: Subviews,
    cache: inout Void
  ) {
    let rows = arrangedRows(proposal: ProposedViewSize(width: bounds.width, height: proposal.height), subviews: subviews)

    for row in rows {
      let rowX = bounds.minX + max(0, (bounds.width - row.width) / 2)

      for item in row.items {
        subviews[item.index].place(
          at: CGPoint(x: rowX + item.x, y: bounds.minY + row.y),
          anchor: .topLeading,
          proposal: ProposedViewSize(item.size)
        )
      }
    }
  }

  private func arrangedRows(proposal: ProposedViewSize, subviews: Subviews) -> [Row] {
    let maxWidth = proposal.width ?? subviews.reduce(CGFloat.zero) { partial, subview in
      partial + subview.sizeThatFits(.unspecified).width + horizontalSpacing
    }

    var rows: [Row] = []
    var currentItems: [RowItem] = []
    var currentX: CGFloat = 0
    var currentY: CGFloat = 0
    var currentHeight: CGFloat = 0

    for index in subviews.indices {
      let size = subviews[index].sizeThatFits(.unspecified)
      let nextX = currentItems.isEmpty ? size.width : currentX + horizontalSpacing + size.width

      if nextX > maxWidth, !currentItems.isEmpty {
        rows.append(Row(items: currentItems, y: currentY, width: currentX, height: currentHeight))
        currentY += currentHeight + verticalSpacing
        currentItems = []
        currentX = 0
        currentHeight = 0
      }

      let x = currentItems.isEmpty ? 0 : currentX + horizontalSpacing
      currentItems.append(RowItem(index: index, x: x, size: size))
      currentX = x + size.width
      currentHeight = max(currentHeight, size.height)
    }

    if !currentItems.isEmpty {
      rows.append(Row(items: currentItems, y: currentY, width: currentX, height: currentHeight))
    }

    return rows
  }

  private struct Row {
    let items: [RowItem]
    let y: CGFloat
    let width: CGFloat
    let height: CGFloat
  }

  private struct RowItem {
    let index: Int
    let x: CGFloat
    let size: CGSize
  }
}
