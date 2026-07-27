//
//  ExpandedLyricsView.swift
//  Ampwave
//
//  Created by Ome Asraf on 4/3/26.
//

internal import SwiftUI

#if canImport(UIKit)
  import UIKit
#elseif canImport(AppKit)
  import AppKit
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
                // The scroll view's own width, not the screen's: UIScreen
                // ignores split view, Stage Manager and any window that isn't
                // full screen, so pinning to it can size the content wider
                // than the space it actually has.
                .frame(maxWidth: .infinity)
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
              .frame(maxWidth: .infinity)
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
        .toolbarBackgroundVisibility(.hidden, for: .navigationBar)
        // The backdrop behind the bar is always dark artwork, so the title and
        // buttons need light chrome regardless of the system appearance.
        .toolbarColorScheme(.dark, for: .navigationBar)
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
                // currentTime is NOT read here — only inside KaraokeLineView,
                // for the current line. So this ForEach re-renders when
                // currentLyricIndex changes (every few seconds), not on every
                // playback tick.
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

// MARK: - Karaoke model

/// One display word of a word-synced line, with the window during which its
/// highlight sweeps across it.
struct KaraokeWord: Identifiable {
  let id: Int
  let text: String
  let start: TimeInterval
  var end: TimeInterval
}

enum KaraokeLine {
  /// Groups timestamped tokens into display words.
  ///
  /// Sources disagree about tokenisation: enhanced-LRC strips the spaces and
  /// emits one token per syllable ("provoca", "tive"), while TTML and
  /// LyricsPlus spans carry their own spacing. Guessing word boundaries from
  /// the token text alone is what produced "wannabe" — "wanna" is
  /// indistinguishable from a syllable fragment by shape.
  ///
  /// `line.text` already holds the correctly spaced line, so use *it* as the
  /// authority: walk it alongside the tokens and start a new word wherever the
  /// text has whitespace. If the two disagree the text is stale, and we fall
  /// back to one word per token.
  static func words(for line: LyricLine) -> [KaraokeWord] {
    guard let offsets = line.wordOffsets, !offsets.isEmpty else { return [] }

    let tokens: [(text: String, timestamp: TimeInterval)] = offsets.compactMap {
      let text = $0.text.trimmingCharacters(in: .whitespacesAndNewlines)
      return text.isEmpty ? nil : (text, $0.timestamp)
    }
    guard !tokens.isEmpty else { return [] }

    let grouped =
      grouped(tokens, using: line.text)
      ?? tokens.enumerated().map {
        KaraokeWord(id: $0.offset, text: $0.element.text, start: $0.element.timestamp, end: 0)
      }

    return withSweepWindows(grouped)
  }

  private static func grouped(
    _ tokens: [(text: String, timestamp: TimeInterval)],
    using lineText: String
  ) -> [KaraokeWord]? {
    let characters = Array(lineText)

    // A line whose text lost its spaces (some cached/reconstructed lines come
    // back with every word run together) can't tell us anything about word
    // boundaries.
    guard tokens.count == 1 || characters.contains(where: { $0.isWhitespace }) else { return nil }

    // The tokens must spell out the line once whitespace is removed, otherwise
    // the text belongs to different lyrics than the timings.
    guard Array(tokens.map(\.text).joined()) == characters.filter({ !$0.isWhitespace }) else {
      return nil
    }

    var words: [KaraokeWord] = []
    var index = 0
    var pending = ""
    var pendingStart: TimeInterval = 0

    for token in tokens {
      var crossedSpace = false
      while index < characters.count, characters[index].isWhitespace {
        index += 1
        crossedSpace = true
      }
      if crossedSpace, !pending.isEmpty {
        words.append(KaraokeWord(id: words.count, text: pending, start: pendingStart, end: 0))
        pending = ""
      }
      if pending.isEmpty { pendingStart = token.timestamp }
      pending += token.text
      index += token.text.count
    }
    if !pending.isEmpty {
      words.append(KaraokeWord(id: words.count, text: pending, start: pendingStart, end: 0))
    }

    return words.isEmpty ? nil : words
  }

  /// A word's highlight sweeps from its own timestamp to the next word's, so
  /// the fill runs continuously along the line. Capped so a word held before a
  /// long pause doesn't crawl for seconds.
  private static func withSweepWindows(_ words: [KaraokeWord]) -> [KaraokeWord] {
    var result = words
    for index in result.indices {
      let next =
        index + 1 < result.count
        ? result[index + 1].start
        : result[index].start + 0.6
      result[index].end = max(
        result[index].start + 0.12,
        min(next, result[index].start + 1.1)
      )
    }
    return result
  }
}

