//
//  ZipArchive.swift
//  Ampwave
//
//  Minimal streaming ZIP32 container backed by Apple's native DEFLATE codec.
//

import Compression
import Foundation

nonisolated enum ZipArchive {
  struct Source: Sendable {
    let path: String
    let fileURL: URL?
    let data: Data?

    init(path: String, fileURL: URL) {
      self.path = path
      self.fileURL = fileURL
      self.data = nil
    }

    init(path: String, data: Data) {
      self.path = path
      self.fileURL = nil
      self.data = data
    }
  }

  private struct CentralEntry {
    let path: String
    let crc32: UInt32
    let compressedSize: UInt32
    let uncompressedSize: UInt32
    let localHeaderOffset: UInt32
    let modificationTime: UInt16
    let modificationDate: UInt16
  }

  private static let utf8AndDescriptorFlags: UInt16 = 0x0808
  private static let deflateMethod: UInt16 = 8
  private static let chunkSize = 256 * 1024

  static func create(at archiveURL: URL, sources: [Source]) throws {
    guard !sources.isEmpty else { throw archiveError("The Capsule has no files to archive.") }
    try? FileManager.default.removeItem(at: archiveURL)
    guard FileManager.default.createFile(atPath: archiveURL.path, contents: nil) else {
      throw archiveError("Could not create the Capsule archive.")
    }

    let output = try FileHandle(forWritingTo: archiveURL)
    defer { try? output.close() }
    var entries: [CentralEntry] = []

    for source in sources {
      entries.append(try write(source, to: output))
    }

    let centralDirectoryOffset = try zip32Offset(output.offsetInFile)
    for entry in entries {
      try writeCentralDirectoryEntry(entry, to: output)
    }
    let centralDirectorySize = try zip32Offset(output.offsetInFile - UInt64(centralDirectoryOffset))
    guard entries.count <= Int(UInt16.max) else {
      throw archiveError("This Capsule contains too many files for the current format.")
    }

    var end = Data()
    end.appendLE(UInt32(0x06054B50))
    end.appendLE(UInt16(0))
    end.appendLE(UInt16(0))
    end.appendLE(UInt16(entries.count))
    end.appendLE(UInt16(entries.count))
    end.appendLE(centralDirectorySize)
    end.appendLE(centralDirectoryOffset)
    end.appendLE(UInt16(0))
    try output.write(contentsOf: end)
  }

  static func extract(archiveURL: URL, to destinationURL: URL) throws {
    try FileManager.default.createDirectory(
      at: destinationURL,
      withIntermediateDirectories: true
    )
    let input = try FileHandle(forReadingFrom: archiveURL)
    defer { try? input.close() }

    let entries = try readCentralDirectory(from: input)
    for entry in entries {
      guard isSafeArchivePath(entry.path) else {
        throw archiveError("The Capsule contains an unsafe file path.")
      }
      let outputURL = destinationURL.appendingPathComponent(entry.path)
      try FileManager.default.createDirectory(
        at: outputURL.deletingLastPathComponent(),
        withIntermediateDirectories: true
      )
      try extract(entry, from: input, to: outputURL)
    }
  }

  private static func write(_ source: Source, to output: FileHandle) throws -> CentralEntry {
    let nameData = Data(source.path.utf8)
    guard nameData.count <= Int(UInt16.max), isSafeArchivePath(source.path) else {
      throw archiveError("A Capsule filename is invalid.")
    }

    let (dosTime, dosDate) = dosTimestamp(.now)
    let localOffset = try zip32Offset(output.offsetInFile)
    var header = Data()
    header.appendLE(UInt32(0x04034B50))
    header.appendLE(UInt16(20))
    header.appendLE(utf8AndDescriptorFlags)
    header.appendLE(deflateMethod)
    header.appendLE(dosTime)
    header.appendLE(dosDate)
    header.appendLE(UInt32(0))
    header.appendLE(UInt32(0))
    header.appendLE(UInt32(0))
    header.appendLE(UInt16(nameData.count))
    header.appendLE(UInt16(0))
    header.append(nameData)
    try output.write(contentsOf: header)

    var compressedByteCount: UInt64 = 0
    var uncompressedByteCount: UInt64 = 0
    var crc = CRC32()
    let filter = try OutputFilter(.compress, using: .zlib) { data in
      guard let data, !data.isEmpty else { return }
      try output.write(contentsOf: data)
      compressedByteCount += UInt64(data.count)
    }

    if let data = source.data {
      var offset = 0
      while offset < data.count {
        let end = min(offset + chunkSize, data.count)
        let chunk = data[offset..<end]
        crc.update(chunk)
        uncompressedByteCount += UInt64(chunk.count)
        try filter.write(chunk)
        offset = end
      }
    } else if let fileURL = source.fileURL {
      let secured = fileURL.startAccessingSecurityScopedResource()
      defer { if secured { fileURL.stopAccessingSecurityScopedResource() } }
      let input = try FileHandle(forReadingFrom: fileURL)
      defer { try? input.close() }
      while let chunk = try input.read(upToCount: chunkSize), !chunk.isEmpty {
        crc.update(chunk)
        uncompressedByteCount += UInt64(chunk.count)
        try filter.write(chunk)
      }
    } else {
      throw archiveError("A Capsule file could not be read.")
    }
    try filter.finalize()

    let compressedSize = try zip32Offset(compressedByteCount)
    let uncompressedSize = try zip32Offset(uncompressedByteCount)
    var descriptor = Data()
    descriptor.appendLE(UInt32(0x08074B50))
    descriptor.appendLE(crc.finalized)
    descriptor.appendLE(compressedSize)
    descriptor.appendLE(uncompressedSize)
    try output.write(contentsOf: descriptor)

    return CentralEntry(
      path: source.path,
      crc32: crc.finalized,
      compressedSize: compressedSize,
      uncompressedSize: uncompressedSize,
      localHeaderOffset: localOffset,
      modificationTime: dosTime,
      modificationDate: dosDate
    )
  }

  private static func writeCentralDirectoryEntry(
    _ entry: CentralEntry,
    to output: FileHandle
  ) throws {
    let nameData = Data(entry.path.utf8)
    var data = Data()
    data.appendLE(UInt32(0x02014B50))
    data.appendLE(UInt16(20))
    data.appendLE(UInt16(20))
    data.appendLE(utf8AndDescriptorFlags)
    data.appendLE(deflateMethod)
    data.appendLE(entry.modificationTime)
    data.appendLE(entry.modificationDate)
    data.appendLE(entry.crc32)
    data.appendLE(entry.compressedSize)
    data.appendLE(entry.uncompressedSize)
    data.appendLE(UInt16(nameData.count))
    data.appendLE(UInt16(0))
    data.appendLE(UInt16(0))
    data.appendLE(UInt16(0))
    data.appendLE(UInt16(0))
    data.appendLE(UInt32(0))
    data.appendLE(entry.localHeaderOffset)
    data.append(nameData)
    try output.write(contentsOf: data)
  }

  private static func readCentralDirectory(from input: FileHandle) throws -> [CentralEntry] {
    let fileSize = input.seekToEndOfFile()
    let tailSize = min(fileSize, UInt64(UInt16.max) + 22)
    try input.seek(toOffset: fileSize - tailSize)
    let tail = try input.readToEnd() ?? Data()
    guard let endIndex = tail.lastIndex(ofSignature: 0x06054B50) else {
      throw archiveError("This file is not a valid Ampwave Capsule.")
    }

    let entryCount = Int(try tail.readLEUInt16(at: endIndex + 10))
    let directoryOffset = UInt64(try tail.readLEUInt32(at: endIndex + 16))
    try input.seek(toOffset: directoryOffset)

    var entries: [CentralEntry] = []
    for _ in 0..<entryCount {
      let fixed = try readExactly(46, from: input)
      guard try fixed.readLEUInt32(at: 0) == 0x02014B50 else {
        throw archiveError("The Capsule directory is damaged.")
      }
      let method = try fixed.readLEUInt16(at: 10)
      guard method == deflateMethod || method == 0 else {
        throw archiveError("The Capsule uses an unsupported compression method.")
      }
      let nameLength = Int(try fixed.readLEUInt16(at: 28))
      let extraLength = Int(try fixed.readLEUInt16(at: 30))
      let commentLength = Int(try fixed.readLEUInt16(at: 32))
      let nameData = try readExactly(nameLength, from: input)
      guard let path = String(data: nameData, encoding: .utf8) else {
        throw archiveError("The Capsule contains an invalid filename.")
      }
      if extraLength + commentLength > 0 {
        _ = try readExactly(extraLength + commentLength, from: input)
      }
      entries.append(
        CentralEntry(
          path: path,
          crc32: try fixed.readLEUInt32(at: 16),
          compressedSize: try fixed.readLEUInt32(at: 20),
          uncompressedSize: try fixed.readLEUInt32(at: 24),
          localHeaderOffset: try fixed.readLEUInt32(at: 42),
          modificationTime: method,
          modificationDate: 0
        )
      )
    }
    return entries
  }

  private static func extract(
    _ entry: CentralEntry,
    from input: FileHandle,
    to outputURL: URL
  ) throws {
    try input.seek(toOffset: UInt64(entry.localHeaderOffset))
    let header = try readExactly(30, from: input)
    guard try header.readLEUInt32(at: 0) == 0x04034B50 else {
      throw archiveError("A Capsule entry is damaged.")
    }
    let method = try header.readLEUInt16(at: 8)
    let nameLength = Int(try header.readLEUInt16(at: 26))
    let extraLength = Int(try header.readLEUInt16(at: 28))
    _ = try readExactly(nameLength + extraLength, from: input)

    guard FileManager.default.createFile(atPath: outputURL.path, contents: nil) else {
      throw archiveError("Could not extract a Capsule file.")
    }
    let output = try FileHandle(forWritingTo: outputURL)
    defer { try? output.close() }
    var remaining = Int(entry.compressedSize)
    var crc = CRC32()

    if method == 0 {
      while remaining > 0 {
        let chunk = try readExactly(min(chunkSize, remaining), from: input)
        crc.update(chunk)
        try output.write(contentsOf: chunk)
        remaining -= chunk.count
      }
    } else {
      let filter = try OutputFilter(.decompress, using: .zlib) { data in
        guard let data, !data.isEmpty else { return }
        crc.update(data)
        try output.write(contentsOf: data)
      }
      while remaining > 0 {
        let chunk = try readExactly(min(chunkSize, remaining), from: input)
        try filter.write(chunk)
        remaining -= chunk.count
      }
      try filter.finalize()
    }

    guard crc.finalized == entry.crc32 else {
      throw archiveError("A Capsule audio file failed its integrity check.")
    }
  }

  private static func readExactly(_ count: Int, from handle: FileHandle) throws -> Data {
    guard count >= 0, let data = try handle.read(upToCount: count), data.count == count else {
      throw archiveError("The Capsule ended unexpectedly.")
    }
    return data
  }

  private static func zip32Offset(_ value: UInt64) throws -> UInt32 {
    guard value <= UInt64(UInt32.max) else {
      throw archiveError("This Capsule is larger than the current 4 GB archive limit.")
    }
    return UInt32(value)
  }

  private static func isSafeArchivePath(_ path: String) -> Bool {
    !path.isEmpty
      && !path.hasPrefix("/")
      && !path.hasPrefix("\\")
      && !path.split(separator: "/").contains("..")
  }

  private static func dosTimestamp(_ date: Date) -> (UInt16, UInt16) {
    let components = Calendar(identifier: .gregorian).dateComponents(
      in: .current,
      from: date
    )
    let year = min(max(components.year ?? 1980, 1980), 2107)
    let month = min(max(components.month ?? 1, 1), 12)
    let day = min(max(components.day ?? 1, 1), 31)
    let hour = min(max(components.hour ?? 0, 0), 23)
    let minute = min(max(components.minute ?? 0, 0), 59)
    let second = min(max(components.second ?? 0, 0), 59)
    let time = UInt16((hour << 11) | (minute << 5) | (second / 2))
    let date = UInt16(((year - 1980) << 9) | (month << 5) | day)
    return (time, date)
  }

  private static func archiveError(_ message: String) -> NSError {
    NSError(
      domain: "com.ampwave.zip",
      code: 1,
      userInfo: [NSLocalizedDescriptionKey: message]
    )
  }
}

