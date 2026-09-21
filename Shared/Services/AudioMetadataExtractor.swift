//
//  AudioMetadataExtractor.swift
//  Ampwave
//
//  Extracts metadata from audio files using AVFoundation.
//

import AVFoundation
import Foundation

/// A compact, persistable representation of one ID3v2.4 frame. Text and URL
/// payloads are retained in full. Binary payloads are represented by their
/// declared type and size so artwork/provenance data is not duplicated in the
/// SwiftData store.
struct ID3v2Tag: Codable, Hashable, Sendable {
  var frameID: String
  var value: String?
  var descriptor: String?
  var language: String?
  var mimeType: String?
  var fileName: String?
  var binaryDataSize: Int?
  var flags: UInt16
}

/// All metadata extracted from an audio file.
struct ExtractedAudioMetadata: Sendable {
  var title: String
  var artist: String
  var artists: [String] = []
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
  var isExplicit: Bool?
  var lyricist: String?
  var isrc: String?
  var id3v2Tags: [ID3v2Tag] = []
  var isAIGenerated: Bool = false
  /// ReplayGain track gain in dB, when the file carries the tag.
  var replayGainDB: Double?

  // Confidence & Sources
  var titleConfidence: Double = 0.0
  var artistConfidence: Double = 0.0
  var albumConfidence: Double = 0.0
  var metadataSourceTitle: String = "unknown"
  var metadataSourceArtist: String = "unknown"
  var metadataSourceAlbum: String = "unknown"
  var isCompilation: Bool = false
  var isLive: Bool = false
  var isMedley: Bool = false

  // Technical
  var sampleRate: Double?
  var bitDepth: Int?
  var bitRate: Int?
  var channels: Int?
  var format: String?
}

/// Extracts metadata using AVFoundation, Filename Parsing, and Folder Context.
enum AudioMetadataExtractor: Sendable {

