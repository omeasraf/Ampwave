//
//  LRCParser.swift
//  Ampwave
//

import Foundation

enum LRCParser {
  static func parse(_ content: String) -> [LyricLine] {
    var lines: [LyricLine] = []

    let pattern = #"\[(\d{2}):(\d{2})\.(\d{2,3})\](.*)"#
    guard let regex = try? NSRegularExpression(pattern: pattern) else {
      return []
    }

    let nsRange = NSRange(content.startIndex..., in: content)
    let matches = regex.matches(in: content, range: nsRange)

    for match in matches {
      guard match.numberOfRanges == 5,
        let minutesRange = Range(match.range(at: 1), in: content),
        let secondsRange = Range(match.range(at: 2), in: content),
        let fractionRange = Range(match.range(at: 3), in: content),
        let textRange = Range(match.range(at: 4), in: content),
        let minutes = Int(content[minutesRange]),
        let seconds = Int(content[secondsRange])
      else {
        continue
      }

      let fractionString = String(content[fractionRange])

      // Convert fraction properly
      let fractionalSeconds: Double

      if fractionString.count == 2 {
        // Centiseconds → divide by 100
        fractionalSeconds = Double(Int(fractionString) ?? 0) / 100.0
      } else {
        // Milliseconds → divide by 1000
        fractionalSeconds = Double(Int(fractionString) ?? 0) / 1000.0
      }

      let timestamp =
        Double(minutes * 60 + seconds) + fractionalSeconds

      let text = String(content[textRange])
        .trimmingCharacters(in: .whitespaces)

      if !text.isEmpty {
        lines.append(LyricLine(timestamp: timestamp, text: text))
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
