//
//  LRCLIBResponse.swift
//  Ampwave
//

import Foundation

struct LRCLIBResponse: Codable {
    let id: Int
    let trackName: String
    let artistName: String
    let albumName: String?
    let duration: Double?
    let instrumental: Bool
    let plainLyrics: String?
    let syncedLyrics: String?
    let language: String?
    
    enum CodingKeys: String, CodingKey {
        case id
        case trackName = "trackName"
        case artistName = "artistName"
        case albumName = "albumName"
        case duration
        case instrumental
        case plainLyrics = "plainLyrics"
        case syncedLyrics = "syncedLyrics"
        case language
    }
}
