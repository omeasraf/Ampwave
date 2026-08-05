//
//  LRCParser.swift
//  Ampwave
//

import Foundation

enum LRCParser {
  static func parse(_ content: String) -> [LyricLine] {
    var lines: [LyricLine] = []

    let linePattern = #"\[(\d{2}):(\d{2})\.(\d{2,3})\](.*)"#
    guard let lineRegex = try? NSRegularExpression(pattern: linePattern) else {
      return []
    }

    let nsRange = NSRange(content.startIndex..., in: content)
    let matches = lineRegex.matches(in: content, range: nsRange)

    for match in matches {
      guard match.numberOfRanges == 5,
        let minutesRange = Range(match.range(at: 1), in: content),
        let secondsRange = Range(match.range(at: 2), in: content),
        let fractionRange = Range(match.range(at: 3), in: content),
        let contentRange = Range(match.range(at: 4), in: content),
        let minutes = Int(content[minutesRange]),
        let seconds = Int(content[secondsRange])
      else {
        continue
      }

      let fractionString = String(content[fractionRange])
      let fractionalSeconds: Double
      if fractionString.count == 2 {
        fractionalSeconds = Double(Int(fractionString) ?? 0) / 100.0
      } else {
        fractionalSeconds = Double(Int(fractionString) ?? 0) / 1000.0
      }

      let lineTimestamp = Double(minutes * 60 + seconds) + fractionalSeconds
      let rawLineContent = String(content[contentRange])

      // Parse word-synced tokens if present: <mm:ss.xxx>word
      //
      // Strategy: treat each timestamp-tagged segment as its own word/syllable unit.
      // We don't attempt syllable merging because many common enhanced-LRC sources
      // omit the trailing spaces that would normally signal word boundaries, making
      // it impossible to reliably distinguish "provoca"+"tive" from "I"+"don't".
      //
      // For the display text we strip the timestamp tags and use the raw text when
      // it already has spaces (well-formed LRC), or join the token texts with spaces
      // when the format is space-free.
      var wordOffsets: [WordOffset] = []
      let wordPattern = #"<(\d{2}):(\d{2})\.(\d{2,3})>([^<]*)"#

      if let wordRegex = try? NSRegularExpression(pattern: wordPattern) {
        let wordMatches = wordRegex.matches(
          in: rawLineContent,
          range: NSRange(rawLineContent.startIndex..., in: rawLineContent)
        )

        for wordMatch in wordMatches {
          guard wordMatch.numberOfRanges == 5,
            let wMinRange  = Range(wordMatch.range(at: 1), in: rawLineContent),
            let wSecRange  = Range(wordMatch.range(at: 2), in: rawLineContent),
            let wFracRange = Range(wordMatch.range(at: 3), in: rawLineContent),
            let wTextRange = Range(wordMatch.range(at: 4), in: rawLineContent),
            let wMin = Int(rawLineContent[wMinRange]),
            let wSec = Int(rawLineContent[wSecRange])
          else { continue }

          let wFracStr = String(rawLineContent[wFracRange])
          let wFrac: Double = wFracStr.count == 2
            ? Double(Int(wFracStr) ?? 0) / 100.0
            : Double(Int(wFracStr) ?? 0) / 1000.0

          let ts  = Double(wMin * 60 + wSec) + wFrac
          let raw = String(rawLineContent[wTextRange])

          // Each space-separated part becomes its own WordOffset.
          // This handles both "word " (trailing space = standalone word)
          // and "word" (no space = still its own unit in this format).
          let parts = raw.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
          for part in parts {
            wordOffsets.append(WordOffset(timestamp: ts, text: part))
          }
        }

      }

      let text: String
      if wordOffsets.isEmpty {
        text = rawLineContent.trimmingCharacters(in: .whitespaces)
      } else {
        // Try to reconstruct display text by stripping the <ts> tags.
        // If the result has natural word spaces (well-formed LRC) use it directly;
        // otherwise fall back to joining merged token texts with spaces.
        let stripped = rawLineContent
          .replacingOccurrences(
            of: #"<\d{2}:\d{2}\.\d{2,3}>"#,
            with: "",
            options: .regularExpression
          )
          .trimmingCharacters(in: .whitespacesAndNewlines)

        text = stripped.contains(" ")
          ? stripped
          : wordOffsets.map(\.text).joined(separator: " ")
      }

      if !text.isEmpty {
        lines.append(
          LyricLine(
            timestamp: lineTimestamp,
            text: text,
            wordOffsets: wordOffsets.isEmpty ? nil : wordOffsets
          ))
      }
    }

    return lines.sorted { $0.timestamp < $1.timestamp }
  }

  // MARK: - Syllable merging