  static func extract(from url: URL) async -> ExtractedAudioMetadata {
    print("[DEBUG] AudioMetadataExtractor.extract: Starting for \(url.lastPathComponent)")
    let asset = AVURLAsset(url: url)
    
    // 1. Technical & Embedded Metadata
    async let durationTask = loadDuration(from: asset)
    async let metadataTask = try? asset.load(.commonMetadata)
    async let formatsTask = try? asset.load(.availableMetadataFormats)
    async let technicalTask = loadTechnicalMetadata(from: asset)

    let duration = await durationTask
    var allMetadata = (await metadataTask) ?? []
    let formats = (await formatsTask) ?? []
    let technical = await technicalTask

    for format in formats {
      if let metadata = try? await asset.loadMetadata(for: format) {
        allMetadata.append(contentsOf: metadata)
      }
    }

    var embeddedTitle: String?
    var embeddedArtist: String?
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
    var isCompilation: Bool = false
    var isExplicit: Bool?
    var lyricist: String?
    var isrc: String?
    var id3v2Tags: [ID3v2Tag] = []
    var isAIGenerated = false
    var replayGainDB: Double?

    for item in allMetadata {
      let value = try? await item.load(.value)
      let idRaw = item.identifier?.rawValue ?? ""
      let idLower = idRaw.lowercased()
      // FLAC/Ogg carry ReplayGain as a Vorbis comment and MP3 as a TXXX frame;
      // in both cases the tag name lands on `key` rather than the identifier.
      let keyLower = (stringValue(item.key) ?? "").lowercased()
      let infoLower = (stringValue(item.extraAttributes?[.info]) ?? "").lowercased()

      if replayGainDB == nil,
        idLower.contains("replaygain") || keyLower.contains("replaygain")
          || infoLower.contains("replaygain"),
        keyLower.contains("track") || idLower.contains("track")
          || infoLower.contains("track") || keyLower.isEmpty,
        let gain = parseReplayGain(value)
      {
        replayGainDB = gain
      }

      // ── Non-common-key path (format-specific identifiers) ──────────────────
      guard let key = item.commonKey else {
        // Match on the actual well-known identifiers first — e.g. ID3's
        // "TRCK"/"TPOS"/"TYER" and iTunes's "trkn"/"disk"/"©day" atoms never
        // contain the English substrings ("track"/"disc"/"year") the
        // fallback below looks for, so without this exact match those tags
        // were silently dropped for essentially every standard file.
        if let identifier = item.identifier {
          switch identifier {
          case .id3MetadataTrackNumber, .iTunesMetadataTrackNumber:
            trackNumber = parsePosition(value) ?? trackNumber
            continue
          case .id3MetadataPartOfASet, .iTunesMetadataDiscNumber:
            discNumber = parsePosition(value) ?? discNumber
            continue
          case .id3MetadataYear, .id3MetadataRecordingTime, .id3MetadataOriginalReleaseYear,
            .iTunesMetadataReleaseDate, .quickTimeMetadataYear:
            if let num = value as? NSNumber { year = num.intValue }
            else if let str = stringValue(value) { year = parseYear(str) }
            continue
          case .iTunesMetadataContentRating:
            if let num = value as? NSNumber { isExplicit = num.intValue != 0 }
            else if let str = stringValue(value) {
              let normalized = str.lowercased()
              isExplicit = !(normalized == "clean" || normalized == "0" || normalized.isEmpty)
            }
            continue
          case .iTunesMetadataDiscCompilation:
            if let num = value as? NSNumber { isCompilation = num.boolValue }
            else if let str = stringValue(value) { isCompilation = (str == "1" || str.lowercased() == "true") }
            continue
          default:
            break
          }
        }

        if idRaw.contains("lyrics") || idRaw.contains("Lyrics") { lyrics = stringValue(value) ?? lyrics }
        else if idLower == "id3/comm" || keyLower == "comm" || infoLower == "comment"
          || idLower.contains("comment") || idLower.contains("description")
        {
          songDescription = stringValue(value) ?? songDescription
        }
        else if idLower.contains("advisory") || idLower.contains("explicit") {
          if let num = value as? NSNumber { isExplicit = num.intValue != 0 }
          else if let str = stringValue(value) {
            let normalized = str.lowercased()
            isExplicit = (normalized == "1" || normalized == "true" || normalized == "explicit")
          }
        }
        else if idRaw.contains("year") || idRaw.contains("Year") || idRaw.contains("date") || idRaw.contains("Date") {
          if let num = value as? NSNumber { year = num.intValue }
          else if let str = stringValue(value) { year = parseYear(str) }
        }
        else if (idLower.contains("track") || keyLower.contains("track") || idLower.contains("trck"))
          && !idLower.contains("artist") && !keyLower.contains("artist")
        {
          trackNumber = parsePosition(value) ?? trackNumber
        }
        else if idLower.contains("disc") || keyLower.contains("disc") || idLower.contains("tpos") {
          discNumber = parsePosition(value) ?? discNumber
        }
        // Vorbis comments (FLAC/Ogg) and several ID3 readers expose the tag
        // name through `key`, not `identifier`. Checking both is essential for
        // embedded genres to survive an offline import.
        else if idLower.contains("genre") || keyLower.contains("genre")
          || idLower.contains("tcon") || idLower.contains("gnre")
        {
          genre = stringValue(value) ?? genre
        }
        // Compilation flag: ID3 TCMP, iTunes cpil
        else if idRaw.contains("TCMP") || idRaw.contains("cpil") || idLower.contains("compilation") {
          if let num = value as? NSNumber { isCompilation = num.boolValue }
          else if let str = stringValue(value) { isCompilation = (str == "1" || str.lowercased() == "true") }
        }
        // Album Artist:
        // • ID3 MP3  → TPE2  (Band/Orchestra — de-facto Album Artist)
        // • iTunes/M4A → aART (album artist atom)
        // • FLAC/Ogg → ALBUMARTIST as a TXXX user-defined frame
        else if idRaw.contains("TPE2") || idRaw.contains("aART")
             || idLower.contains("albumartist") || idLower.contains("album artist")
             || idLower.contains("album_artist") || keyLower.contains("albumartist")
             || keyLower.contains("album artist") || keyLower.contains("album_artist")
             || infoLower == "albumartist" || infoLower == "album artist"
             || infoLower == "album_artist" {
          if let v = stringValue(value) {
            albumArtist = v
          }
        }
        continue
      }

      // ── Common-key path ────────────────────────────────────────────────────
      let raw = key.rawValue.lowercased()
      if raw == "title" || raw.contains("title") { embeddedTitle = stringValue(value) ?? embeddedTitle }
      else if raw == "artist" || raw.contains("artist"), !raw.contains("album") { embeddedArtist = stringValue(value) ?? embeddedArtist }
      else if raw.contains("albumname") || raw == "album" { album = stringValue(value) ?? album }
      else if raw.contains("lyrics") || raw == "lyr" { lyrics = stringValue(value) ?? lyrics }
      else if raw == "type" || raw.contains("genre") { genre = stringValue(value) ?? genre }
      else if raw.contains("creator") || raw.contains("composer") { composer = stringValue(value) ?? composer }
      else if raw.contains("artwork") || raw.contains("art") { artwork = value as? Data ?? artwork }
      // Some encoders surface albumArtist through a common-key variant
      else if raw.contains("albumartist") || raw.contains("album artist") {
        if let v = stringValue(value) {
          albumArtist = v
        }
      }
    }

    // AVFoundation does not consistently expose ID3 frame descriptors or
    // binary frames. Keep a compact snapshot of every v2.4 frame, and use the
    // direct parser as the authoritative source for standard text fields.
    if url.pathExtension.lowercased() == "mp3", let id3 = readID3Metadata(from: url) {
      if id3.version == 4 { id3v2Tags = id3.tags }
      lyrics = id3.lyrics ?? lyrics
      embeddedTitle = id3.firstValue(for: "TIT2") ?? embeddedTitle
      embeddedArtist = id3.firstValue(for: "TPE1") ?? embeddedArtist
      album = id3.firstValue(for: "TALB") ?? album
      albumArtist = id3.firstValue(for: "TPE2") ?? albumArtist
      genre = id3.firstValue(for: "TCON") ?? genre
      composer = id3.firstValue(for: "TCOM") ?? composer
      lyricist = id3.firstValue(for: "TEXT") ?? lyricist
      isrc = id3.firstValue(for: "TSRC") ?? isrc
      trackNumber = id3.firstValue(for: "TRCK").flatMap(parseTrackNumber) ?? trackNumber
      discNumber = id3.firstValue(for: "TPOS").flatMap(parseTrackNumber) ?? discNumber
      year = id3.firstValue(for: "TDRC").flatMap(parseYear)
        ?? id3.firstValue(for: "TYER").flatMap(parseYear) ?? year
      songDescription = id3.firstValue(for: "COMM")
        ?? id3.firstValue(for: "TXXX", descriptor: "comment") ?? songDescription
      replayGainDB = id3.firstValue(for: "TXXX", descriptor: "REPLAYGAIN_TRACK_GAIN")
        .flatMap { parseReplayGain($0) } ?? replayGainDB
      isAIGenerated = id3.hasC2PAProvider(named: "Suno, Inc.")
    }

    // AVFoundation exposes FLAC/Vorbis fields as opaque Objective-C tag
    // objects and does not expose FLAC PICTURE blocks at all on Apple
    // platforms. Read the small metadata prefix directly so local tags remain
    // authoritative and cover art works without an online lookup.
    if url.pathExtension.lowercased() == "flac", let flac = readFLACMetadata(from: url) {
      func comment(_ names: String...) -> String? {
        names.lazy.compactMap { flac.comments[$0]?.first }.first
      }

      embeddedTitle = comment("TITLE") ?? embeddedTitle
      embeddedArtist = comment("ARTIST") ?? embeddedArtist
      album = comment("ALBUM") ?? album
      albumArtist = comment("ALBUMARTIST", "ALBUM_ARTIST", "ALBUM ARTIST") ?? albumArtist
      genre = comment("GENRE") ?? genre
      trackNumber = comment("TRACKNUMBER", "TRACK").flatMap(parseTrackNumber) ?? trackNumber
      discNumber = comment("DISCNUMBER", "DISC").flatMap(parseTrackNumber) ?? discNumber
      year = comment("DATE", "YEAR").flatMap(parseYear) ?? year
      composer = comment("COMPOSER") ?? composer
      lyrics = comment("LYRICS", "UNSYNCEDLYRICS", "UNSYNCED LYRICS") ?? lyrics
      songDescription = comment("DESCRIPTION", "COMMENT") ?? songDescription
      replayGainDB = comment("REPLAYGAIN_TRACK_GAIN").flatMap(parseReplayGain) ?? replayGainDB
      artwork = flac.artwork ?? artwork

      if let compilation = comment("COMPILATION")?.lowercased() {
        isCompilation = compilation == "1" || compilation == "true" || compilation == "yes"
      }
      if let advisory = comment("ITUNESADVISORY", "EXPLICIT")?.lowercased() {
        isExplicit = advisory == "1" || advisory == "true" || advisory == "yes" || advisory == "explicit"
      }
    }

    // 2. Filename Parsing
    let filename = url.lastPathComponent
    let filenameMetadata = FilenameParser.parse(filename)
    
    // 3. Broken Path Reconstruction & Folder Context
    let folderName = url.deletingLastPathComponent().lastPathComponent
    let folderMetadata = FilenameParser.parse(folderName + ".mp3") // Use folder as a "virtual" file for parsing
    
    // Resolve Title
    var finalTitle = embeddedTitle ?? filenameMetadata.title
    var titleConfidence = MetadataConfidenceScorer.scoreEmbedded(value: embeddedTitle, field: "title")
    var titleSource = "embedded"
    
    if titleConfidence < 0.5 {
        // Filename is likely better if embedded is generic
        let fileTitleConfidence = MetadataConfidenceScorer.scoreFilename(value: filenameMetadata.title)
        if fileTitleConfidence > titleConfidence {
            finalTitle = filenameMetadata.title
            titleConfidence = fileTitleConfidence
            titleSource = "filename"
        }
    }
    
    // Handle "Broken Path": If filename is just a number/short string and folder has a high confidence title
    if finalTitle.count <= 3 || finalTitle.range(of: "^[0-9]+$", options: String.CompareOptions.regularExpression) != nil {
        if folderMetadata.confidence > 0.6 {
            finalTitle = folderMetadata.title
            titleConfidence = folderMetadata.confidence
            titleSource = "folder"
        }
    }

    // Resolve Artist
    var finalArtist = embeddedArtist ?? filenameMetadata.artists.joined(separator: " & ")
    if finalArtist == "Unknown Artist" && !filenameMetadata.artists.isEmpty {
        finalArtist = filenameMetadata.artists.joined(separator: " & ")
    }
    var artistConfidence = MetadataConfidenceScorer.scoreEmbedded(value: embeddedArtist, field: "artist")
    var artistSource = "embedded"
    
    if artistConfidence < 0.5 && !filenameMetadata.artists.isEmpty {
        finalArtist = filenameMetadata.artists.joined(separator: " & ")
        artistConfidence = MetadataConfidenceScorer.scoreFilename(value: finalArtist)
        artistSource = "filename"
    }
    
    if artistConfidence < 0.5 && !folderMetadata.artists.isEmpty {
        finalArtist = folderMetadata.artists.joined(separator: " & ")
        artistConfidence = folderMetadata.confidence
        artistSource = "folder"
    }

    // Resolve Album
    var finalAlbum = album ?? folderName
    var albumConfidence = MetadataConfidenceScorer.scoreEmbedded(value: album, field: "album")
    var albumSource = "embedded"
    
    if albumConfidence < 0.4 {
        finalAlbum = folderName
        albumConfidence = 0.5
        albumSource = "folder"
    }

    // Final Normalization
    finalTitle = UnicodeCleanup.clean(finalTitle)
    finalArtist = UnicodeCleanup.clean(finalArtist)
    finalAlbum = UnicodeCleanup.clean(finalAlbum)

    return ExtractedAudioMetadata(
      title: finalTitle,
      artist: finalArtist,
      artists: artistSource == "filename" ? filenameMetadata.artists : ArtistParser.parseArtists(from: finalArtist),
      duration: duration,
      lyrics: lyrics,
      album: finalAlbum,
      albumArtist: albumArtist,
      genre: genre,
      songDescription: songDescription,
      trackNumber: trackNumber,
      discNumber: discNumber,
      year: year ?? filenameMetadata.year ?? folderMetadata.year,
      composer: composer,
      artwork: artwork,
      isExplicit: isExplicit,
      lyricist: lyricist,
      isrc: isrc,
      id3v2Tags: id3v2Tags,
      isAIGenerated: isAIGenerated,
      replayGainDB: replayGainDB,
      titleConfidence: titleConfidence,
      artistConfidence: artistConfidence,
      albumConfidence: albumConfidence,
      metadataSourceTitle: titleSource,
      metadataSourceArtist: artistSource,
      metadataSourceAlbum: albumSource,
      isCompilation: isCompilation,
      isLive: filenameMetadata.isLive || folderMetadata.isLive,
      isMedley: filenameMetadata.isMedley || folderMetadata.isMedley,
      sampleRate: technical.sampleRate,
      bitDepth: technical.bitDepth,
      bitRate: technical.bitRate,
      channels: technical.channels,
      format: technical.format ?? url.pathExtension.uppercased()
    )
  }

