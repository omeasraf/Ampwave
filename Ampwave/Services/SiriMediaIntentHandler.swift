//
//  SiriMediaIntentHandler.swift
//  Ampwave
//
//  Handles Siri's system-level media request ("Play … on Ampwave"). App
//  Shortcuts cover explicit shortcut phrases, but native media requests arrive
//  as INPlayMediaIntent and must be dispatched through UIApplicationDelegate.
//

#if os(iOS)
  import Intents
  import UIKit

  final class AmpwaveApplicationDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, handlerFor intent: INIntent) -> Any? {
      guard intent is INPlayMediaIntent else { return nil }
      DiagnosticLog.shared.log("siri", "Dispatching native INPlayMediaIntent")
      return SiriMediaIntentHandler()
    }
  }

  final class SiriMediaIntentHandler: NSObject, INPlayMediaIntentHandling {
    func confirm(
      intent: INPlayMediaIntent,
      completion: @escaping (INPlayMediaIntentResponse) -> Void
    ) {
      completion(INPlayMediaIntentResponse(code: .ready, userActivity: nil))
    }

    func handle(
      intent: INPlayMediaIntent,
      completion: @escaping (INPlayMediaIntentResponse) -> Void
    ) {
      Task { @MainActor in
        await SiriIntentEnvironment.prepareLibrary(includePlaylists: true, includePlayback: true)

        if intent.resumePlayback == true, Self.requestedTitle(from: intent) == nil {
          let playback = PlaybackController.shared
          playback.restoreStateAfterLoading()
          playback.play()
          completion(INPlayMediaIntentResponse(code: .success, userActivity: nil))
          return
        }

        guard let title = Self.requestedTitle(from: intent) else {
          DiagnosticLog.shared.log("siri", "Native media intent did not contain a title")
          completion(INPlayMediaIntentResponse(code: .failureUnknownMediaType, userActivity: nil))
          return
        }

        let artist = intent.mediaItems?.first?.artist ?? intent.mediaSearch?.artistName
        do {
          let result = try await SiriPlaybackRouter.shared.playSong(
            songTitle: title,
            artistName: artist
          )
          DiagnosticLog.shared.log(
            "siri",
            "Native media intent played \(result.matchedTitle) via \(result.source.rawValue)"
          )
          completion(INPlayMediaIntentResponse(code: .success, userActivity: nil))
          return
        } catch {
          DiagnosticLog.shared.log(
            "siri",
            "Direct song resolution failed for \(title); trying library search: \(error)"
          )
        }

        let results = await SearchManager.shared.search(query: title, filter: .all)
        let playback = PlaybackController.shared

        if let song = results.topSong {
          playback.play(song, from: .search)
        } else if let artist = results.artists.first {
          playback.playArtist(artist.name)
        } else if let album = results.albums.first {
          playback.playAlbum(album)
        } else if let playlist = results.playlists.first {
          playback.playPlaylist(playlist)
        } else {
          DiagnosticLog.shared.log("siri", "No playable result for native media query: \(title)")
          completion(INPlayMediaIntentResponse(code: .failure, userActivity: nil))
          return
        }

        completion(INPlayMediaIntentResponse(code: .success, userActivity: nil))
      }
    }

    private static func requestedTitle(from intent: INPlayMediaIntent) -> String? {
      let candidates = [
        intent.mediaItems?.first?.title,
        intent.mediaSearch?.mediaName,
        intent.mediaSearch?.albumName,
        intent.mediaContainer?.title,
      ]

      return candidates
        .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
        .first { !$0.isEmpty }
    }
  }
#endif
