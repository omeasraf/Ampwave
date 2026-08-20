//
//  AudioMetadataExtractor.swift
//  Ampwave
//
//  Extracts metadata from audio files using AVFoundation.
//

import AVFoundation
import Foundation

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
    var replayGainDB: Double?

    for item in allMetadata {
      let value = try? await item.load(.value)
      let idRaw = item.identifier?.rawValue ?? ""
      let idLower = idRaw.lowercased()
      // FLAC/Ogg carry ReplayGain as a Vorbis comment and MP3 as a TXXX frame;
      // in both cases the tag name lands on `key` rather than the identifier.
      let keyLower = (stringValue(item.key) ?? "").lowercased()

      if replayGainDB == nil,
        idLower.contains("replaygain") || keyLower.contains("replaygain"),
        keyLower.contains("track") || idLower.contains("track") || keyLower.isEmpty,
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
        else if idRaw.contains("comment") || idRaw.contains("Comment") || idRaw.contains("description") { songDescription = stringValue(value) ?? songDescription }
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
             || keyLower.contains("album artist") || keyLower.contains("album_artist") {
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

  private struct FLACMetadata {
    var comments: [String: [String]] = [:]
    var artwork: Data?
    var artworkPriority = -1
  }

  /// Parses only FLAC metadata blocks; audio frames are never read or copied.
  private static func readFLACMetadata(from url: URL) -> FLACMetadata? {
    guard let data = try? Data(contentsOf: url, options: .mappedIfSafe),
      data.count >= 8, data.prefix(4) == Data("fLaC".utf8)
    else { return nil }

    func uint32(_ offset: Int, littleEndian: Bool = false) -> Int? {
      guard offset >= 0, offset + 4 <= data.count else { return nil }
      let bytes = data[offset..<(offset + 4)]
      if littleEndian {
        return bytes.enumerated().reduce(0) { $0 | (Int($1.element) << ($1.offset * 8)) }
      }
      return bytes.reduce(0) { ($0 << 8) | Int($1) }
    }

    var result = FLACMetadata()
    var offset = 4
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