  /// Merges syllable-fragment tokens into whole words.
  ///
  /// e.g. ["provoca", "tive"] → ["provocative"]
  ///      ["e", "very"]       → ["every"]
  ///
  /// This is intentionally kept as a public utility so views can apply it to
  /// already-cached `wordOffsets` without requiring a re-parse.
  ///
  /// - Note: The heuristic is tuned for Latin-script languages where syllable
  ///   fragments characteristically end in 'i', long-word 'a', bare 'e', or
  ///   short 'y'. It works well for English and will be mostly harmless for
  ///   non-Latin scripts (Korean, Japanese, Chinese) since those characters
  ///   won't match the rules. Romance-language LRC files may occasionally
  ///   see false merges; pass the result of `SyncedLyric.language == "en"`
  ///   as `enabled` to restrict merging to English when the language is known.
  static func mergeSyllables(_ tokens: [WordOffset], enabled: Bool = true) -> [WordOffset] {
    guard enabled, !tokens.isEmpty else { return tokens }
    var result: [WordOffset] = []
    var i = 0
    while i < tokens.count {
      var combinedText = tokens[i].text
      let ts = tokens[i].timestamp
      while isSyllableFragment(combinedText), i + 1 < tokens.count {
        i += 1
        combinedText += tokens[i].text
      }
      result.append(WordOffset(timestamp: ts, text: combinedText))
      i += 1
    }
    return result
  }

  /// `true` when `text` is an incomplete syllable that should be concatenated
  /// (no space) with the token that follows it.
  ///
  /// Rules (tuned for English):
  ///   • Bare "e"        → fragment  ("e"+"very", "e"+"ven")
  ///   • Ends 'i', ≥2   → fragment  ("ti"+"ming", "Chemi"+"cal")
  ///   • Ends 'a', ≥4   → fragment  ("provoca"+"tive", "ultra"+"violet")
  ///   • 2-char 'y', not "my"/"by" → fragment  ("dy"+"ing")
  static func isSyllableFragment(_ text: String) -> Bool {
    let lower = text.lowercased()
    guard let last = lower.last else { return false }
    switch last {
    case "e": return text.count == 1
    case "i": return text.count >= 2
    case "a": return text.count >= 4
    case "y": return text.count == 2 && lower != "my" && lower != "by"
    default:  return false
    }
  }

  static func toLRC(_ lines: [LyricLine]) -> String {
    lines.map { line in
      let text: String
      if let wordOffsets = line.wordOffsets, !wordOffsets.isEmpty {
        text = wordOffsets.map { "<\(formattedTime($0.timestamp))>\($0.text)" }.joined()
      } else {
        text = line.text
      }

      return "[\(line.formattedTime)] \(text)"
    }.joined(separator: "\n")
  }

  /// Strips every LRC marker out of `content`, leaving readable text.
  ///
  /// Covers all three things an LRC file can carry: line timestamps
  /// (`[00:12.34]`), metadata tags (`[ar:…]`, `[offset:…]`), and the inline
  /// word timestamps `toLRC` writes for word-synced lyrics (`<00:12.340>`).
  /// Missing that last form is why raw timings showed up in the plain-text
  /// view.
  nonisolated static func plainText(from content: String) -> String {
    let patterns = [
      #"\[\d{1,2}:\d{2}(?:[.:]\d{1,3})?\]"#,  // line timestamps
      #"\[[a-zA-Z#]+:[^\]]*\]"#,  // metadata tags
      #"<\d{1,2}:\d{2}(?:[.:]\d{1,3})?>"#,  // word timestamps
    ]

    var cleaned = content
    for pattern in patterns {
      cleaned = cleaned.replacingOccurrences(
        of: pattern,
        with: "",
        options: .regularExpression
      )
    }

    // Word timestamps sit flush against their words, so removing them can
    // leave doubled spaces mid-line.
    return
      cleaned
      .split(separator: "\n", omittingEmptySubsequences: false)
      .map {
        $0.replacingOccurrences(of: #"[ \t]+"#, with: " ", options: .regularExpression)
          .trimmingCharacters(in: .whitespaces)
      }
      .joined(separator: "\n")
      .trimmingCharacters(in: .whitespacesAndNewlines)
  }

  /// True when `content` carries LRC timing markers of any kind.
  static func isLRCFormatted(_ content: String) -> Bool {
    content.range(of: #"\[\d{1,2}:\d{2}(?:[.:]\d{1,3})?\]"#, options: .regularExpression) != nil
  }

  private static func formattedTime(_ timestamp: TimeInterval) -> String {
    let minutes = Int(timestamp) / 60
    let seconds = Int(timestamp) % 60
    let milliseconds = Int((timestamp - Double(Int(timestamp))) * 1000)
    return String(format: "%02d:%02d.%03d", minutes, seconds, milliseconds)
  }
}

extension String {
  subscript(range: NSRange) -> Substring {
    guard let swiftRange = Range(range, in: self) else {
      return ""
    }
    return self[swiftRange]
  }
}