enum LyricText {
  /// Prefer the line's own text — every parser reconstructs it with the
  /// source's real spacing. Only rebuild from tokens when it is missing or has
  /// lost its spaces, because a run-together line has nowhere to wrap and
  /// spills off both edges of the screen.
  static func display(for line: LyricLine) -> String {
    let text = line.text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let offsets = line.wordOffsets, !offsets.isEmpty else { return text }

    if !text.isEmpty, offsets.count == 1 || text.contains(where: { $0.isWhitespace }) {
      return text
    }

    return
      offsets
      .map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }
      .filter { !$0.isEmpty }
      .joined(separator: " ")
  }
}

private enum LyricMetrics {
  /// Width of a real space in the lyric font, so a karaoke line's word gaps
  /// match the plain lines above and below it exactly.
  static func spaceWidth(fontSize: CGFloat) -> CGFloat {
    #if canImport(UIKit)
      let font = UIFont.systemFont(ofSize: fontSize, weight: .bold)
    #elseif canImport(AppKit)
      let font = NSFont.systemFont(ofSize: fontSize, weight: .bold)
    #else
      return fontSize * 0.26
    #endif
    return (" " as NSString).size(withAttributes: [.font: font]).width
  }
}

// MARK: - Lines

struct LyricLineView: View {
  let line: LyricLine
  let index: Int
  let isCurrent: Bool
  @Bindable var playback: PlaybackController
  @Environment(ThemeManager.self) private var themeManager

  private var karaokeWords: [KaraokeWord] {
    guard isCurrent, themeManager.userPreferences?.wordSyncedLyricsEnabled ?? false else {
      return []
    }
    return KaraokeLine.words(for: line)
  }

  var body: some View {
    ZStack {
      if !karaokeWords.isEmpty {
        KaraokeLineView(words: karaokeWords, fontSize: 24, color: .white)
          .transition(.opacity)
      } else {
        Text(LyricText.display(for: line))
          .font(.system(size: 24, weight: isCurrent ? .bold : .semibold))
          .foregroundStyle(.white)
          .transition(.opacity)
      }
    }
    .animation(.easeInOut(duration: 0.3), value: karaokeWords.isEmpty)
    .multilineTextAlignment(.center)
    .lineLimit(nil)
    .fixedSize(horizontal: false, vertical: true)
    .lineSpacing(4)
    // Inactive lines recede rather than shrink — matching Apple Music, where
    // the sung line is simply the one in focus.
    //
    // Modifier order below is load-bearing, not stylistic. Tap-to-seek broke
    // when `.animation(_:value:)` sat at the very end of the chain, wrapping
    // the gesture: taps on a line stopped registering entirely. Keep every
    // visual/animated modifier *above* the tap target so the gesture is the
    // outermost thing on the row. (Verified by testing: `.blur` and the
    // position of `.id` were both ruled out as causes.)
    .opacity(isCurrent ? 1.0 : 0.34)
    .blur(radius: isCurrent ? 0 : 1.1)
    .scaleEffect(isCurrent ? 1.0 : 0.965, anchor: .center)
    .animation(.spring(response: 0.45, dampingFraction: 0.78), value: isCurrent)
    // Padding first, then the flexible frame: the other way round the frame
    // takes the full width and the padding pushes past both edges.
    .padding(.horizontal, 32)
    .frame(maxWidth: .infinity)
    .id(index)
    // The whole row seeks, not just the glyphs.
    .contentShape(Rectangle())
    .onTapGesture {
      playback.seek(to: line.timestamp)
      if !playback.isPlaying { playback.play() }
    }
  }
}

/// The active word-synced line.
///
/// Drawn from a display-linked timeline rather than the player's 30 Hz sampling
/// so the highlight sweeps continuously instead of stepping word to word.
private struct KaraokeLineView: View {
  @Bindable private var playback = PlaybackController.shared
  let words: [KaraokeWord]
  let fontSize: CGFloat
  let color: Color

