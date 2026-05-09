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
    self.isPlaying = isPlaying
    self.currentTime = currentTime
    self.duration = duration
    self.lastUpdated = lastUpdated
    self.lyrics = lyrics
  }
}
