//
//  SharedPlaybackInfo.swift
//  Ampwave
//

import Foundation

public struct SharedPlaybackInfo: Codable {
  public var songId: UUID?
  public var title: String
  public var artist: String
  public var album: String?
  /// Relative artwork path (app copies a JPEG into the app group for widgets when possible).
  public var artworkRelativePath: String?
  /// Resized artwork embedded as a fallback so WidgetKit is not dependent on
  /// the lifetime or file-protection state of a separate shared file.
  public var artworkData: Data?
  /// Small artwork previews for the next songs in the active queue.
  public var upcomingArtworkData: [Data]?
  public var themeBackgroundHex: String?
  public var themeAccentHex: String?
  public var themePrimaryTextHex: String?
  public var themeSecondaryTextHex: String?
  public var themeIsDark: Bool?
  public var isPlaying: Bool
  public var currentTime: TimeInterval
  public var duration: TimeInterval
  public var lastUpdated: Date
  public var lyrics: [LyricLine]?

  public init(
    songId: UUID? = nil,
    title: String = "Not Playing",
    artist: String = "No Artist",
    album: String? = nil,
    artworkRelativePath: String? = nil,
    artworkData: Data? = nil,
    upcomingArtworkData: [Data]? = nil,
    themeBackgroundHex: String? = nil,
    themeAccentHex: String? = nil,
    themePrimaryTextHex: String? = nil,
    themeSecondaryTextHex: String? = nil,
    themeIsDark: Bool? = nil,
    isPlaying: Bool = false,
    currentTime: TimeInterval = 0,
    duration: TimeInterval = 0,
    lastUpdated: Date = Date(),
    lyrics: [LyricLine]? = nil
  ) {
    self.songId = songId
    self.title = title
    self.artist = artist
    self.album = album
    self.artworkRelativePath = artworkRelativePath
    self.artworkData = artworkData
    self.upcomingArtworkData = upcomingArtworkData
    self.themeBackgroundHex = themeBackgroundHex
    self.themeAccentHex = themeAccentHex
    self.themePrimaryTextHex = themePrimaryTextHex
    self.themeSecondaryTextHex = themeSecondaryTextHex
    self.themeIsDark = themeIsDark
    self.isPlaying = isPlaying
    self.currentTime = currentTime
    self.duration = duration
    self.lastUpdated = lastUpdated
    self.lyrics = lyrics
  }
}