  var body: some View {
    TimelineView(.animation(paused: !playback.isPlaying || playback.isScrubbing)) { _ in
      let now = playback.lyricsClock.interpolatedTime(
        isPlaying: playback.isPlaying && !playback.isScrubbing
      )

      WrappingWordsLayout(
        horizontalSpacing: LyricMetrics.spaceWidth(fontSize: fontSize),
        verticalSpacing: fontSize * 0.3
      ) {
        ForEach(words) { word in
          KaraokeWordView(
            text: word.text,
            progress: playback.isScrubbing ? 0 : progress(of: word, at: now),
            fontSize: fontSize,
            color: color
          )
          // Seek to the exact word. Sits inside the line's own tap target, so
          // tapping a word goes to that word and tapping the gaps around them
          // falls through to the start of the line.
          .contentShape(Rectangle())
          .onTapGesture {
            playback.seek(to: word.start)
            if !playback.isPlaying { playback.play() }
          }
        }
      }
    }
  }

  private func progress(of word: KaraokeWord, at time: TimeInterval) -> Double {
    guard time > word.start else { return 0 }
    guard time < word.end else { return 1 }
    return (time - word.start) / (word.end - word.start)
  }
}

/// A single word, lit by a soft-edged wipe travelling through its glyphs.
private struct KaraokeWordView: View {
  let text: String
  let progress: Double
  let fontSize: CGFloat
  let color: Color

  private var isSinging: Bool { progress > 0 && progress < 1 }

  var body: some View {
    label(color.opacity(0.3))
      .overlay(alignment: .leading) {
        label(color).mask(alignment: .leading) { sweep }
      }
      // A breath of lift and glow on the word being sung. Deliberately no
      // scaling: scaling individual words changes the gaps around them and
      // makes the line look unevenly spaced.
      .offset(y: isSinging ? -1.5 : 0)
      .shadow(color: color.opacity(isSinging ? 0.4 : 0), radius: 9)
      .animation(.spring(response: 0.4, dampingFraction: 0.7), value: isSinging)
  }

  private func label(_ style: Color) -> some View {
    Text(text)
      .font(.system(size: fontSize, weight: .bold))
      .foregroundStyle(style)
      .lineLimit(1)
      .minimumScaleFactor(0.5)
  }

  @ViewBuilder
  private var sweep: some View {
    if progress >= 1 {
      Color.white
    } else if progress <= 0 {
      Color.clear
    } else {
      LinearGradient(
        stops: [
          .init(color: .white, location: max(0, progress - 0.22)),
          .init(color: .white.opacity(0), location: min(1, progress + 0.08)),
        ],
        startPoint: .leading,
        endPoint: .trailing
      )
    }
  }
}

private struct CompactLyricLineView: View {
  let line: LyricLine
  let isCurrent: Bool
  let wordSyncEnabled: Bool

  private var karaokeWords: [KaraokeWord] {
    guard isCurrent, wordSyncEnabled else { return [] }
    return KaraokeLine.words(for: line)
  }

