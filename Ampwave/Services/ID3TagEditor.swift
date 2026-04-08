//
//  ID3TagEditor.swift
//  Ampwave
//
//  Reads and writes ID3v1, ID3v2.3, and ID3v2.4 tags.
//

import AVFoundation
import Foundation

struct ID3TagInfo {
  var title: String?
  var artist: String?
  var album: String?
  var year: String?
  var genre: String?
  var trackNumber: String?
  var albumArtist: String?
  var composers: [String] = []
}

enum ID3TagEditor {
  private static let id3v2Header = Data([0x49, 0x44, 0x33])  // "ID3"
  private static let id3v1Header = "TAG"

  /// Check if file has ID3 tags
  static func hasID3Tags(at url: URL) -> Bool {
    guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return false }

    // Check for ID3v2 at start
    if data.count >= 3 && data.prefix(3) == id3v2Header {
      return true
    }

    // Check for ID3v1 at end
    if data.count >= 128 {
      let endData = data.subdata(in: (data.count - 128)..<data.count)
      if endData.prefix(3) == Data(id3v1Header.utf8) {
        return true
      }
    }

    return false
  }

  /// Write ID3v2.4 tags to file (overwrites existing tags)
  static func writeID3v24Tags(to url: URL, tags: ID3TagInfo) throws {
    guard let data = try? Data(contentsOf: url) else {
      throw NSError(
        domain: "ID3TagEditor", code: -1, userInfo: [NSLocalizedDescriptionKey: "Cannot read file"])
    }

    // Strip existing ID3v2 tags
    var audioData = stripID3v2Tags(from: data)

    // Strip existing ID3v1 tags
    audioData = stripID3v1Tags(from: audioData)

    // Create new ID3v2.4 frame data
    var frameData = Data()

    if let title = tags.title, !title.isEmpty {
      frameData.append(createID3Frame(id: "TIT2", text: title))
    }

    if let artist = tags.artist, !artist.isEmpty {
      frameData.append(createID3Frame(id: "TPE1", text: artist))
    }

    if let album = tags.album, !album.isEmpty {
      frameData.append(createID3Frame(id: "TALB", text: album))
    }

    if let albumArtist = tags.albumArtist, !albumArtist.isEmpty {
      frameData.append(createID3Frame(id: "TPE2", text: albumArtist))
    }

    if let year = tags.year, !year.isEmpty {
      frameData.append(createID3Frame(id: "TYER", text: year))
    }

    if let trackNumber = tags.trackNumber, !trackNumber.isEmpty {
      frameData.append(createID3Frame(id: "TRCK", text: trackNumber))
    }

    if let genre = tags.genre, !genre.isEmpty {
      frameData.append(createID3Frame(id: "TCON", text: genre))
    }

    for composer in tags.composers {
      if !composer.isEmpty {
        frameData.append(createID3Frame(id: "TCOM", text: composer))
      }
    }

    // Create ID3v2.4 header
    let id3Header = createID3v24Header(frameDataSize: frameData.count)

    // Write: ID3 header + frames + audio data
    var finalData = id3Header
    finalData.append(frameData)
    finalData.append(audioData)

    try finalData.write(to: url)
  }

  /// Read ID3 tags from file
  static func readID3Tags(from url: URL) -> ID3TagInfo {
    guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else {
      return ID3TagInfo()
    }

    var tags = ID3TagInfo()

    // Try ID3v2 first
    if data.count >= 3 && data.prefix(3) == id3v2Header {
      if let v24Tags = parseID3v24(data) {
        tags = v24Tags
      } else if let v23Tags = parseID3v23(data) {
        tags = v23Tags
      }
    }

    // Fall back to ID3v1 if v2 not found
    if tags.title == nil && data.count >= 128 {
      let endData = data.subdata(in: (data.count - 128)..<data.count)
      if endData.prefix(3) == Data(id3v1Header.utf8) {
        parseID3v1(endData, into: &tags)
      }
    }

    return tags
  }

  // MARK: - Private Helpers

  private static func createID3v24Header(frameDataSize: Int) -> Data {
    var header = Data([0x49, 0x44, 0x33])  // "ID3"
    header.append(0x04)  // Version 2.4
    header.append(0x00)  // Revision
    header.append(0x00)  // Flags

    // Synchsafe size (7 bits per byte)
    let syncSize = encodeSynchsafeSize(frameDataSize)
    header.append(syncSize)

    return header
  }

  private static func encodeSynchsafeSize(_ size: Int) -> Data {
    var data = Data()
    var remaining = size

    for _ in 0..<4 {
      let byte = UInt8(remaining & 0x7F)
      data.insert(byte, at: 0)
      remaining >>= 7
    }

    return data
  }

  private static func decodeSynchsafeSize(_ data: Data) -> Int {
    guard data.count >= 4 else { return 0 }

    var size = 0
    for byte in data.prefix(4) {
      size = (size << 7) | Int(byte & 0x7F)
    }

    return size
  }

  private static func createID3Frame(id: String, text: String) -> Data {
    var frame = Data(id.utf8)

    let textData = Data(text.utf8)
    let frameSize = textData.count + 2  // +2 for text encoding byte and null terminator

    // Frame size (synchsafe)
    let sizeSynch = encodeSynchsafeSize(frameSize)
    frame.append(sizeSynch)

    // Flags
    frame.append(0x00)
    frame.append(0x00)

    // Text encoding (UTF-8)
    frame.append(0x03)

    // Text
    frame.append(textData)

    return frame
  }

  private static func stripID3v2Tags(from data: Data) -> Data {
    guard data.count >= 10 && data.prefix(3) == id3v2Header else {
      return data
    }

    let syncSize = decodeSynchsafeSize(data.subdata(in: 6..<10))
    let tagSize = 10 + syncSize

    guard tagSize < data.count else { return data }
    return data.subdata(in: tagSize..<data.count)
  }

  private static func stripID3v1Tags(from data: Data) -> Data {
    guard data.count >= 128 else { return data }

    let endData = data.subdata(in: (data.count - 128)..<data.count)
    guard endData.prefix(3) == Data(id3v1Header.utf8) else {
      return data
    }

    return data.subdata(in: 0..<(data.count - 128))
  }

  private static func parseID3v24(_ data: Data) -> ID3TagInfo? {
    guard data.count >= 10, data.prefix(3) == id3v2Header else { return nil }
    guard data[3] == 0x04 else { return nil }  // Version 2.4

    let syncSize = decodeSynchsafeSize(data.subdata(in: 6..<10))
    let frameStart = 10
    let frameEnd = frameStart + syncSize

    guard frameEnd <= data.count else { return nil }

    var tags = ID3TagInfo()
    let frameData = data.subdata(in: frameStart..<frameEnd)

    var offset = 0
    while offset + 10 <= frameData.count {
      let frameID =
        String(data: frameData.subdata(in: offset..<(offset + 4)), encoding: .utf8) ?? ""
      offset += 4

      let frameSizeSynch = frameData.subdata(in: offset..<(offset + 4))
      let frameSize = decodeSynchsafeSize(frameSizeSynch)
      offset += 4

      offset += 2  // Skip flags

      if frameSize == 0 { continue }

      let frameContent = frameData.subdata(in: offset..<min(offset + frameSize, frameData.count))

      // Parse text frames (encoding byte + text)
      if frameContent.count > 0 {
        let textEncoding = frameContent[0]
        let text: String?

        if textEncoding == 0x03 {  // UTF-8
          text = String(data: frameContent.subdata(in: 1..<frameContent.count), encoding: .utf8)
        } else {
          text = String(
            data: frameContent.subdata(in: 1..<frameContent.count), encoding: .isoLatin1)
        }

        switch frameID {
        case "TIT2": tags.title = text?.trimmingCharacters(in: .whitespaces)
        case "TPE1": tags.artist = text?.trimmingCharacters(in: .whitespaces)
        case "TALB": tags.album = text?.trimmingCharacters(in: .whitespaces)
        case "TPE2": tags.albumArtist = text?.trimmingCharacters(in: .whitespaces)
        case "TYER": tags.year = text?.trimmingCharacters(in: .whitespaces)
        case "TRCK": tags.trackNumber = text?.trimmingCharacters(in: .whitespaces)
        case "TCON": tags.genre = text?.trimmingCharacters(in: .whitespaces)
        case "TCOM":
          if let composer = text?.trimmingCharacters(in: .whitespaces), !composer.isEmpty {
            tags.composers.append(composer)
          }
        default: break
        }
      }

      offset += frameSize
    }

    return tags
  }

  private static func parseID3v23(_ data: Data) -> ID3TagInfo? {
    guard data.count >= 10, data.prefix(3) == id3v2Header else { return nil }
    guard data[3] == 0x03 else { return nil }  // Version 2.3

    let syncSize = decodeSynchsafeSize(data.subdata(in: 6..<10))
    let frameStart = 10
    let frameEnd = frameStart + syncSize

    guard frameEnd <= data.count else { return nil }

    var tags = ID3TagInfo()
    let frameData = data.subdata(in: frameStart..<frameEnd)

    var offset = 0
    while offset + 10 <= frameData.count {
      let frameID =
        String(data: frameData.subdata(in: offset..<(offset + 4)), encoding: .utf8) ?? ""
      offset += 4

      // v2.3 uses 3-byte size (big-endian, NOT synchsafe)
      var frameSize = 0
      frameSize |= Int(frameData[offset]) << 16
      frameSize |= Int(frameData[offset + 1]) << 8
      frameSize |= Int(frameData[offset + 2])
      offset += 3

      offset += 2  // Skip flags

      if frameSize == 0 { continue }

      let frameContent = frameData.subdata(in: offset..<min(offset + frameSize, frameData.count))

      if frameContent.count > 0 {
        let textEncoding = frameContent[0]
        let text: String?

        if textEncoding == 0x03 {
          text = String(data: frameContent.subdata(in: 1..<frameContent.count), encoding: .utf8)
        } else if textEncoding == 0x01 {
          text = String(data: frameContent.subdata(in: 1..<frameContent.count), encoding: .utf16)
        } else {
          text = String(
            data: frameContent.subdata(in: 1..<frameContent.count), encoding: .isoLatin1)
        }

        switch frameID {
        case "TIT2": tags.title = text?.trimmingCharacters(in: .whitespaces)
        case "TPE1": tags.artist = text?.trimmingCharacters(in: .whitespaces)
        case "TALB": tags.album = text?.trimmingCharacters(in: .whitespaces)
        case "TPE2": tags.albumArtist = text?.trimmingCharacters(in: .whitespaces)
        case "TYER": tags.year = text?.trimmingCharacters(in: .whitespaces)
        case "TRCK": tags.trackNumber = text?.trimmingCharacters(in: .whitespaces)
        case "TCON": tags.genre = text?.trimmingCharacters(in: .whitespaces)
        case "TCOM":
          if let composer = text?.trimmingCharacters(in: .whitespaces), !composer.isEmpty {
            tags.composers.append(composer)
          }
        default: break
        }
      }

      offset += frameSize
    }

    return tags
  }

  private static func parseID3v1(_ data: Data, into tags: inout ID3TagInfo) {
    guard data.count >= 128 else { return }

    // ID3v1 has fixed field sizes
    tags.title = extractStringFromData(data, offset: 3, length: 30)
    tags.artist = extractStringFromData(data, offset: 33, length: 30)
    tags.album = extractStringFromData(data, offset: 63, length: 30)
    tags.year = extractStringFromData(data, offset: 93, length: 4)

    // Track number (if present)
    if data[127] == 0 && data[126] != 0 {
      tags.trackNumber = String(data[126])
    }
  }

  private static func extractStringFromData(_ data: Data, offset: Int, length: Int) -> String? {
    let endOffset = min(offset + length, data.count)
    let subdata = data.subdata(in: offset..<endOffset)
    let string = String(data: subdata, encoding: .isoLatin1)?
      .trimmingCharacters(in: .controlCharacters)
      .trimmingCharacters(in: .whitespaces)

    return (string?.isEmpty == false) ? string : nil
  }
}
