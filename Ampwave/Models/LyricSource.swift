//
//  LyricSource.swift
//  Ampwave
//

import Foundation

enum LyricSource: String, Codable {
    case local = "local"
    case lrclib = "lrclib"
    case genius = "genius"
    case user = "user"
}
