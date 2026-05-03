//
//  AmpwaveURLRouter.swift
//  Ampwave
//

import Foundation

@MainActor
enum AmpwaveURLRouter {
  static func handle(_ url: URL) {
    guard url.scheme?.lowercased() == "ampwave" else { return }
    let host = url.host ?? ""
    let path = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    let route = path.isEmpty ? host : "\(host)/\(path)"

    let playback = PlaybackController.shared
    let pm = PlaylistManager.shared

    switch route.lowercased() {
    case "play/liked", "liked":
      if let liked = pm.likedSongsPlaylist, !liked.songs.isEmpty {
        playback.playPlaylist(liked)
      }
    case "resume":
      if playback.currentItem != nil {
        playback.play()
      } else {
        playback.restoreStateAfterLoading()
        playback.play()
      }
    default:
      break
    }
  }
}
