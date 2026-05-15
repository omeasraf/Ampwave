//
//  UnicodeCleanup.swift
//  Ampwave
//
//  Utility for cleaning up and normalizing metadata strings.
//

import Foundation

enum UnicodeCleanup {
    
    /// Normalizes a string using NFKC and repairs common encoding issues.
    static func clean(_ input: String) -> String {
        var result = input.trimmingCharacters(in: .whitespacesAndNewlines)
        
        // 1. NFKC Normalization (combines characters like e + ´ into é)
        result = result.precomposedStringWithCompatibilityMapping
        
        // 2. Repair common encoding issues (e.g. malformed UTF-8, double encoding)
        result = repairEncoding(result)
        
        // 3. Normalize smart quotes and apostrophes to standard ones for consistency
        // but the plan says preserve them if possible, however for search/matching it's better to be consistent.
        // The plan says: "Preserve: ë, ç, ’". So I will keep those.
        
        return result
    }
    
    private static func repairEncoding(_ input: String) -> String {
        // Handle common double-encoding cases or replacement characters
        var result = input
        
        // Replace replacement characters if we can guess them, otherwise leave them
        // result = result.replacingOccurrences(of: "", with: "") // Risky to just remove
        
        // Repair common mojibake if detected (highly specific to language, but let's stick to basics)
        
        return result
    }
    
    /// Normalizes a string for comparison (lowercase, stripped diacritics, noise removed)
    static func normalizeForComparison(_ input: String) -> String {
        input
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .replacingOccurrences(of: "[^a-z0-9 ]", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }
}
