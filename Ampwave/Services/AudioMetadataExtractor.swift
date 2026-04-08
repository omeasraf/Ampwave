//
//  AudioMetadataExtractor.swift
//  Ampwave
//
//  Extracts metadata from audio files using AVFoundation.
//

import Foundation
import AVFoundation

/// All metadata extracted from an audio file (AVFoundation).
struct ExtractedAudioMetadata: Sendable {
    var title: String
    var artist: String
    var duration: TimeInterval
    var lyrics: String?
    var album: String?
    var albumArtist: String?
    var genre: String?
    var songDescription: String?
    var trackNumber: Int?
    var discNumber: Int?
    var year: Int?
    var composer: String?
    var artwork: Data?
}

/// Extracts metadata using AVFoundation (supports major formats and full metadata).
enum AudioMetadataExtractor: Sendable {
    
    static func extract(from url: URL) async -> ExtractedAudioMetadata {
        print("[DEBUG] AudioMetadataExtractor.extract: Starting for \(url.lastPathComponent)")
        let asset = AVURLAsset(url: url)
        let fallbackTitle = url.deletingPathExtension().lastPathComponent
        
        // Use modern load API for properties and metadata
        print("[DEBUG] AudioMetadataExtractor.extract: Loading duration and metadata...")
        async let durationTask = loadDuration(from: asset)
        async let metadataTask = try? asset.load(.commonMetadata)
        async let formatsTask = try? asset.load(.availableMetadataFormats)
        
        let duration = await durationTask
        print("[DEBUG] AudioMetadataExtractor.extract: Duration loaded: \(duration)")
        var allMetadata = (await metadataTask) ?? []
        let formats = (await formatsTask) ?? []
        print("[DEBUG] AudioMetadataExtractor.extract: Found \(formats.count) metadata formats")
        
        for format in formats {
            print("[DEBUG] AudioMetadataExtractor.extract: Loading metadata for format \(format)")
            if let metadata = try? await asset.loadMetadata(for: format) {
                allMetadata.append(contentsOf: metadata)
            }
        }
        
        print("[DEBUG] AudioMetadataExtractor.extract: Total metadata items found: \(allMetadata.count)")
        var title = fallbackTitle
        var artist = "Unknown Artist"
        var lyrics: String?
        var album: String?
        var albumArtist: String?
        var genre: String?
        var songDescription: String?
        var trackNumber: Int?
        var discNumber: Int?
        var year: Int?
        var composer: String?
        var artwork: Data?
        
        for (index, item) in allMetadata.enumerated() {
            // Load key and value asynchronously
            guard let key = item.commonKey else {
                // Format-specific key
                if let id = item.identifier?.rawValue {
                    // print("[DEBUG] AudioMetadataExtractor.extract: Processing format-specific key \(id)")
                    let value = try? await item.load(.value)
                    if id.contains("lyrics") || id.contains("Lyrics") {
                        lyrics = (value as? String) ?? lyrics
                    } else if id.contains("comment") || id.contains("Comment") || id.contains("description") {
                        songDescription = (value as? String) ?? songDescription
                    } else if id.contains("year") || id.contains("Year") || id.contains("date") {
                        if let num = value as? NSNumber {
                            year = num.intValue
                        } else if let str = value as? String {
                            year = parseYear(str)
                        }
                    } else if id.contains("track") || id.contains("Track") {
                        if let num = value as? NSNumber {
                            trackNumber = num.intValue
                        } else if let str = value as? String {
                            trackNumber = parseTrackNumber(str)
                        }
                    } else if id.contains("disc") || id.contains("Disc") {
                        discNumber = (value as? NSNumber)?.intValue ?? discNumber
                    }
                }
                continue
            }
            
            // print("[DEBUG] AudioMetadataExtractor.extract: Processing common key \(key.rawValue)")
            let value = try? await item.load(.value)
            let raw = key.rawValue.lowercased()
            
            if raw == "title" || raw.contains("title") {
                if let v = value as? String, !v.isEmpty { title = v }
            } else if raw == "artist" || raw.contains("artist"), !raw.contains("album") {
                if let v = value as? String, !v.isEmpty { artist = v }
            } else if raw.contains("albumname") || raw == "album" {
                album = (value as? String) ?? album
            } else if raw.contains("lyrics") || raw == "lyr" {
                lyrics = (value as? String) ?? lyrics
            } else if raw.contains("description") || raw.contains("comment") {
                songDescription = (value as? String) ?? songDescription
            } else if raw == "type" || raw.contains("genre") {
                genre = (value as? String) ?? genre
            } else if raw.contains("creator") || raw.contains("composer") {
                composer = (value as? String) ?? composer
            } else if raw.contains("artwork") || raw.contains("art") {
                artwork = value as? Data ?? artwork
            } else if raw.contains("albumartist") || raw.contains("album artist") {
                albumArtist = (value as? String) ?? albumArtist
            }
        }
        
        print("[DEBUG] AudioMetadataExtractor.extract: Finished processing all metadata items")
        
        // Format-specific fallbacks
        if trackNumber == nil || discNumber == nil || year == nil {
            for item in allMetadata {
                guard item.commonKey == nil else { continue }
                if let id = item.identifier?.rawValue {
                    let value = try? await item.load(.value)
                    if trackNumber == nil && (id.contains("track") || id.contains("Track")) {
                        if let num = value as? NSNumber {
                            trackNumber = num.intValue
                        } else if let str = value as? String {
                            trackNumber = parseTrackNumber(str)
                        }
                    }
                    if discNumber == nil && (id.contains("disc") || id.contains("Disc")) {
                        discNumber = (value as? NSNumber)?.intValue
                    }
                    if year == nil && (id.contains("year") || id.contains("Year") || id.contains("date")) {
                        if let num = value as? NSNumber {
                            year = num.intValue
                        } else if let str = value as? String {
                            year = parseYear(str)
                        }
                    }
                }
            }
        }
        
        return ExtractedAudioMetadata(
            title: title,
            artist: artist,
            duration: duration,
            lyrics: lyrics,
            album: album,
            albumArtist: albumArtist,
            genre: genre,
            songDescription: songDescription,
            trackNumber: trackNumber,
            discNumber: discNumber,
            year: year,
            composer: composer,
            artwork: artwork
        )
    }
    
    /// Parses "5", "5/12" -> 5
    private static func parseTrackNumber(_ s: String) -> Int? {
        let part = s.split(separator: "/").first.flatMap(String.init) ?? s
        return Int(part.trimmingCharacters(in: .whitespaces))
    }
    
    /// Parses year from "2024" or "2024-01-01"
    private static func parseYear(_ s: String) -> Int? {
        let part = String(s.prefix(4))
        return Int(part)
    }
    
    private static func loadDuration(from asset: AVURLAsset) async -> TimeInterval {
        do {
            let duration = try await asset.load(.duration)
            let seconds = CMTimeGetSeconds(duration)
            return seconds.isFinite && seconds >= 0 ? seconds : 0
        } catch {
            return 0
        }
    }
}