  private static func loadTechnicalMetadata(from asset: AVURLAsset) async -> (
    sampleRate: Double?, bitDepth: Int?, bitRate: Int?, channels: Int?, format: String?
  ) {
    var sampleRate: Double?
    var bitDepth: Int?
    var bitRate: Int?
    var channels: Int?
    var format: String?

    do {
      let tracks = try await asset.load(.tracks)
      if let audioTrack = tracks.first(where: { $0.mediaType == .audio }) {
        let formatDescriptions = try await audioTrack.load(.formatDescriptions)
        if let desc = formatDescriptions.first {
          let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(desc)?.pointee
          if let asbd = asbd {
            sampleRate = asbd.mSampleRate
            channels = Int(asbd.mChannelsPerFrame)
            bitDepth = Int(asbd.mBitsPerChannel)

            // Map format
            let formatID = asbd.mFormatID
            switch formatID {
            case kAudioFormatLinearPCM: format = "PCM"
            case kAudioFormatMPEG4AAC: format = "AAC"
            case kAudioFormatMPEGLayer3: format = "MP3"
            case kAudioFormatAppleLossless: format = "ALAC"
            case kAudioFormatFLAC: format = "FLAC"
            case kAudioFormatOpus: format = "Opus"
            default: format = nil
            }
          }
        }

        // Bitrate
        let estimatedBitRate = try? await audioTrack.load(.estimatedDataRate)
        if let rate = estimatedBitRate, rate > 0 {
          bitRate = Int(rate / 1000)  // Convert to kbps
        }
      }
    } catch {
      print("[DEBUG] AudioMetadataExtractor: Error loading technical metadata: \(error)")
    }

    return (sampleRate, bitDepth, bitRate, channels, format)
  }

