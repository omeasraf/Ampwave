//
//  MacOSLyricsWindowView.swift
//  Ampwave
//
//  A floating, utility-style window for displaying lyrics on macOS.
//  Fully responsive layout that scales with window size.
//

internal import SwiftUI

struct MacOSLyricsWindowView: View {
  @Environment(\.dismiss) private var dismiss
  private var playback: PlaybackController { PlaybackController.shared }
  @State private var isHovering = false

  var body: some View {
    GeometryReader { geometry in
      let w = geometry.size.width
      let h = geometry.size.height

      ZStack(alignment: .top) {
        // Background
        Rectangle()
          .fill(.ultraThinMaterial)
          .ignoresSafeArea()

        // Main Content
        VStack(spacing: 0) {
          // Constant Spacer for the custom title bar (which is 28pt high)
          Color.clear.frame(height: 28)

          // Song Info Header - Only shown on hover
          if let item = playback.currentItem, isHovering {
            HStack(spacing: w * 0.03) {
              FixedArtworkThumbnail(artworkPath: item.artworkPath, size: max(32, w * 0.12))
                .cornerRadius(6)

              VStack(alignment: .leading, spacing: 2) {
                Text(item.title)
                  .font(.system(size: max(12, w * 0.04), weight: .bold))
                  .lineLimit(1)
                  .minimumScaleFactor(0.7)
                Text(item.artist)
                  .font(.system(size: max(10, w * 0.035)))
                  .foregroundStyle(.secondary)
                  .lineLimit(1)
                  .minimumScaleFactor(0.7)
              }
              Spacer()
            }
            .padding(.horizontal, max(12, w * 0.04))
            .padding(.vertical, max(8, h * 0.02))
            .background(Color.primary.opacity(0.03))
            .transition(.move(edge: .top).combined(with: .opacity))
            .id(item.id)
          }

          // Lyrics section
          ExpandedLyricsView(isExpanded: .constant(true))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }

        // Custom PiP Title Bar
        HStack {
          Button {
            dismiss()
          } label: {
            Image(systemName: "xmark.circle.fill")
              .font(.system(size: max(14, w * 0.045)))
              .foregroundStyle(.secondary)
          }
          .buttonStyle(.plain)
          .padding(.leading, 8)

          Spacer()

          if let item = playback.currentItem {
            Text(item.title)
              .font(.system(size: max(9, w * 0.025), weight: .medium))
              .foregroundStyle(.secondary)
              .lineLimit(1)
              .minimumScaleFactor(0.6)
              .padding(.horizontal, 4)
          }

          Spacer()

          // Placeholder to balance the close button
          Color.clear.frame(width: max(20, w * 0.06))
        }
        .frame(height: 28)
        .background(Color.black.opacity(0.1))
        .opacity(isHovering ? 1 : 0)
      }
    }
    .animation(.spring(response: 0.3, dampingFraction: 0.8), value: isHovering)
    .onHover { hovering in
      isHovering = hovering
    }
    #if os(macOS)
      .onAppear {
        setupWindow()
      }
    #endif
  }

  #if os(macOS)
    private func setupWindow() {
      DispatchQueue.main.async {
        if let window = NSApplication.shared.windows.first(where: {
          $0.isVisible && $0.title == "Lyrics"
        }) ?? NSApplication.shared.windows.last {
          window.level = .floating
          window.isMovableByWindowBackground = true

          window.standardWindowButton(.closeButton)?.isHidden = true
          window.standardWindowButton(.miniaturizeButton)?.isHidden = true
          window.standardWindowButton(.zoomButton)?.isHidden = true

          window.titlebarAppearsTransparent = true
          window.titleVisibility = .hidden
        }
      }
    }
  #endif
}

#Preview {
  MacOSLyricsWindowView()
}
