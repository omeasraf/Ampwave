//
//  SyncedLyric.swift
//  Ampwave
//
//  Model for time-synced lyrics (LRC format).
//  Supports karaoke-style highlighting and auto-scrolling.
//

import Foundation
import SwiftData

@Model
final class SyncedLyric: Identifiable {
    @Attribute(.unique) var id: UUID
    var songId: UUID
    
    var lines: [LyricLine]
    var source: LyricSource
    var language: String?
    
    var fetchedAt: Date
    var lastUpdated: Date
    
    init(songId: UUID, lines: [LyricLine], source: LyricSource = .local, language: String? = nil) {
        self.id = UUID()
        self.songId = songId
        self.lines = lines
        self.source = source
        self.language = language
        self.fetchedAt = Date()
        self.lastUpdated = Date()
    }
    
    func line(at time: TimeInterval) -> LyricLine? {
        lines.last { $0.timestamp <= time }
    }
    
    func lineIndex(at time: TimeInterval) -> Int? {
        lines.lastIndex { $0.timestamp <= time }
    }
    
    func nextLine(after time: TimeInterval) -> LyricLine? {
        lines.first { $0.timestamp > time }
    }
    
    var hasLyrics: Bool {
        !lines.isEmpty
    }
    
    var plainText: String {
        lines.map { $0.text }.joined(separator: "\n")
    }
}
