//
//  FilenameParser.swift
//  Ampwave
//
//  Parses audio filenames to extract metadata like artist, title, year, and version.
//

import Foundation

struct ParsedFilenameMetadata {
    var title: String
    var artists: [String] = []
    var album: String?
    var year: Int?
    var isLive: Bool = false
    var isMedley: Bool = false
    var version: String?
    var confidence: Double = 0.0
}

enum FilenameParser {
    
    static func parse(_ filename: String) -> ParsedFilenameMetadata {
        // Remove extension
        let name = (filename as NSString).deletingPathExtension
        
        var metadata = ParsedFilenameMetadata(title: name)
        
        // 1. Pre-parsing cleanup (remove track numbers at start like "01. ", "01 - ")
        let cleanName = stripLeadingTrackNumbers(name)
        
        // 2. Detect Live/Medley before splitting
        metadata.isLive = detectLive(cleanName)
        metadata.isMedley = detectMedley(cleanName)
        
        // 3. Noise removal (Official Video, HD, etc.)
        let (noisedFreeName, noiseFound) = stripNoise(cleanName)
        
        // 4. Split by common separators
        let separators = [" - ", " : ", " – ", " — "]
        var parts: [String] = []
        
        for sep in separators {
            let split = noisedFreeName.components(separatedBy: sep)
            if split.count >= 2 {
                parts = split.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                break
            }
        }
        
        if parts.count >= 2 {
            // Likely "Artist - Title"
            let artistPart = parts[0]
            let titlePart = parts.dropFirst().joined(separator: " - ")
            
            metadata.artists = parseMultiArtists(artistPart)
            metadata.title = titlePart
            metadata.confidence = 0.8
        } else {
            // Fallback for names without clear separators
            metadata.title = noisedFreeName
            metadata.confidence = 0.3
        }
        
        // 5. Year detection
        if let yearMatch = detectYear(name) {
            metadata.year = yearMatch
        }
        
        // Final cleanup of title
        metadata.title = UnicodeCleanup.clean(metadata.title)
        
        return metadata
    }
    
    private static func stripLeadingTrackNumbers(_ s: String) -> String {
        let pattern = "^[0-9]{1,3}[\\s\\.\\-_/]+"
        if let range = s.range(of: pattern, options: .regularExpression) {
            return String(s[range.upperBound...])
        }
        return s
    }
    
    private static func detectLive(_ s: String) -> Bool {
        let patterns = ["\\bLIVE\\b", "\\bLive\\b", "\\(Live\\)", "\\[Live\\]", "Kolazh Live"]
        for p in patterns {
            if s.range(of: p, options: [.regularExpression, .caseInsensitive]) != nil {
                return true
            }
        }
        return false
    }
    
    private static func detectMedley(_ s: String) -> Bool {
        let patterns = ["Potpuri", "Kolazh", "Medley"]
        for p in patterns {
            if s.range(of: p, options: [.regularExpression, .caseInsensitive]) != nil {
                return true
            }
        }
        return false
    }
    
    private static func stripNoise(_ s: String) -> (String, Bool) {
        let patterns = [
            "\\(?Official (Video|Audio|Music Video)\\)?",
            "\\(?(HD|4K|HQ)\\)?",
            "@\\w+",
            "\\b(20[0-2][0-9])\\b", // Years are handled separately but often considered noise in titles
            "\\b(19[0-9][0-9])\\b",
            "[\\[\\(]?(prod\\.?|produced by|feat\\.?|featuring).*?[\\]\\)]?",
        ]
        
        var result = s
        var found = false
        
        for p in patterns {
            if let range = result.range(of: p, options: [.regularExpression, .caseInsensitive]) {
                result.removeSubrange(range)
                found = true
            }
        }
        
        return (result.trimmingCharacters(in: .whitespacesAndNewlines), found)
    }
    
    private static func detectYear(_ s: String) -> Int? {
        let pattern = "\\b(19[5-9][0-9]|20[0-2][0-9])\\b"
        if let range = s.range(of: pattern, options: .regularExpression) {
            return Int(s[range])
        }
        return nil
    }
    
    private static func parseMultiArtists(_ s: String) -> [String] {
        let separators = [" & ", " x ", " X ", " , ", " feat. ", " ft. ", " Featuring "]
        var result = [s]
        
        for sep in separators {
            var newResult: [String] = []
            for part in result {
                newResult.append(contentsOf: part.components(separatedBy: sep))
            }
            result = newResult.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        }
        
        return result
    }
}