nonisolated private struct CRC32 {
  private static let table: [UInt32] = (0..<256).map { value in
    var crc = UInt32(value)
    for _ in 0..<8 {
      crc = (crc & 1) == 1 ? (crc >> 1) ^ 0xEDB88320 : crc >> 1
    }
    return crc
  }

  private var value: UInt32 = 0xFFFF_FFFF

  mutating func update<D: DataProtocol>(_ data: D) {
    for byte in data {
      let index = Int((value ^ UInt32(byte)) & 0xFF)
      value = Self.table[index] ^ (value >> 8)
    }
  }

  var finalized: UInt32 { value ^ 0xFFFF_FFFF }
}

nonisolated private extension Data {
  mutating func appendLE<T: FixedWidthInteger>(_ value: T) {
    var littleEndian = value.littleEndian
    Swift.withUnsafeBytes(of: &littleEndian) { append(contentsOf: $0) }
  }

  func readLEUInt16(at offset: Int) throws -> UInt16 {
    guard offset >= 0, offset + 2 <= count else { throw dataError }
    return UInt16(self[offset]) | (UInt16(self[offset + 1]) << 8)
  }

  func readLEUInt32(at offset: Int) throws -> UInt32 {
    guard offset >= 0, offset + 4 <= count else { throw dataError }
    return UInt32(self[offset])
      | (UInt32(self[offset + 1]) << 8)
      | (UInt32(self[offset + 2]) << 16)
      | (UInt32(self[offset + 3]) << 24)
  }

  func lastIndex(ofSignature signature: UInt32) -> Int? {
    guard count >= 4 else { return nil }
    for index in stride(from: count - 4, through: 0, by: -1) {
      if (try? readLEUInt32(at: index)) == signature { return index }
    }
    return nil
  }

  private var dataError: NSError {
    NSError(
      domain: "com.ampwave.zip",
      code: 2,
      userInfo: [NSLocalizedDescriptionKey: "The Capsule archive is truncated."]
    )
  }
}

