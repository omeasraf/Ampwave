//
//  TTMLParser.swift
//  Ampwave
//
//  Parses Apple Music TTML (Timed Text Markup Language) lyrics into LyricLine + WordOffset arrays.
//  TTML uses XML with <p begin="H:MM:SS.mmm"> for lines and <span begin="..."> for word timestamps.
//

import Foundation

enum TTMLParser {
  /// Parse an Apple Music TTML string into an array of LyricLine.
  /// Returns an empty array if the string is not valid TTML or contains no timing data.
  static func parse(_ ttml: String) -> [LyricLine] {
    // Quick sanity check — must be XML-like
    guard ttml.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("<") else { return [] }

    let delegate = TTMLXMLDelegate()
    let data = Data(ttml.utf8)
    let parser = XMLParser(data: data)
    parser.delegate = delegate
    parser.parse()
    return delegate.lines.sorted { $0.timestamp < $1.timestamp }
  }

  // MARK: - Time parsing

  /// Accepts formats: H:MM:SS.mmm  /  MM:SS.mmm  /  SS.mmm
  static func parseTime(_ str: String) -> TimeInterval? {
    let parts = str.split(separator: ":", omittingEmptySubsequences: false)
    switch parts.count {
    case 1:
      return TimeInterval(parts[0])
    case 2:
      guard let m = TimeInterval(parts[0]), let s = TimeInterval(parts[1]) else { return nil }
      return m * 60 + s
    case 3:
      guard let h = TimeInterval(parts[0]),
        let m = TimeInterval(parts[1]),
        let s = TimeInterval(parts[2])
      else { return nil }
      return h * 3600 + m * 60 + s
    default:
      return nil
    }
  }
}

// MARK: - XMLParserDelegate

private final class TTMLXMLDelegate: NSObject, XMLParserDelegate {
  var lines: [LyricLine] = []

  private var lineTimestamp: TimeInterval?
  private var lineWords: [WordOffset] = []
  private var wordTimestamp: TimeInterval?
  private var wordBuffer = ""
  private var inSpan = false

  func parser(
    _ parser: XMLParser,
    didStartElement elementName: String,
    namespaceURI: String?,
    qualifiedName _: String?,
    attributes: [String: String] = [:]
  ) {
    switch elementName {
    case "p", "P":
      lineTimestamp = attributes["begin"].flatMap { TTMLParser.parseTime($0) }
      lineWords = []
      inSpan = false

    case "span", "SPAN":
      wordTimestamp = attributes["begin"].flatMap { TTMLParser.parseTime($0) }
      wordBuffer = ""
      inSpan = true

    default:
      break
    }
  }

  func parser(_ parser: XMLParser, foundCharacters string: String) {
    if inSpan {
      wordBuffer += string
    }
  }

  func parser(
    _ parser: XMLParser,
    didEndElement elementName: String,
    namespaceURI: String?,
    qualifiedName _: String?
  ) {
    switch elementName {
    case "span", "SPAN":
      if let ts = wordTimestamp, !wordBuffer.isEmpty {
        lineWords.append(WordOffset(timestamp: ts, text: wordBuffer))
      }
      inSpan = false
      wordBuffer = ""
      wordTimestamp = nil

    case "p", "P":
      guard let lineTs = lineTimestamp, !lineWords.isEmpty else {
        lineTimestamp = nil
        lineWords = []
        return
      }
      let fullText = lineWords.map(\.text)
        .joined()
        .trimmingCharacters(in: .whitespacesAndNewlines)
      guard !fullText.isEmpty else {
        lineTimestamp = nil
        lineWords = []
        return
      }
      lines.append(
        LyricLine(
          timestamp: lineTs,
          text: fullText,
          wordOffsets: lineWords
        ))
      lineTimestamp = nil
      lineWords = []

    default:
      break
    }
  }
}
