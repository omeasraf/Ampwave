//
//  MetadataConfidenceScorer.swift
//  Ampwave
//
//  Assigns confidence scores to metadata fields based on their source and quality.
//

import Foundation

enum MetadataConfidenceScorer {
    
    static func scoreEmbedded(value: String?, field: String) -> Double {
        guard let value = value, !value.isEmpty else { return 0.0 }
        
        // Penalize generic tags
        let genericTags = ["Unknown", "Track", "Artist", "Album", "Untitled", "Audio"]
        for tag in genericTags {
            if value.localizedCaseInsensitiveContains(tag) {
                return 0.4
            }
        }
        
        return 0.95 // High trust for embedded tags
    }
    
    static func scoreFilename(value: String?) -> Double {
        guard let value = value, !value.isEmpty else { return 0.0 }
        return 0.7 // Filenames are usually reliable but can be messy
    }
    
    static func scoreMusicBrainz(value: String?) -> Double {
        guard let value = value, !value.isEmpty else { return 0.0 }
        return 0.9 // High trust for verified online sources
    }
}