  /// Parses "5", "5/12" -> 5.
  private static func parseTrackNumber(_ s: String) -> Int? {
    let part = s.split(separator: "/").first.flatMap(String.init) ?? s
    return Int(part.trimmingCharacters(in: .whitespaces))
  }

  /// Track and disc positions are strings in ID3/Vorbis, but iTunes `trkn`
  /// and `disk` atoms are commonly returned as big-endian binary data.
  private static func parsePosition(_ value: Any?) -> Int? {
    if let number = value as? NSNumber, number.intValue > 0 {
      return number.intValue
    }
    if let string = stringValue(value), let number = parseTrackNumber(string) {
      return number
    }
    guard let data = value as? Data else { return nil }

    if let string = String(data: data, encoding: .utf8)?
      .trimmingCharacters(in: .controlCharacters.union(.whitespacesAndNewlines)),
      let number = parseTrackNumber(string)
    {
      return number
    }

    // Apple stores the position in bytes 2...3 (network byte order), followed
    // by the total track/disc count. Zero means the field is unset.
    guard data.count >= 4 else { return nil }
    let bytes = [UInt8](data)
    let number = (Int(bytes[2]) << 8) | Int(bytes[3])
    return number > 0 ? number : nil
  }

  private static func stringValue(_ value: Any?) -> String? {
    let string: String?
    if let value = value as? String {
      string = value
    } else if let value = value as? NSString {
      string = value as String
    } else if let value = value as? NSNumber {
      string = value.stringValue
    } else if let value = value as? Data {
      string = String(data: value, encoding: .utf8)
    } else {
      string = nil
    }

    let trimmed = string?.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed?.isEmpty == false ? trimmed : nil
  }

  // MARK: - ID3 lyrics

  private struct ID3LyricsCandidate {
    let text: String
    let priority: Int
  }

  private struct ID3SynchronizedText {
    let text: String
    let milliseconds: UInt32
  }

  private struct ID3MetadataResult {
    let version: Int
    let tags: [ID3v2Tag]
    let lyrics: String?
    let c2paProviders: [String]

    func firstValue(for frameID: String, descriptor: String? = nil) -> String? {
      tags.first { tag in
        guard tag.frameID == frameID else { return false }
        guard let descriptor else { return true }
        return tag.descriptor?.caseInsensitiveCompare(descriptor) == .orderedSame
      }?.value
    }

    func hasC2PAProvider(named expected: String) -> Bool {
      c2paProviders.contains { $0.caseInsensitiveCompare(expected) == .orderedSame }
    }
  }

  /// Reads every ID3v2.4 frame into a compact snapshot. This is intentionally
  /// internal so parser tests do not depend on AVFoundation's metadata mapping.
  static func readID3v2Tags(from url: URL) -> [ID3v2Tag] {
    guard let metadata = readID3Metadata(from: url), metadata.version == 4 else { return [] }
    return metadata.tags
  }

  static func readID3AIGeneratedFlag(from url: URL) -> Bool {
    readID3Metadata(from: url)?.hasC2PAProvider(named: "Suno, Inc.") == true
  }

  /// Reads the ID3v2.3/v2.4 USLT and SYLT layouts defined by ID3.org.
  static func readID3Lyrics(from url: URL) -> String? {
    readID3Metadata(from: url)?.lyrics
  }

  private static func readID3Metadata(from url: URL) -> ID3MetadataResult? {
    guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
    defer { try? handle.close() }

    guard let header = try? handle.read(upToCount: 10), header.count == 10,
      header.starts(with: [0x49, 0x44, 0x33])
    else { return nil }

    let version = Int(header[3])
    guard version == 3 || version == 4,
      let tagSize = synchsafeInteger(header[6..<10]),
      tagSize > 0,
      // ID3's four-byte synchsafe field permits 256 MB. Lyrics should never
      // require reading an unbounded tag into memory, even for a malformed file.
      tagSize <= 64 * 1_024 * 1_024,
      let rawBody = try? handle.read(upToCount: tagSize), rawBody.count == tagSize
    else { return nil }

    let tagFlags = header[5]
    var offset = 0
    if tagFlags & 0x40 != 0 {
      guard rawBody.count >= 4 else { return nil }
      if version == 3 {
        let extendedSize = bigEndianInteger(rawBody[0..<4])
        offset = 4 + extendedSize
      } else {
        guard let extendedSize = synchsafeInteger(rawBody[0..<4]) else { return nil }
        offset = extendedSize
      }
      guard offset >= 4, offset <= rawBody.count else { return nil }
    }

    var candidates: [ID3LyricsCandidate] = []
    var tags: [ID3v2Tag] = []
    var c2paProviders: [String] = []
    while offset + 10 <= rawBody.count {
      let idBytes = rawBody[offset..<(offset + 4)]
      guard idBytes.allSatisfy({ byte in
        (0x41...0x5A).contains(byte) || (0x30...0x39).contains(byte)
      }) else { break }

      let frameID = String(decoding: idBytes, as: UTF8.self)
      let sizeBytes = rawBody[(offset + 4)..<(offset + 8)]
      let frameSize: Int
      if version == 4 {
        guard let size = synchsafeInteger(sizeBytes) else { break }
        frameSize = size
      } else {
        frameSize = bigEndianInteger(sizeBytes)
      }

      guard frameSize > 0, frameSize <= rawBody.count - offset - 10 else { break }
      let frameFlags = UInt16(rawBody[offset + 8]) << 8 | UInt16(rawBody[offset + 9])
      let formatFlags = rawBody[offset + 9]
      var frameData = Data(rawBody[(offset + 10)..<(offset + 10 + frameSize)])
      offset += 10 + frameSize

      // Encrypted or compressed lyrics cannot be interpreted without their
      // registered transform. Skip them, as required for unknown transforms.
      if version == 3 {
        guard formatFlags & 0xC0 == 0 else { continue }
        if formatFlags & 0x20 != 0 {
          guard !frameData.isEmpty else { continue }
          frameData.removeFirst() // grouping identity
        }
        if tagFlags & 0x80 != 0 { frameData = resynchronised(frameData) }
      } else {
        guard formatFlags & 0x0C == 0 else { continue }
        if formatFlags & 0x40 != 0 {
          guard !frameData.isEmpty else { continue }
          frameData.removeFirst() // grouping identity
        }
        if formatFlags & 0x01 != 0 {
          guard frameData.count >= 4 else { continue }
          frameData.removeFirst(4) // data length indicator
        }
        if tagFlags & 0x80 != 0 || formatFlags & 0x02 != 0 {
          frameData = resynchronised(frameData)
        }
      }

      if version == 4 {
        let decoded = decodeID3v2Tag(frameID: frameID, data: frameData, flags: frameFlags)
        tags.append(decoded.tag)
        if let provider = decoded.c2paProvider { c2paProviders.append(provider) }
      }

      switch frameID {
      case "USLT":
        if let text = parseUSLT(frameData, version: version) {
          // Prefer LRC-in-USLT over plain USLT, but prefer native SYLT over both.
          candidates.append(
            ID3LyricsCandidate(text: text, priority: LRCParser.isLRCFormatted(text) ? 2 : 1)
          )
        }
      case "SYLT":
        if let text = parseSYLT(frameData, version: version) {
          candidates.append(ID3LyricsCandidate(text: text, priority: 3))
        }
      default:
        continue
      }
    }

    return ID3MetadataResult(
      version: version,
      tags: tags,
      lyrics: candidates.max { lhs, rhs in lhs.priority < rhs.priority }?.text,
      c2paProviders: c2paProviders
    )
  }

