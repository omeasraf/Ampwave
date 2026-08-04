//
//  FullScreenPlayerView.swift
//  Ampwave
//

import AVFoundation
import SwiftData
internal import SwiftUI

#if os(iOS)
  import UIKit
#else
  import AppKit
#endif

struct OpenPlayerView: View {
  @Environment(\.dismiss) private var dismiss
  @Environment(ThemeManager.self) private var themeManager
  @Environment(SleepTimerService.self) private var sleepTimer
  @State private var showingQueue = false
  @State private var isLyricsExpanded = false
  @State private var showingAddToPlaylist = false
  @State private var isEditingShown = false
  @State private var showingTechnicalInfo = false
  @State private var showingEqualizer = false
  @State private var showingSleepTimerOptions = false
  @State private var artworkColor: Color = .clear
  @State private var rawArtworkColor: Color = .clear
  /// Measured height of the whole controls block (track info through the
  /// utility row). The artwork is sized around this so the bottom row is never
  /// pushed below the fold, whatever the device or text size.
  @State private var controlsHeight: CGFloat = 0
  #if os(iOS)
    @State private var isAirPlayActive = false
  #endif

  private var playback: PlaybackController { PlaybackController.shared }
  private var playlistManager: PlaylistManager { PlaylistManager.shared }

  private var availablePlaylists: [Playlist] {
    playlistManager.playlists.filter { $0.playlistType != .likedSongs }
  }

  @Query private var preferencesList: [UserPreferences]
  private var userPreferences: UserPreferences? { preferencesList.first }

  init() {}