  var body: some View {
    Group {
      if !karaokeWords.isEmpty {
        KaraokeLineView(words: karaokeWords, fontSize: 15, color: .primary)
      } else {
        Text(LyricText.display(for: line))
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
    .animation(.spring(response: 0.3, dampingFraction: 0.78), value: isCurrent)
  }
}

// MARK: - Ambient background orbs

/// Slow-moving colour blobs that sit between the blurred artwork and the
/// lyrics text, mimicking the ambient gradient in Apple Music's full-screen
/// lyrics. They breathe at different rates so the result never looks
/// mechanical.
private struct LyricsAmbientOrbs: View {
  let color: Color
  @State private var phase = false

  var body: some View {
    // Sized off the container rather than fixed points, so the orbs can never
    // be wider than the screen they sit on.
    GeometryReader { proxy in
      let unit = min(proxy.size.width, proxy.size.height)

      ZStack {
        orb(diameter: unit * 0.9, opacity: 0.5, blur: 100)
          .offset(x: phase ? -60 : -100, y: phase ? -200 : -260)
          .scaleEffect(phase ? 1.2 : 0.8)
          .animation(.easeInOut(duration: 8).repeatForever(autoreverses: true), value: phase)

        orb(diameter: unit * 0.7, opacity: 0.35, blur: 85)
          .offset(x: phase ? 110 : 70, y: phase ? -140 : -190)
          .scaleEffect(phase ? 0.85 : 1.15)
          .animation(.easeInOut(duration: 6.5).repeatForever(autoreverses: true), value: phase)

        orb(diameter: unit * 0.5, opacity: 0.25, blur: 70)
          .offset(x: phase ? 20 : -30, y: phase ? 60 : 20)
          .scaleEffect(phase ? 1.1 : 0.88)
          .animation(.easeInOut(duration: 9).repeatForever(autoreverses: true), value: phase)
      }
      .frame(width: proxy.size.width, height: proxy.size.height, alignment: .topLeading)
    }
    .allowsHitTesting(false)
    .onAppear { phase = true }
  }

  private func orb(diameter: CGFloat, opacity: Double, blur: CGFloat) -> some View {
    Circle()
      .fill(color.opacity(opacity))
      .frame(width: diameter, height: diameter)
      .blur(radius: blur)
  }
}

// MARK: - Layout

/// Centred, wrapping row layout for the individual words of a karaoke line.
private struct WrappingWordsLayout: Layout {
  var horizontalSpacing: CGFloat
  var verticalSpacing: CGFloat

  struct Row {
    var items: [(index: Int, x: CGFloat, width: CGFloat)]
    var y: CGFloat
    var width: CGFloat
    var height: CGFloat
  }

  struct Cache {
    var sizes: [CGSize]
    var width: CGFloat = .nan
    var rows: [Row] = []
    var total: CGSize = .zero
  }

  func makeCache(subviews: Subviews) -> Cache {
    Cache(sizes: subviews.map { $0.sizeThatFits(.unspecified) })
  }

  func updateCache(_ cache: inout Cache, subviews: Subviews) {
    cache.sizes = subviews.map { $0.sizeThatFits(.unspecified) }
    cache.width = .nan
  }

  func sizeThatFits(
    proposal: ProposedViewSize,
    subviews: Subviews,
    cache: inout Cache
  ) -> CGSize {
    let width = resolvedWidth(proposal, cache: cache)
    layoutRows(width: width, cache: &cache)
    // Never report more than we were offered. A Layout that returns an
    // oversized width is not clipped by the parent frame — it simply spills
    // out over both edges of the screen.
    return CGSize(width: min(cache.total.width, width), height: cache.total.height)
  }

  func placeSubviews(
    in bounds: CGRect,
    proposal: ProposedViewSize,
    subviews: Subviews,
    cache: inout Cache
  ) {
    // Measure and place agree because both go through layoutRows.
    layoutRows(width: bounds.width, cache: &cache)

    for row in cache.rows {
      let originX = bounds.minX + max(0, (bounds.width - row.width) / 2)

      for item in row.items {
        subviews[item.index].place(
          at: CGPoint(x: originX + item.x, y: bounds.minY + row.y),
          anchor: .topLeading,
          proposal: ProposedViewSize(
            width: item.width,
            height: cache.sizes[item.index].height
          )
        )
      }
    }
  }

  private func resolvedWidth(_ proposal: ProposedViewSize, cache: Cache) -> CGFloat {
    if let width = proposal.width, width.isFinite, width > 0 { return width }
    // An unspecified proposal must not turn into "one row holding every word":
    // that reports a width several times the screen's and drags the whole line
    // off to the side. The widest single word always fits whatever the parent
    // ends up offering.
    return cache.sizes.map(\.width).max() ?? 0
  }

  private func layoutRows(width: CGFloat, cache: inout Cache) {
    // NaN != NaN, so a freshly made or invalidated cache always rebuilds.
    guard cache.width != width else { return }

    var rows: [Row] = []
    var items: [(index: Int, x: CGFloat, width: CGFloat)] = []
    var x: CGFloat = 0
    var y: CGFloat = 0
    var rowHeight: CGFloat = 0
    var widest: CGFloat = 0

    for index in cache.sizes.indices {
      let size = cache.sizes[index]
      // A single word longer than the line gets capped and shrinks to fit
      // (see minimumScaleFactor on the word) instead of overflowing.
      let itemWidth = min(size.width, width)
      let projected = items.isEmpty ? itemWidth : x + horizontalSpacing + itemWidth

      if projected > width, !items.isEmpty {
        rows.append(Row(items: items, y: y, width: x, height: rowHeight))
        widest = max(widest, x)
        y += rowHeight + verticalSpacing
        items = []
        x = 0
        rowHeight = 0
      }

      let itemX = items.isEmpty ? 0 : x + horizontalSpacing
      items.append((index: index, x: itemX, width: itemWidth))
      x = itemX + itemWidth
      rowHeight = max(rowHeight, size.height)
    }

    if !items.isEmpty {
      rows.append(Row(items: items, y: y, width: x, height: rowHeight))
      widest = max(widest, x)
    }

    cache.width = width
    cache.rows = rows
    cache.total = CGSize(width: widest, height: rows.last.map { $0.y + $0.height } ?? 0)
  }
}