  private static func decodeID3v2Tag(
    frameID: String,
    data: Data,
    flags: UInt16
  ) -> (tag: ID3v2Tag, c2paProvider: String?) {
    func tag(
      value: String? = nil,
      descriptor: String? = nil,
      language: String? = nil,
      mimeType: String? = nil,
      fileName: String? = nil,
      binaryDataSize: Int? = nil
    ) -> ID3v2Tag {
      ID3v2Tag(
        frameID: frameID,
        value: value,
        descriptor: descriptor,
        language: language,
        mimeType: mimeType,
        fileName: fileName,
        binaryDataSize: binaryDataSize,
        flags: flags
      )
    }

    if frameID == "TXXX", data.count >= 2 {
      let encoding = data[0]
      if isSupportedID3Encoding(encoding, version: 4),
        let end = terminatedTextEnd(in: data, from: 1, encoding: encoding)
      {
        let descriptorBytes = Data(data[1..<end.contentEnd])
        let littleEndian = utf16LittleEndianHint(from: descriptorBytes)
        let descriptor = normalizedID3Text(
          decodeID3Text(descriptorBytes, encoding: encoding, fallbackLittleEndian: nil)
        )
        let value = normalizedID3Text(
          decodeID3Text(
            Data(data[end.nextOffset...]),
            encoding: encoding,
            fallbackLittleEndian: littleEndian
          )
        )
        return (tag(value: value, descriptor: descriptor), nil)
      }
    }

    if frameID.first == "T", !data.isEmpty {
      let encoding = data[0]
      if isSupportedID3Encoding(encoding, version: 4) {
        let value = normalizedID3Text(
          decodeID3Text(Data(data.dropFirst()), encoding: encoding, fallbackLittleEndian: nil)
        )
        return (tag(value: value), nil)
      }
    }

    if frameID == "WXXX", data.count >= 2 {
      let encoding = data[0]
      if isSupportedID3Encoding(encoding, version: 4),
        let end = terminatedTextEnd(in: data, from: 1, encoding: encoding)
      {
        let descriptor = normalizedID3Text(
          decodeID3Text(
            Data(data[1..<end.contentEnd]), encoding: encoding, fallbackLittleEndian: nil)
        )
        let value = normalizedID3Text(
          String(data: Data(data[end.nextOffset...]), encoding: .isoLatin1)
        )
        return (tag(value: value, descriptor: descriptor), nil)
      }
    }

    if frameID.first == "W" {
      return (tag(value: normalizedID3Text(String(data: data, encoding: .isoLatin1))), nil)
    }

    if (frameID == "COMM" || frameID == "USLT"), data.count >= 5 {
      let encoding = data[0]
      let language = String(data: Data(data[1..<4]), encoding: .isoLatin1)
      if isSupportedID3Encoding(encoding, version: 4),
        let end = terminatedTextEnd(in: data, from: 4, encoding: encoding)
      {
        let descriptorBytes = Data(data[4..<end.contentEnd])
        let littleEndian = utf16LittleEndianHint(from: descriptorBytes)
        let descriptor = normalizedID3Text(
          decodeID3Text(descriptorBytes, encoding: encoding, fallbackLittleEndian: nil)
        )
        let value = normalizedID3Text(
          decodeID3Text(
            Data(data[end.nextOffset...]),
            encoding: encoding,
            fallbackLittleEndian: littleEndian
          )
        )
        return (tag(value: value, descriptor: descriptor, language: language), nil)
      }
    }

    if frameID == "SYLT" {
      let language = data.count >= 4
        ? String(data: Data(data[1..<4]), encoding: .isoLatin1) : nil
      return (tag(value: parseSYLT(data, version: 4), language: language), nil)
    }

    if frameID == "APIC", data.count >= 4 {
      let encoding = data[0]
      if let mimeEnd = data[1...].firstIndex(of: 0), mimeEnd + 1 < data.count {
        let mimeType = String(data: Data(data[1..<mimeEnd]), encoding: .isoLatin1)
        let pictureType = data[mimeEnd + 1]
        let descriptorStart = mimeEnd + 2
        if let end = terminatedTextEnd(in: data, from: descriptorStart, encoding: encoding) {
          let descriptor = normalizedID3Text(
            decodeID3Text(
              Data(data[descriptorStart..<end.contentEnd]),
              encoding: encoding,
              fallbackLittleEndian: nil
            )
          )
          return (
            tag(
              value: id3PictureTypeName(pictureType),
              descriptor: descriptor,
              mimeType: mimeType,
              binaryDataSize: data.count - end.nextOffset
            ),
            nil
          )
        }
      }
    }

    if frameID == "GEOB", data.count >= 5 {
      let encoding = data[0]
      if let mimeEnd = data[1...].firstIndex(of: 0) {
        let mimeType = String(data: Data(data[1..<mimeEnd]), encoding: .isoLatin1)
        let fileNameStart = mimeEnd + 1
        if let fileNameEnd = terminatedTextEnd(
          in: data, from: fileNameStart, encoding: encoding
        ) {
          let fileNameBytes = Data(data[fileNameStart..<fileNameEnd.contentEnd])
          let littleEndian = utf16LittleEndianHint(from: fileNameBytes)
          let fileName = normalizedID3Text(
            decodeID3Text(fileNameBytes, encoding: encoding, fallbackLittleEndian: nil)
          )
          if let descriptorEnd = terminatedTextEnd(
            in: data, from: fileNameEnd.nextOffset, encoding: encoding
          ) {
            let descriptor = normalizedID3Text(
              decodeID3Text(
                Data(data[fileNameEnd.nextOffset..<descriptorEnd.contentEnd]),
                encoding: encoding,
                fallbackLittleEndian: littleEndian
              )
            )
            let object = Data(data[descriptorEnd.nextOffset...])
            let c2paFields = [
              "providerName", "createdAt", "systemName", "systemVersion", "contentId",
              "digitalSourceType",
            ].compactMap { key -> String? in
              cborTextValue(forKey: key, in: object).map { "\(key)=\($0)" }
            }
            let provider = cborTextValue(forKey: "providerName", in: object)
            return (
              tag(
                value: c2paFields.isEmpty ? nil : c2paFields.joined(separator: "; "),
                descriptor: descriptor,
                mimeType: mimeType,
                fileName: fileName,
                binaryDataSize: object.count
              ),
              provider
            )
          }
        }
      }
    }

    return (tag(binaryDataSize: data.count), nil)
  }

