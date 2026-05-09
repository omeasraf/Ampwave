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
  @Environment(ThemeManager.self) private var themeManager
  private var playback: PlaybackController { PlaybackController.shared }
  @State private var isHovering = false

  var body: some View {
    GeometryReader { geometry in
      let w = geometry.size.width
      let h = geometry.size.height

      ZStack(alignment: .top) {

        // Lyrics section
        ExpandedLyricsView(isExpanded: .constant(true))
          .frame(maxWidth: .infinity, maxHeight: .infinity)

        if isHovering {
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
          .frame(height: 12)
          .background(themeManager.cardBackgroundColor.opacity(0.6))
        }
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
