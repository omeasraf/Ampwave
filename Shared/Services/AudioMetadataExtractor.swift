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

    for item in allMetadata {
      let value = try? await item.load(.value)
      let idRaw = item.identifier?.rawValue ?? ""
      let idLower = idRaw.lowercased()

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
            if let num = value as? NSNumber { trackNumber = num.intValue }
            else if let str = value as? String { trackNumber = parseTrackNumber(str) }
            continue
          case .id3MetadataPartOfASet, .iTunesMetadataDiscNumber:
            if let num = value as? NSNumber { discNumber = num.intValue }
            else if let str = value as? String { discNumber = parseTrackNumber(str) }
            continue
          case .id3MetadataYear, .id3MetadataRecordingTime, .id3MetadataOriginalReleaseYear,
            .iTunesMetadataReleaseDate, .quickTimeMetadataYear:
            if let num = value as? NSNumber { year = num.intValue }
            else if let str = value as? String { year = parseYear(str) }
            continue
          case .iTunesMetadataContentRating:
            if let num = value as? NSNumber { isExplicit = num.intValue != 0 }
            else if let str = value as? String {
              let normalized = str.lowercased()
              isExplicit = !(normalized == "clean" || normalized == "0" || normalized.isEmpty)
            }
            continue
          case .iTunesMetadataDiscCompilation:
            if let num = value as? NSNumber { isCompilation = num.boolValue }
            else if let str = value as? String { isCompilation = (str == "1" || str.lowercased() == "true") }
            continue
          default:
            break
          }
        }

        if idRaw.contains("lyrics") || idRaw.contains("Lyrics") { lyrics = (value as? String) ?? lyrics }
        else if idRaw.contains("comment") || idRaw.contains("Comment") || idRaw.contains("description") { songDescription = (value as? String) ?? songDescription }
        else if idLower.contains("advisory") || idLower.contains("explicit") {
          if let num = value as? NSNumber { isExplicit = num.intValue != 0 }
          else if let str = value as? String {
            let normalized = str.lowercased()
            isExplicit = (normalized == "1" || normalized == "true" || normalized == "explicit")
          }
        }
        else if idRaw.contains("year") || idRaw.contains("Year") || idRaw.contains("date") || idRaw.contains("Date") {
          if let num = value as? NSNumber { year = num.intValue }
          else if let str = value as? String { year = parseYear(str) }
        }
        else if (idRaw.contains("track") || idRaw.contains("Track")) && !idRaw.contains("artist") {
          if let num = value as? NSNumber { trackNumber = num.intValue }
          else if let str = value as? String { trackNumber = parseTrackNumber(str) }
        }
        else if idRaw.contains("disc") || idRaw.contains("Disc") { discNumber = (value as? NSNumber)?.intValue ?? discNumber }
        // Compilation flag: ID3 TCMP, iTunes cpil
        else if idRaw.contains("TCMP") || idRaw.contains("cpil") || idLower.contains("compilation") {
          if let num = value as? NSNumber { isCompilation = num.boolValue }
          else if let str = value as? String { isCompilation = (str == "1" || str.lowercased() == "true") }
        }
        // Album Artist:
        // • ID3 MP3  → TPE2  (Band/Orchestra — de-facto Album Artist)
        // • iTunes/M4A → aART (album artist atom)
        // • FLAC/Ogg → ALBUMARTIST as a TXXX user-defined frame
        else if idRaw.contains("TPE2") || idRaw.contains("aART")
             || idLower.contains("albumartist") || idLower.contains("album artist")
             || idLower.contains("album_artist") {
          if let v = value as? String, !v.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            albumArtist = v
          }
        }
        continue
      }

      // ── Common-key path ────────────────────────────────────────────────────
      let raw = key.rawValue.lowercased()
      if raw == "title" || raw.contains("title") { if let v = value as? String, !v.isEmpty { embeddedTitle = v } }
      else if raw == "artist" || raw.contains("artist"), !raw.contains("album") { if let v = value as? String, !v.isEmpty { embeddedArtist = v } }
      else if raw.contains("albumname") || raw == "album" { album = (value as? String) ?? album }
      else if raw.contains("lyrics") || raw == "lyr" { lyrics = (value as? String) ?? lyrics }
      else if raw == "type" || raw.contains("genre") { genre = (value as? String) ?? genre }
      else if raw.contains("creator") || raw.contains("composer") { composer = (value as? String) ?? composer }
      else if raw.contains("artwork") || raw.contains("art") { artwork = value as? Data ?? artwork }
      // Some encoders surface albumArtist through a common-key variant
      else if raw.contains("albumartist") || raw.contains("album artist") {
        if let v = value as? String, !v.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
          albumArtist = v
        }
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

  /// Parses "5", "5/12" -> 5
  private static func parseTrackNumber(_ s: String) -> Int? {
    let part = s.split(separator: "/").first.flatMap(String.init) ?? s
    return Int(part.trimmingCharacters(in: .whitespaces))
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