  private static func normalizedID3Text(_ text: String?) -> String? {
    let normalized = text?.replacingOccurrences(of: "\0", with: "\n")
      .trimmingCharacters(in: .whitespacesAndNewlines.union(.controlCharacters))
    return normalized?.isEmpty == false ? normalized : nil
  }

  private static func id3PictureTypeName(_ type: UInt8) -> String {
    let names = [
      "Other", "32×32 file icon", "Other file icon", "Front cover", "Back cover",
      "Leaflet", "Media", "Lead artist", "Artist", "Conductor", "Band", "Composer",
      "Lyricist", "Recording location", "During recording", "During performance",
      "Video capture", "Bright coloured fish", "Illustration", "Band logo", "Publisher logo",
    ]
    return Int(type) < names.count ? names[Int(type)] : "Picture type \(type)"
  }

  /// Finds a canonical CBOR text key followed immediately by a text value.
  /// C2PA assertion payloads use this shape for provenance fields such as
  /// providerName; no assumptions are made from free-form comments or URLs.
  private static func cborTextValue(forKey key: String, in data: Data) -> String? {
    guard let keyData = cborText(key), let range = data.range(of: keyData) else { return nil }
    return decodeCBORText(in: data, at: range.upperBound)?.value
  }

  private static func cborText(_ value: String) -> Data? {
    let bytes = Data(value.utf8)
    guard bytes.count <= UInt32.max else { return nil }
    var result = Data()
    switch bytes.count {
    case 0...23:
      result.append(UInt8(0x60 + bytes.count))
    case 24...255:
      result.append(0x78)
      result.append(UInt8(bytes.count))
    case 256...65_535:
      result.append(0x79)
      result.append(UInt8((bytes.count >> 8) & 0xFF))
      result.append(UInt8(bytes.count & 0xFF))
    default:
      result.append(0x7A)
      result.append(contentsOf: bigEndianBytes32(UInt32(bytes.count)))
    }
    result.append(bytes)
    return result
  }

  private static func decodeCBORText(in data: Data, at offset: Int) -> (value: String, end: Int)? {
    guard offset < data.count else { return nil }
    let initial = data[offset]
    guard initial >> 5 == 3 else { return nil }
    let additional = initial & 0x1F
    let length: Int
    let payloadStart: Int
    switch additional {
    case 0...23:
      length = Int(additional)
      payloadStart = offset + 1
    case 24:
      guard offset + 1 < data.count else { return nil }
      length = Int(data[offset + 1])
      payloadStart = offset + 2
    case 25:
      guard offset + 2 < data.count else { return nil }
      length = Int(data[offset + 1]) << 8 | Int(data[offset + 2])
      payloadStart = offset + 3
    case 26:
      guard offset + 4 < data.count else { return nil }
      length = bigEndianInteger(data[(offset + 1)...(offset + 4)])
      payloadStart = offset + 5
    default:
      return nil
    }
    guard length <= data.count - payloadStart,
      let value = String(data: Data(data[payloadStart..<(payloadStart + length)]), encoding: .utf8)
    else { return nil }
    return (value, payloadStart + length)
  }

  private static func bigEndianBytes32(_ value: UInt32) -> [UInt8] {
    [
      UInt8((value >> 24) & 0xFF), UInt8((value >> 16) & 0xFF),
      UInt8((value >> 8) & 0xFF), UInt8(value & 0xFF),
    ]
  }

  private static func parseUSLT(_ data: Data, version: Int) -> String? {
    guard data.count >= 5 else { return nil }
    let encoding = data[0]
    guard isSupportedID3Encoding(encoding, version: version),
      let descriptorEnd = terminatedTextEnd(in: data, from: 4, encoding: encoding)
    else { return nil }

    let descriptorBytes = Data(data[4..<descriptorEnd.contentEnd])
    let lyricsBytes = Data(data[descriptorEnd.nextOffset...])
    let fallbackByteOrder = utf16LittleEndianHint(from: descriptorBytes)
    guard let decoded = decodeID3Text(
      lyricsBytes,
      encoding: encoding,
      fallbackLittleEndian: fallbackByteOrder
    ) else { return nil }
    return cleanLyricsText(decoded)
  }

