//
//  LyricSource.swift
//  Ampwave
//

import Foundation

enum LyricSource: String, Codable {
  case local = "local"
  case lrclib = "lrclib"
  case lyricsPlus = "lyricsPlus"
  case biniLyrics = "biniLyrics"
  case appleMusic = "appleMusic"
  case genius = "genius"
  case user = "user"
}
