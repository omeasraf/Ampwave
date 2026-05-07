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

      // Parse word offsets if present: <00:00.00> word
      var wordOffsets: [WordOffset] = []
      let wordPattern = #"<(\d{2}):(\d{2})\.(\d{2,3})>([^<]*)"#
      if let wordRegex = try? NSRegularExpression(pattern: wordPattern) {
        let wordMatches = wordRegex.matches(
          in: rawLineContent, range: NSRange(rawLineContent.startIndex..., in: rawLineContent))

        for wordMatch in wordMatches {
          guard wordMatch.numberOfRanges == 5,
            let wMinRange = Range(wordMatch.range(at: 1), in: rawLineContent),
            let wSecRange = Range(wordMatch.range(at: 2), in: rawLineContent),
            let wFracRange = Range(wordMatch.range(at: 3), in: rawLineContent),
            let wTextRange = Range(wordMatch.range(at: 4), in: rawLineContent),
            let wMin = Int(rawLineContent[wMinRange]),
            let wSec = Int(rawLineContent[wSecRange])
          else {
            continue
          }

          let wFracString = String(rawLineContent[wFracRange])
          let wFracSeconds: Double
          if wFracString.count == 2 {
            wFracSeconds = Double(Int(wFracString) ?? 0) / 100.0
          } else {
            wFracSeconds = Double(Int(wFracString) ?? 0) / 1000.0
          }

          let wordTimestamp = Double(wMin * 60 + wSec) + wFracSeconds
          let wordText = String(rawLineContent[wTextRange])
          wordOffsets.append(WordOffset(timestamp: wordTimestamp, text: wordText))
        }
      }

      let text: String
      if wordOffsets.isEmpty {
        text = rawLineContent.trimmingCharacters(in: .whitespaces)
      } else {
        // Reconstruct text from word offsets for consistency if needed,
        // but often the rawLineContent without tags is better.
        // Let's just strip the tags for the 'text' property.
        text = rawLineContent.replacingOccurrences(
          of: #"<\d{2}:\d{2}\.\d{2,3}>"#, with: "", options: .regularExpression
        ).trimmingCharacters(in: .whitespaces)
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

  static func toLRC(_ lines: [LyricLine]) -> String {
    lines.map { "[\($0.formattedTime)] \($0.text)" }.joined(separator: "\n")
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