  private static func parseSYLT(_ data: Data, version: Int) -> String? {
    guard data.count >= 7 else { return nil }
    let encoding = data[0]
    let timestampFormat = data[4]
    let contentType = data[5]
    guard isSupportedID3Encoding(encoding, version: version),
      timestampFormat == 0x02, // milliseconds; MPEG-frame timestamps need the audio timebase
      contentType <= 0x02,
      let descriptorEnd = terminatedTextEnd(in: data, from: 6, encoding: encoding)
    else { return nil }

    let descriptorBytes = Data(data[6..<descriptorEnd.contentEnd])
    let fallbackByteOrder = utf16LittleEndianHint(from: descriptorBytes)
    var cursor = descriptorEnd.nextOffset
    var entries: [ID3SynchronizedText] = []

    while cursor < data.count {
      guard let textEnd = terminatedTextEnd(in: data, from: cursor, encoding: encoding),
        textEnd.nextOffset + 4 <= data.count
      else { break }

      let textBytes = Data(data[cursor..<textEnd.contentEnd])
      guard let decoded = decodeID3Text(
        textBytes,
        encoding: encoding,
        fallbackLittleEndian: fallbackByteOrder
      ) else { break }

      let timestamp = UInt32(bigEndianInteger(data[textEnd.nextOffset..<(textEnd.nextOffset + 4)]))
      if !decoded.isEmpty {
        entries.append(ID3SynchronizedText(text: decoded, milliseconds: timestamp))
      }
      cursor = textEnd.nextOffset + 4
    }

    guard !entries.isEmpty else { return nil }
    return syltAsLRC(entries)
  }

  private static func syltAsLRC(_ entries: [ID3SynchronizedText]) -> String {
    let carriesLineBreaks = entries.contains { $0.text.contains("\n") || $0.text.contains("\r") }
    if !carriesLineBreaks {
      return entries.map { "[\(lrcTimestamp($0.milliseconds))]\($0.text)" }
        .joined(separator: "\n")
    }

    var lines: [String] = []
    var line = ""
    var lineTimestamp: UInt32?

    func flushLine() {
      guard let timestamp = lineTimestamp else { return }
      let text = line.trimmingCharacters(in: .whitespaces)
      if !text.isEmpty { lines.append("[\(lrcTimestamp(timestamp))]\(line)") }
      line = ""
      lineTimestamp = nil
    }

    for entry in entries {
      let normalized = entry.text.replacingOccurrences(of: "\r\n", with: "\n")
        .replacingOccurrences(of: "\r", with: "\n")
      let parts = normalized.split(separator: "\n", omittingEmptySubsequences: false)
      for (index, part) in parts.enumerated() {
        if !part.isEmpty {
          if lineTimestamp == nil { lineTimestamp = entry.milliseconds }
          line += "<\(lrcTimestamp(entry.milliseconds))>\(part)"
        }
        if index < parts.count - 1 { flushLine() }
      }
    }
    flushLine()
    return lines.joined(separator: "\n")
  }

  private static func lrcTimestamp(_ milliseconds: UInt32) -> String {
    let minutes = milliseconds / 60_000
    let seconds = (milliseconds / 1_000) % 60
    let remainder = milliseconds % 1_000
    return String(format: "%02u:%02u.%03u", minutes, seconds, remainder)
  }

  private static func cleanLyricsText(_ text: String) -> String? {
    let cleaned = text.trimmingCharacters(
      in: .whitespacesAndNewlines.union(.controlCharacters)
    )
    return cleaned.isEmpty ? nil : cleaned
  }

  private static func isSupportedID3Encoding(_ encoding: UInt8, version: Int) -> Bool {
    encoding <= (version == 3 ? 1 : 3)
  }

  private static func terminatedTextEnd(
    in data: Data,
    from start: Int,
    encoding: UInt8
  ) -> (contentEnd: Int, nextOffset: Int)? {
    guard start >= 0, start <= data.count else { return nil }
    if encoding == 0 || encoding == 3 {
      guard let end = data[start...].firstIndex(of: 0) else { return nil }
      return (end, end + 1)
    }

    guard start + 1 < data.count else { return nil }
    var cursor = start
    while cursor + 1 < data.count {
      if data[cursor] == 0, data[cursor + 1] == 0 {
        return (cursor, cursor + 2)
      }
      cursor += 2
    }
    return nil
  }

  private static func decodeID3Text(
    _ data: Data,
    encoding: UInt8,
    fallbackLittleEndian: Bool?
  ) -> String? {
    let value: String?
    switch encoding {
    case 0:
      value = String(data: data, encoding: .isoLatin1)
    case 1:
      if data.starts(with: [0xFF, 0xFE]) || data.starts(with: [0xFE, 0xFF]) {
        value = String(data: data, encoding: .utf16)
      } else if fallbackLittleEndian == true {
        value = String(data: data, encoding: .utf16LittleEndian)
      } else {
        value = String(data: data, encoding: .utf16BigEndian)
      }
    case 2:
      value = String(data: data, encoding: .utf16BigEndian)
    case 3:
      value = String(data: data, encoding: .utf8)
    default:
      value = nil
    }
    return value?.trimmingCharacters(in: .init(charactersIn: "\0"))
  }

  private static func utf16LittleEndianHint(from data: Data) -> Bool? {
    if data.starts(with: [0xFF, 0xFE]) { return true }
    if data.starts(with: [0xFE, 0xFF]) { return false }
    return nil
  }

  private static func resynchronised(_ data: Data) -> Data {
    var result = Data()
    result.reserveCapacity(data.count)
    var index = 0
    while index < data.count {
      let byte = data[index]
      result.append(byte)
      if byte == 0xFF, index + 1 < data.count, data[index + 1] == 0x00 {
        index += 1
      }
      index += 1
    }
    return result
  }

  private static func synchsafeInteger(_ bytes: Data.SubSequence) -> Int? {
    guard bytes.count == 4, bytes.allSatisfy({ $0 & 0x80 == 0 }) else { return nil }
    return bytes.reduce(0) { ($0 << 7) | Int($1) }
  }

  private static func bigEndianInteger(_ bytes: Data.SubSequence) -> Int {
    bytes.reduce(0) { ($0 << 8) | Int($1) }
  }

