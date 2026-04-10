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
    @State private var isProgrammaticScroll = false
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

                                ForEach(
                                    Array(lyrics.lines.enumerated()),
                                    id: \.element.timestamp
                                ) { index, line in
                                    Text(line.text)
                                        .font(
                                            .system(
                                                size: 18,
                                                weight: isCurrentLine(index)
                                                    ? .bold : .semibold
                                            )
                                        )
                                        .foregroundStyle(
                                            isCurrentLine(index)
                                                ? .white : .white.opacity(0.35)
                                        )
                                        .multilineTextAlignment(.center)
                                        .lineSpacing(2)
                                        .padding(.horizontal, 24)
                                        .frame(
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
                                        }
                                        .animation(
                                            .spring(
                                                response: 0.3,
                                                dampingFraction: 0.7
                                            ),
                                            value: playback.currentLyricIndex
                                        )

                                }

                                // Bottom spacer for centering last line
                                Spacer()
                                    .frame(height: 200)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.horizontal, 24)
                        }
                        .id(playback.currentItem?.id)
                        .onChange(of: playback.currentLyricIndex) {
                            _,
                            newIndex in
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
                                    if let currentIndex = playback
                                        .currentLyricIndex
                                    {
                                        isProgrammaticScroll = true
                                        withAnimation(
                                            .easeInOut(duration: 0.35)
                                        ) {
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
                    // Plain text fallback (show even if LRC formatted but not yet parsed)
                    ScrollView(.vertical, showsIndicators: false) {
                        VStack(spacing: 20) {
                            Spacer().frame(height: 100)

                            Text(plainLyrics.cleanedLRC)
                                .font(.system(size: 20, weight: .medium))
                                .foregroundStyle(.white)
                                .multilineTextAlignment(.center)
                                .padding(.horizontal, 24)
                                .lineSpacing(8)
                                .padding(.horizontal, 30)

                            Spacer().frame(height: 100)
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
                        Text("New")
                    }
                }

                //        ToolbarItem(placement: .navigationBarTrailing) {
                //          Button {
                //            Task {
                //              await playback.refreshLyrics()
                //            }
                //          } label: {
                //            Image(systemName: "arrow.clockwise")
                //              .font(.system(size: 18))
                //              .foregroundStyle(.white)
                //          }
                //        }
            }
            .preferredColorScheme(.dark)
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
            line.trimmingCharacters(in: .whitespaces).firstMatch(of: lrcPattern)
                != nil
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
                                    .fixedSize(
                                        horizontal: false,
                                        vertical: true
                                    )
                                    .padding(.horizontal, 12)
                                    .frame(maxWidth: .infinity)
                                    .scaleEffect(
                                        isCurrentLine(index) ? 1.08 : 1.0,
                                        anchor: .center
                                    )
                                    .id(index)
                                    .onTapGesture {
                                        playback.seek(to: line.timestamp)
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
                            Spacer()
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
                                if let currentIndex = playback.currentLyricIndex
                                {
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
                        Spacer().frame(height: 40)
                        Text(plainLyrics.cleanedLRC)
                            .font(.system(size: 15, weight: .medium))
                            .foregroundStyle(.primary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 20)
                        Spacer().frame(height: 40)
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
