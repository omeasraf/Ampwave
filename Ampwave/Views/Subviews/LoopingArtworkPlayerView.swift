#if os(iOS)
  import AVFoundation
  internal import SwiftUI
  import UIKit

  /// A silent, noninteractive HLS loop for Now Playing artwork. The static
  /// cover remains underneath while the first video frame loads.
  struct LoopingArtworkPlayerView: UIViewRepresentable {
    let url: URL
    let isPlaying: Bool

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> ArtworkPlayerUIView {
      let view = ArtworkPlayerUIView()
      context.coordinator.attach(to: view)
      context.coordinator.configure(url: url, isPlaying: isPlaying)
      return view
    }

    func updateUIView(_ view: ArtworkPlayerUIView, context: Context) {
      context.coordinator.configure(url: url, isPlaying: isPlaying)
    }

    static func dismantleUIView(_ view: ArtworkPlayerUIView, coordinator: Coordinator) {
      coordinator.stop()
    }

    final class Coordinator {
      private let player = AVPlayer()
      private var currentURL: URL?
      private var endObserver: NSObjectProtocol?
      private var statusObserver: NSKeyValueObservation?
      private var shouldPlay = false
      private weak var view: ArtworkPlayerUIView?

      func attach(to view: ArtworkPlayerUIView) {
        self.view = view
        player.isMuted = true
        // This player reads a remote HLS stream, so allow AVFoundation to
        // buffer enough data for a stable first frame.
        player.automaticallyWaitsToMinimizeStalling = true
        view.playerLayer.player = player
      }

      func configure(url: URL, isPlaying: Bool) {
        shouldPlay = isPlaying
        if currentURL != url {
          player.pause()
          removeObservers()
          currentURL = url
          let item = AVPlayerItem(url: url)
          player.replaceCurrentItem(with: item)
          statusObserver = item.observe(\.status, options: [.new]) { [weak self] item, _ in
            Task { @MainActor in
              guard let self else { return }
              switch item.status {
              case .readyToPlay:
                DiagnosticLog.shared.log(
                  "animated-artwork",
                  "OpenPlayer animation ready url=\(url.lastPathComponent)"
                )
                if self.shouldPlay { self.player.play() }
              case .failed:
                DiagnosticLog.shared.log(
                  "animated-artwork",
                  "OpenPlayer animation failed error=\(item.error?.localizedDescription ?? "unknown")"
                )
              default:
                break
              }
            }
          }
          endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: item,
            queue: .main
          ) { [weak self] _ in
            guard let self else { return }
            self.player.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero) { _ in
              if self.shouldPlay { self.player.play() }
            }
          }
        }
        isPlaying ? player.play() : player.pause()
      }

      func stop() {
        player.pause()
        removeObservers()
        player.replaceCurrentItem(with: nil)
        view?.playerLayer.player = nil
      }

      private func removeObservers() {
        statusObserver?.invalidate()
        statusObserver = nil
        if let endObserver {
          NotificationCenter.default.removeObserver(endObserver)
          self.endObserver = nil
        }
      }
    }
  }

  final class ArtworkPlayerUIView: UIView {
    override static var layerClass: AnyClass { AVPlayerLayer.self }
    var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }

    override init(frame: CGRect) {
      super.init(frame: frame)
      isUserInteractionEnabled = false
      backgroundColor = .clear
      playerLayer.backgroundColor = UIColor.clear.cgColor
      playerLayer.videoGravity = .resizeAspectFill
    }

    required init?(coder: NSCoder) {
      fatalError("init(coder:) has not been implemented")
    }
  }
#endif