  private struct FLACMetadata {
    var comments: [String: [String]] = [:]
    var artwork: Data?
    var artworkPriority = -1
  }

  /// Parses only FLAC metadata blocks; audio frames are never read or copied.
  ///
  /// A few tag editors write a complete ID3v2 tag in front of the native FLAC
  /// stream. Although that layout is non-standard, players such as mpv and
  /// ffmpeg accept it. Locate the native marker after the ID3 tag so those
  /// files still get their Vorbis comments and PICTURE block imported.
  private static func readFLACMetadata(from url: URL) -> FLACMetadata? {
    guard let data = try? Data(contentsOf: url, options: .mappedIfSafe),
      data.count >= 8
    else { return nil }

    let flacMarker = Data("fLaC".utf8)

    func hasFLACMarker(at offset: Int) -> Bool {
      guard offset >= 0, offset + flacMarker.count <= data.count else { return false }
      return data[offset..<(offset + flacMarker.count)].elementsEqual(flacMarker)
    }

    let flacOffset: Int
    if hasFLACMarker(at: 0) {
      flacOffset = 0
    } else if data.count >= 10,
      data[0] == 0x49, data[1] == 0x44, data[2] == 0x33,
      data[6] & 0x80 == 0, data[7] & 0x80 == 0,
      data[8] & 0x80 == 0, data[9] & 0x80 == 0
    {
      // ID3 sizes are four 7-bit, big-endian (synchsafe) bytes and exclude
      // the ten-byte header. Some writers also append the optional footer.
      let id3PayloadSize =
        (Int(data[6]) << 21)
        | (Int(data[7]) << 14)
        | (Int(data[8]) << 7)
        | Int(data[9])
      let expectedOffset = 10 + id3PayloadSize
      let footerOffset = expectedOffset + ((data[5] & 0x10) != 0 ? 10 : 0)

      if hasFLACMarker(at: footerOffset) {
        flacOffset = footerOffset
      } else if hasFLACMarker(at: expectedOffset) {
        flacOffset = expectedOffset
      } else {
        // Tolerate a small amount of padding after the declared tag, but do
        // not scan the audio payload where marker-like bytes could be data.
        let searchEnd = min(data.count - flacMarker.count, footerOffset + 4096)
        var locatedOffset: Int?
        if footerOffset <= searchEnd {
          for candidate in footerOffset...searchEnd where hasFLACMarker(at: candidate) {
            locatedOffset = candidate
            break
          }
        }
        guard let locatedOffset else { return nil }
        flacOffset = locatedOffset
      }
    } else {
      return nil
    }

    func uint32(_ offset: Int, littleEndian: Bool = false) -> Int? {
      guard offset >= 0, offset + 4 <= data.count else { return nil }
      let bytes = data[offset..<(offset + 4)]
      if littleEndian {
        return bytes.enumerated().reduce(0) { $0 | (Int($1.element) << ($1.offset * 8)) }
      }
      return bytes.reduce(0) { ($0 << 8) | Int($1) }
    }

    var result = FLACMetadata()
    var offset = flacOffset + flacMarker.count
    var isLast = false

    while !isLast, offset + 4 <= data.count {
      let header = data[offset]
      isLast = header & 0x80 != 0
      let type = header & 0x7f
      let length = (Int(data[offset + 1]) << 16) | (Int(data[offset + 2]) << 8) | Int(data[offset + 3])
      let blockStart = offset + 4
      let blockEnd = blockStart + length
      guard blockEnd <= data.count else { break }

      if type == 4 { // VORBIS_COMMENT
        var cursor = blockStart
        if let vendorLength = uint32(cursor, littleEndian: true),
          cursor + 4 + vendorLength <= blockEnd
        {
          cursor += 4 + vendorLength
          if cursor + 4 <= blockEnd, let count = uint32(cursor, littleEndian: true) {
            cursor += 4
            for _ in 0..<min(count, (blockEnd - cursor) / 4) {
              guard let itemLength = uint32(cursor, littleEndian: true) else { break }
              cursor += 4
              guard itemLength >= 0, cursor + itemLength <= blockEnd else { break }
              if let entry = String(data: data[cursor..<(cursor + itemLength)], encoding: .utf8),
                let equals = entry.firstIndex(of: "=")
              {
                let key = String(entry[..<equals]).uppercased()
                let value = String(entry[entry.index(after: equals)...])
                  .trimmingCharacters(in: .whitespacesAndNewlines)
                if !value.isEmpty { result.comments[key, default: []].append(value) }
              }
              cursor += itemLength
            }
          }
        }
      } else if type == 6, let pictureType = uint32(blockStart) { // PICTURE
        // Prefer a front cover (type 3), then an unspecified/other image.
        let priority = pictureType == 3 ? 2 : (pictureType == 0 ? 1 : 0)
        var cursor = blockStart + 4
        if priority > result.artworkPriority, let mimeLength = uint32(cursor),
          cursor + 4 + mimeLength <= blockEnd
        {
          cursor += 4 + mimeLength
          if cursor + 4 <= blockEnd, let descriptionLength = uint32(cursor),
            cursor + 4 + descriptionLength + 16 <= blockEnd
          {
            cursor += 4 + descriptionLength + 16 // dimensions, depth, palette count
            if cursor + 4 <= blockEnd, let imageLength = uint32(cursor) {
              cursor += 4
              if imageLength > 0, cursor + imageLength <= blockEnd {
                result.artwork = Data(data[cursor..<(cursor + imageLength)])
                result.artworkPriority = priority
              }
            }
          }
        }
      }

      offset = blockEnd
    }

    return result
  }

  /// Parses a ReplayGain value, which tags store as `"-6.54 dB"`, `"+3.20 dB"`
  /// or a bare number. Returns decibels relative to the tag's reference level.
  private static func parseReplayGain(_ value: Any?) -> Double? {
    guard let raw = stringValue(value) else { return nil }

    let cleaned =
      raw
      .replacingOccurrences(of: "dB", with: "", options: [.caseInsensitive])
      .trimmingCharacters(in: .whitespacesAndNewlines)

    guard let gain = Double(cleaned), gain.isFinite else { return nil }
    // Real-world tags sit within roughly ±30 dB; anything wilder is a bad tag.
    guard gain > -30, gain < 30 else { return nil }
    return gain
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