  var body: some View {
    NavigationStack {
      ZStack {
        let fullBackground = userPreferences?.fullArtworkBackground ?? true
        // playerBackground (the accent gradient) is only shown when Full Artwork
        // Background is enabled. When it's off, the accent tint is applied only
        // to the ScrollView background below, keeping the nav-bar area clean.
        if fullBackground {
          playerBackground
        } else {
          themeManager.backgroundColor
            .ignoresSafeArea()
        }

        GeometryReader { geometry in
          let availableHeight = geometry.size.height
          let isFullBackground = userPreferences?.fullArtworkBackground ?? true
          // The scroll view draws under the home indicator, so the first page
          // has to cover the safe-area inset too — sizing it to
          // `geometry.size.height` alone left a sliver of the lyrics section
          // peeking up from the bottom.
          let pageHeight = availableHeight + geometry.safeAreaInsets.bottom
          // The artwork gives up whatever height the controls actually need,
          // rather than always claiming 62%. On shorter screens — or with
          // larger text — a fixed share pushed the utility row off the bottom
          // of the first screenful. Floored so the artwork never collapses.
          let artworkHeight = max(
            pageHeight * 0.3,
            min(pageHeight * 0.62, pageHeight - controlsHeight)
          )

          ScrollView(showsIndicators: false) {
              VStack(spacing: 0) {
                  // ── First page: fills exactly the viewport ──
                  VStack(spacing: 0) {
                      if isFullBackground {
                          // Taller artwork for full background mode
                          let accentOn = userPreferences?.coverArtAccentPlayer ?? false
                          FullArtworkBackgroundView(artworkPath: playback.currentItem?.effectiveArtworkPath)
                              .frame(height: artworkHeight)
                              .overlay {
                                  // Primary fade:" artwork → theme background
                                  LinearGradient(
                                    stops: [
                                        .init(color: .clear, location: 0),
                                        .init(color: .clear, location: 0.6),
                                        .init(color: themeManager.backgroundColor.opacity(0.8), location: 0.85),
                                        .init(color: themeManager.backgroundColor, location: 1.0),
                                    ],
                                    startPoint: .top,
                                    endPoint: .bottom
                                  )
                              }
                              .overlay {
                                  // Accent tint layer: blends the bottom of the artwork
                                  // into the same tinted color used for the scroll background.
                                  if accentOn {
                                      LinearGradient(
                                        stops: [
                                            .init(color: .clear, location: 0),
                                            .init(color: rawArtworkColor.opacity(0.10), location: 0.65),
                                            .init(color: rawArtworkColor.opacity(0.18), location: 1.0),
                                        ],
                                        startPoint: .top,
                                        endPoint: .bottom
                                      )
                                  }
                              }
                      } else {
                          // Artwork same width as glass card
                          let accentOn = userPreferences?.coverArtAccentPlayer ?? false
                          LargeArtworkImageView(
                            artworkPath: playback.currentItem?.effectiveArtworkPath,
                            shadowColor: accentOn
                              ? rawArtworkColor.opacity(0.55)
                              : .black.opacity(0.15),
                            shadowRadius: accentOn ? 32 : 20
                          )
                          .padding(.top, 10)
                          .padding(.bottom, 10)
                          .padding(.horizontal, 16)
                          // Same reasoning as the full-bleed branch: the cover
                          // shrinks before the controls get clipped.
                          .frame(maxHeight: artworkHeight)
                      }
                      
                      Spacer(minLength: 0)
                      
                      VStack(spacing: isFullBackground ? 24 : 22) {
                          trackInfoSection
                          
                          PlayerProgressView()
                          
                          PlayerPlaybackControlsView()
                          
                          extraControls
                      }
                      .padding(.top, isFullBackground ? 24 : 16)
                      // Asymmetric on purpose: the utility row should sit close
                      // to the bottom edge rather than floating above a band of
                      // empty card.
                      .padding(.bottom, isFullBackground ? 8 : 6)
                      .padding(.horizontal, (userPreferences?.openPlayerGlassBackground ?? true) ? 24 : 12)
                      .background(
                        Group {
                            if !(userPreferences?.openPlayerGlassBackground ?? true) {
                                Color.clear
                            } else {
                                RoundedRectangle(cornerRadius: 32, style: .continuous)
                                    .fill(themeManager.cardBackgroundColor)
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 32, style: .continuous)
                                            .fill(coverArtCardTint)
                                    )
                                    .shadow(
                                        color: coverArtCardTint.opacity(0.6),
                                        radius: (userPreferences?.coverArtAccentPlayer ?? false) ? 20 : 0,
                                        x: 0, y: 4
                                    )
                            }
                        }
                      )
                      .padding(.horizontal, (userPreferences?.openPlayerGlassBackground ?? true) ? 16 : 8)
                      // Clear the home indicator: the page now extends under it.
                      .padding(.bottom, 10 + geometry.safeAreaInsets.bottom)
                      .onGeometryChange(for: CGFloat.self) { proxy in
                        proxy.size.height
                      } action: { height in
                        controlsHeight = height
                      }
                  }
                  .frame(minHeight: pageHeight)
                  
                  // ── Lyrics section: only visible on scroll ──
                  tabSection
                      .padding(.horizontal, (userPreferences?.openPlayerGlassBackground ?? true) ? 16 : 8)
                      .padding(.bottom, 24)
              }
          }
          .background {
            let accentOn = userPreferences?.coverArtAccentPlayer ?? false
            themeManager.backgroundColor
            if accentOn {
              rawArtworkColor.opacity(0.18)
            }
          }
          // Hiding the toolbar background isn't enough on its own: content
          // scrolling under the bar still gets the system's scroll edge
          // effect, which paints a blurred/tinted band over the artwork and
          // reads as a solid nav-bar background.
          #if os(iOS)
            .scrollEdgeEffectHidden(true, for: .top)
          #endif
        }
        .ignoresSafeArea(edges: (userPreferences?.fullArtworkBackground ?? true) ? .top : [])
      }
      // Swipe down anywhere to dismiss — works simultaneously with the scroll gesture
      .simultaneousGesture(
        DragGesture(minimumDistance: 30, coordinateSpace: .global)
          .onEnded { value in
            guard value.translation.height > 80,
              value.translation.height > abs(value.translation.width) else { return }
            dismiss()
          }
      )
      .navigationTitle("Now Playing")
      #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
      #endif
      // Something inside the player asked to navigate out of it.
      .onChange(of: AppNavigator.shared.shouldCollapsePlayer) { _, shouldCollapse in
        guard shouldCollapse else { return }
        dismiss()
      }
      .onDisappear {
        // Push only after the cover is gone; doing it mid-transition drops
        // the navigation.
        if AppNavigator.shared.shouldCollapsePlayer {
          AppNavigator.shared.playerDidCollapse()
        }
      }
      .toolbar {
        ToolbarItem(placement: .navigation) {
          Button {
            dismiss()
          } label: {
            Image(systemName: "chevron.down")
              .font(.system(size: 18, weight: .semibold))
              .shadow(radius: 2)
          }
        }

        ToolbarItem(placement: .primaryAction) {
          Menu {
            Button {
              isEditingShown = true
            } label: {
              Label("Edit Song", systemImage: "pencil")
            }

            Button {
              showingAddToPlaylist = true
            } label: {
              Label(
                "Add to Playlist",
                systemImage: "text.badge.plus"
              )
            }

            if let song = playback.currentItem {
              Button {
                _ = playlistManager.toggleLike(song: song)
              } label: {
                Label(
                  playlistManager.isLiked(song: song) ? "Remove from Favorites" : "Add to Favorites",
                  systemImage: playlistManager.isLiked(song: song) ? "heart.slash" : "heart"
                )
              }

              Button {
                _ = playlistManager.toggleDisliked(song: song)
              } label: {
                Label(
                  playlistManager.isDisliked(song: song) ? "Clear Dislike" : "Dislike Song",
                  systemImage: playlistManager.isDisliked(song: song) ? "hand.thumbsdown.slash" : "hand.thumbsdown"
                )
              }

              Menu {
                Button("Clear Rating") {
                  ListeningHistoryTracker.shared.setRating(nil, for: song)
                }
                ForEach(1...5, id: \.self) { rating in
                  Button(String(repeating: "★", count: rating)) {
                    ListeningHistoryTracker.shared.setRating(rating, for: song)
                  }
                }
              } label: {
                let currentRating = ListeningHistoryTracker.shared.rating(for: song) ?? 0
                Label(
                  currentRating > 0 ? "Rating: \(currentRating)/5" : "Rate Song",
                  systemImage: "star"
                )
              }
            }
          } label: {
            Image(systemName: "ellipsis")
              .font(.system(size: 18, weight: .semibold))
              .shadow(radius: 2)
          }
        }
      }
      #if os(iOS)
        .toolbarBackgroundVisibility(.hidden, for: .navigationBar)
      #endif
      .confirmationDialog(
        "Add Song to Playlist",
        isPresented: $showingAddToPlaylist
      ) {
        ForEach(availablePlaylists) { playlist in
          Button(playlist.name) {
            if let song = playback.currentItem {
              playlistManager.addSong(song, to: playlist)
            }
          }
        }
      } message: {
        if availablePlaylists.isEmpty {
          Text("Create a playlist first from the Library tab.")
        } else {
          Text("Choose a playlist for this song.")
        }
      }
      .confirmationDialog(
        "Sleep Timer",
        isPresented: $showingSleepTimerOptions,
        titleVisibility: .visible
      ) {
        Button("15 Minutes") {
          sleepTimer.startCountdown(minutes: 15)
        }
        Button("30 Minutes") {
          sleepTimer.startCountdown(minutes: 30)
        }
        Button("45 Minutes") {
          sleepTimer.startCountdown(minutes: 45)
        }
        Button("1 Hour") {
          sleepTimer.startCountdown(minutes: 60)
        }
        Button("End of Current Song") {
          sleepTimer.startEndOfSong()
        }
        Button("End of Queue") {
          sleepTimer.startEndOfQueue()
        }
        if sleepTimer.isActive {
          Button("Turn Off Timer", role: .destructive) {
            sleepTimer.cancel()
          }
        }
        Button("Cancel", role: .cancel) {}
      } message: {
        Text(sleepTimer.isActive ? sleepTimer.statusText : "Choose when playback should stop.")
      }
    }
    #if os(iOS)
      .fullScreenCover(isPresented: $isLyricsExpanded) {
        ExpandedLyricsView(isExpanded: $isLyricsExpanded)
      }
    #else
      .sheet(isPresented: $isLyricsExpanded) {
        ExpandedLyricsView(isExpanded: $isLyricsExpanded)
      }
    #endif
    .sheet(isPresented: $isEditingShown) {
      if let song = playback.currentItem {
        SongEditSheet(song: song, isPresented: $isEditingShown)
      }
    }
    .task(id: playback.currentItem?.id) {
      await updateArtworkColor()
    }
    .onAppear {
      updateIdleTimerState()
      #if os(iOS)
        checkAirPlayRoute()
      #endif
    }
    .onChange(of: playback.currentItem?.id) { _, _ in
      updateIdleTimerState()
    }
    .onChange(of: playback.isPlaying) { _, _ in
      updateIdleTimerState()
    }
    .onDisappear {
      #if os(iOS)
        UIApplication.shared.isIdleTimerDisabled = false
      #endif
    }
    #if os(iOS)
      .onReceive(
        NotificationCenter.default.publisher(for: AVAudioSession.routeChangeNotification)
      ) { _ in
        checkAirPlayRoute()
      }
    #endif
  }

  private var playerBackground: some View {
    let coverArtAccent = userPreferences?.coverArtAccentPlayer ?? false
    let isFullBackground = userPreferences?.fullArtworkBackground ?? true

    // When fullArtworkBackground is OFF, the top of the screen (navigation bar
    // area) must NOT receive any artwork-derived tint — only the accent card and
    // scroll body below carry the accent color.
    let topColor: Color
    let midColor: Color
    let bottomColor: Color

    if isFullBackground {
      topColor = coverArtAccent ? rawArtworkColor.opacity(0.75) : artworkColor.opacity(0.95)
      midColor = coverArtAccent ? rawArtworkColor.opacity(0.30) : themeManager.backgroundColor
      bottomColor = coverArtAccent ? rawArtworkColor.opacity(0.18) : themeManager.backgroundColor.opacity(0.96)
    } else {
      // fullArtworkBackground OFF: top bar is always the plain theme background.
      // coverArtAccent only affects the card tint and scroll body (handled in the
      // ScrollView .background modifier), not the navigation bar region.
      topColor = themeManager.backgroundColor
      midColor = themeManager.backgroundColor
      bottomColor = coverArtAccent ? rawArtworkColor.opacity(0.18) : themeManager.backgroundColor
    }

    return ZStack {
      themeManager.backgroundColor.ignoresSafeArea()
      LinearGradient(
        colors: [topColor, midColor, bottomColor],
        startPoint: .top,
        endPoint: .bottom
      )
      .ignoresSafeArea()
    }
  }

  private var coverArtCardTint: Color {
    (userPreferences?.coverArtAccentPlayer ?? false)
      ? rawArtworkColor.opacity(0.12)
      : .clear
  }

  private var trackInfoSection: some View {
    VStack(alignment: .leading, spacing: 14) {
      HStack {
        VStack(alignment: .leading, spacing: 6) {
          MarqueeText(
            text: playback.currentItem?.title ?? "Not Playing",
            font: .system(size: 28, weight: .bold, design: .rounded),
            color: .primary
          )

          if let song = playback.currentItem,
            let artist = SongLibrary.shared.getArtist(named: song.artist)
          {
            // Collapses the player first rather than pushing inside its own
            // cover, which would hide the player and mini player with no way
            // back to playback.
            Button {
              AppNavigator.shared.show(.artist(artist), collapsingPlayer: true)
            } label: {
              Text(song.artist)
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }
            .buttonStyle(.plain)
          } else {
            Text(playback.currentItem?.artist ?? "")
              .font(.system(size: 18, weight: .medium))
              .foregroundStyle(.secondary)
              .lineLimit(1)
          }

          if let song = playback.currentItem {
            technicalBadge(for: song)
          }
        }

        Spacer()

        if let song = playback.currentItem {
          HStack(spacing: 10) {
            Button {
              HapticManager.shared.dislike()
              _ = PlaylistManager.shared.toggleDisliked(song: song)
            } label: {
              Image(
                systemName: PlaylistManager.shared.isDisliked(song: song)
                  ? "hand.thumbsdown.fill" : "hand.thumbsdown"
              )
              .font(.system(size: 20))
              .foregroundStyle(
                PlaylistManager.shared.isDisliked(song: song)
                  ? .red : .primary
              )
              .frame(width: 42, height: 42)
              .glassEffect(
                themeManager.coloredSurfaces ? .regular.interactive() : .identity,
                in: Circle()
              )
            }
            .contentTransition(.symbolEffect(.replace))

            Button {
              HapticManager.shared.like()
              PlaylistManager.shared.toggleLike(song: song)
            } label: {
              Image(
                systemName: PlaylistManager.shared.isLiked(
                  song: song
                ) ? "heart.fill" : "heart"
              )
              .font(.system(size: 24))
              .foregroundStyle(
                PlaylistManager.shared.isLiked(song: song)
                  ? themeManager.accentColor : .primary
              )
              .frame(width: 46, height: 46)
              .glassEffect(
                themeManager.coloredSurfaces ? .regular.interactive() : .identity,
                in: Circle()
              )
            }
            .contentTransition(.symbolEffect(.replace))
          }
        }
      }
    }
  }

  private func technicalBadge(for song: LibrarySong) -> some View {
    Button {
      showingTechnicalInfo = true
    } label: {
      HStack(spacing: 4) {
        if let format = song.format {
          Text(format)
            .font(.system(size: 10, weight: .bold))
            .padding(.horizontal, 4)
            .padding(.vertical, 2)
            .background(.secondary.opacity(0.2))
            .cornerRadius(4)
        }

        if let sampleRate = song.sampleRate {
          Text(formatSampleRate(sampleRate))
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(.secondary)
        }

        if let bitDepth = song.bitDepth, bitDepth > 0 {
          Text("\(bitDepth)bit")
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(.secondary)
        }
      }
    }
    .buttonStyle(.plain)
    .sheet(isPresented: $showingTechnicalInfo) {
      TechnicalInfoSheet(song: song)
    }
  }

  private func formatSampleRate(_ rate: Double) -> String {
    if rate >= 1000 {
      return String(format: "%.1f kHz", rate / 1000)
    } else {
      return String(format: "%.0f Hz", rate)
    }
  }

  private var extraControls: some View {
    VStack(spacing: 10) {
      HStack(spacing: 0) {
        playerUtilityButton(
          icon: "text.quote",
          isActive: isLyricsExpanded
        ) {
          isLyricsExpanded = true
        }

        playerUtilityButton(
          icon: "shuffle",
          isActive: playback.shuffleMode != .off
        ) {
          playback.toggleShuffle()
        }

        playerUtilityButton(
          icon: repeatIcon,
          isActive: playback.repeatMode != .off
        ) {
          playback.cycleRepeatMode()
        }

        playerUtilityButton(
          icon: "moon.zzz",
          isActive: sleepTimer.isActive
        ) {
          showingSleepTimerOptions = true
        }

        playerUtilityButton(icon: "list.bullet", isActive: false) {
          showingQueue = true
        }
        .sheet(isPresented: $showingQueue) {
          QueueSheetView()
        }

        playerUtilityButton(
          icon: "slider.horizontal.3",
          isActive: EQManager.shared.isEnabled
        ) {
          showingEqualizer = true
        }
        .sheet(isPresented: $showingEqualizer) {
          EqualizerSheet()
        }

        #if os(iOS)
          airPlayUtilityButton
        #endif
      }

      if sleepTimer.isActive {
        Text(sleepTimer.statusText)
          .font(.system(size: 12, weight: .medium))
          .foregroundStyle(themeManager.accentColor)
          .frame(maxWidth: .infinity, alignment: .center)
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
    playback.repeatMode == .off ? .secondary : themeManager.accentColor
  }

  private var tabSection: some View {
    let accentOn = userPreferences?.coverArtAccentPlayer ?? false
    let lyricsColor = accentOn ? rawArtworkColor.opacity(0.22) : artworkColor
    return VStack(spacing: 16) {
      CompactLyricsView(
        artworkColor: lyricsColor,
        onExpand: {
          isLyricsExpanded = true
        }
      ).padding(.top, 15)
    }
  }

  private func playerUtilityButton(
    icon: String,
    isActive: Bool,
    action: @escaping () -> Void
  ) -> some View {
    Button {
      HapticManager.shared.select()
      action()
    } label: {
      Image(systemName: icon)
        .font(.system(size: 18, weight: .semibold))
        .foregroundStyle(isActive ? themeManager.accentColor : .primary)
        .frame(width: 36, height: 36)
        .glassEffect(
          themeManager.coloredSurfaces ? .regular.interactive() : .identity,
          in: Circle()
        )
        .frame(maxWidth: .infinity)
        .frame(height: 50)
    }
    .buttonStyle(.plain)
  }

  #if os(iOS)
    @ViewBuilder
    private var airPlayUtilityButton: some View {
      let tint: UIColor = isAirPlayActive ? UIColor(themeManager.accentColor) : .label
      AirPlayButton(tintColor: tint)
        .frame(width: 36, height: 36)
        .glassEffect(
          themeManager.coloredSurfaces ? .regular.interactive() : .identity,
          in: Circle()
        )
        .frame(maxWidth: .infinity)
        .frame(height: 50)
    }

    private func checkAirPlayRoute() {
      let outputs = AVAudioSession.sharedInstance().currentRoute.outputs
      let externalPortTypes: [AVAudioSession.Port] = [
        .airPlay, .bluetoothA2DP, .bluetoothLE, .bluetoothHFP,
        .carAudio, .HDMI, .displayPort,
      ]
      isAirPlayActive = outputs.contains { externalPortTypes.contains($0.portType) }
    }
  #endif

  private func updateArtworkColor() async {
    guard let path = playback.currentItem?.effectiveArtworkPath,
      let url = PathManager.resolve(path)
    else {
      artworkColor = .clear
      rawArtworkColor = .clear
      return
    }

    let colors = await Task.detached(priority: .userInitiated) { () -> (Color, Color) in
      #if os(iOS)
        if let image = UIImage(contentsOfFile: url.path),
           let dominant = image.dominantColor() {
          return (dominant.opacity(0.3), dominant)
        }
      #else
        if let image = NSImage(contentsOfFile: url.path),
           let dominant = image.dominantColor() {
          return (dominant.opacity(0.3), dominant)
        }
      #endif
      return (.clear, .clear)
    }.value

    await MainActor.run {
      withAnimation(.easeInOut) {
        artworkColor = colors.0
        rawArtworkColor = colors.1
      }
    }
  }

  private func updateIdleTimerState() {
    #if os(iOS)
      UIApplication.shared.isIdleTimerDisabled =
        playback.currentItem != nil && playback.isPlaying
    #endif
  }
}

// MARK: - Optimization Components (Same UI, better performance)

private struct PlayerProgressView: View {
  private var playback: PlaybackController { PlaybackController.shared }

  var body: some View {
    let duration = playback.duration
    let progress = duration > 0 ? min(max(playback.currentTime / duration, 0), 1) : 0.0

    VStack(spacing: 8) {
      Slider(
        value: Binding(
          get: { progress },
          set: { newValue in
            playback.seek(to: newValue * duration)
          }
        ),
        in: 0...1,
        onEditingChanged: { scrubbing in
          playback.isScrubbing = scrubbing
          if !scrubbing {
            // Force a final seek to sync player state when scrubbing ends
            playback.seek(to: playback.currentTime)
          }
        }
      )
      .tint(.primary)
      .padding(.top, 2)

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

  private func formatTime(_ seconds: TimeInterval) -> String {
    let s = Int(seconds)
    let m = s / 60
    let sec = s % 60
    return String(format: "%d:%02d", m, sec)
  }
}

private struct PlayerPlaybackControlsView: View {
  private var playback: PlaybackController { PlaybackController.shared }
  @Environment(ThemeManager.self) private var themeManager

  var body: some View {
    HStack(spacing: 44) {
      Button {
        HapticManager.shared.skip()
        playback.playPrevious()
      } label: {
        Image(systemName: "backward.fill")
          .font(.system(size: 28))
          .frame(width: 52, height: 52)
          .glassEffect(
            themeManager.coloredSurfaces ? .regular.interactive() : .identity,
            in: Circle()
          )
      }

      Button {
        HapticManager.shared.playPause()
        playback.playPause()
      } label: {
        Image(
          systemName: playback.isPlaying
            ? "pause.circle.fill" : "play.circle.fill"
        )
        .font(.system(size: 72))
      }
      .foregroundStyle(.primary)
      .contentTransition(.symbolEffect(.replace))

      Button {
        HapticManager.shared.skip()
        playback.playNext()
      } label: {
        Image(systemName: "forward.fill")
          .font(.system(size: 28))
          .frame(width: 52, height: 52)
          .glassEffect(
            themeManager.coloredSurfaces ? .regular.interactive() : .identity,
            in: Circle()
          )
      }
    }
  }
}

struct TechnicalInfoSheet: View {
  let song: LibrarySong
  @Environment(\.dismiss) private var dismiss
  @Environment(ThemeManager.self) private var themeManager

  var body: some View {
    NavigationStack {
      List {
        Section("File Information") {
          InfoRow(label: "Format", value: song.format ?? "Unknown")
          if let sampleRate = song.sampleRate {
            InfoRow(
              label: "Sample Rate",
              value: formatSampleRate(sampleRate)
            )
          }
          if let bitDepth = song.bitDepth, bitDepth > 0 {
            InfoRow(label: "Bit Depth", value: "\(bitDepth) bit")
          }
          if let bitRate = song.bitRate {
            InfoRow(label: "Bit Rate", value: "\(bitRate) kbps")
          }
          if let channels = song.channels {
            InfoRow(
              label: "Channels",
              value: channels == 2
                ? "Stereo"
                : (channels == 1 ? "Mono" : "\(channels)")
            )
          }
          InfoRow(
            label: "File Size",
            value: ByteCountFormatter.string(
              fromByteCount: Int64(song.size),
              countStyle: .file
            )
          )
        }
        .listRowBackground(themeManager.cardBackgroundColor)

        Section("Playback Details") {
          InfoRow(
            label: "Source",
            value: song.source ?? "Local Storage"
          )
          InfoRow(
            label: "Output",
            value: song.output ?? "System Default"
          )
          InfoRow(label: "Mode", value: song.mode ?? "Direct")
          InfoRow(
            label: "Processing",
            value: song.processingChain ?? "None"
          )
        }
        .listRowBackground(themeManager.cardBackgroundColor)

        Section("Location") {
          Text(song.fileName)
            .font(.system(size: 12, design: .monospaced))
            .foregroundStyle(.secondary)
        }
        .listRowBackground(themeManager.cardBackgroundColor)
      }
      .navigationTitle("Song Info")
      #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
      #endif
      .toolbar {
        ToolbarItem(placement: .confirmationAction) {
          Button("Done") { dismiss() }
        }
      }
    }
    .presentationDetents([.medium, .large])
  }

  private func formatSampleRate(_ rate: Double) -> String {
    if rate >= 1000 {
      return String(format: "%.1f kHz", rate / 1000)
    } else {
      return String(format: "%.0f Hz", rate)
    }
  }
}
