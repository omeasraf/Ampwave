//
//  MetadataMatcher.swift
//  Ampwave
//
//  Utility for matching metadata from different sources using similarity scoring.
//

import Foundation

enum MetadataMatcher {
    
    /// Normalizes strings and computes a similarity score (0.0 to 1.0) between two sets of metadata.
    static func computeMatchScore(
        title1: String, artist1: String, duration1: TimeInterval?,
        title2: String, artist2: String, duration2: TimeInterval?
    ) -> Double {
        let nTitle1 = normalize(title1)
        let nArtist1 = normalize(artist1)
        let nTitle2 = normalize(title2)
        let nArtist2 = normalize(artist2)
        
        var score = 0.0
        
        // Title match (50%)
        let titleSimilarity = stringSimilarity(nTitle1, nTitle2)
        score += titleSimilarity * 0.5
        
        // Artist match (30%)
        let artistSimilarity = stringSimilarity(nArtist1, nArtist2)
        score += artistSimilarity * 0.3
        
        // Duration match (20%)
        if let d1 = duration1, let d2 = duration2, d1 > 0, d2 > 0 {
            let diff = abs(d1 - d2)
            if diff <= 2 {
                score += 0.2
            } else if diff <= 5 {
                score += 0.1
            } else if diff <= 10 {
                score += 0.05
            }
        } else {
            // If duration is missing, re-weight title and artist
            score += (titleSimilarity * 0.1) + (artistSimilarity * 0.1)
        }
        
        return score
    }
    
    private static func normalize(_ value: String) -> String {
        value
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .replacingOccurrences(of: "[^a-z0-9 ]", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }
    
    private static func stringSimilarity(_ lhs: String, _ rhs: String) -> Double {
        if lhs == rhs { return 1.0 }
        if lhs.contains(rhs) || rhs.contains(lhs) { return 0.8 }
        
        let lhsTokens = Set(lhs.split(separator: " ").map(String.init))
        let rhsTokens = Set(rhs.split(separator: " ").map(String.init))
        let overlap = lhsTokens.intersection(rhsTokens).count
        let union = lhsTokens.union(rhsTokens).count
        
        guard union > 0 else { return 0 }
        return Double(overlap) / Double(union)
    }
}
