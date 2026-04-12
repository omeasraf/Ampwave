//
//  CoverArtArchive.swift
//  Ampwave
//

import Foundation

struct CoverArtArchiveResponse: Codable {
  let images: [CoverArtImage]
}

struct CoverArtImage: Codable {
  let id: Int64
  let types: [String]
  let image: CoverArtURL
  let thumbnails: CoverArtThumbnails

  enum CodingKeys: String, CodingKey {
    case id, types, image, thumbnails
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)

    // Handle id as either String or Int64
    if let idInt = try? container.decode(Int64.self, forKey: .id) {
      self.id = idInt
    } else if let idString = try? container.decode(String.self, forKey: .id) {
      self.id = Int64(idString) ?? 0
    } else {
      self.id = 0
    }

    self.types = try container.decode([String].self, forKey: .types)
    self.image = try container.decode(CoverArtURL.self, forKey: .image)
    self.thumbnails = try container.decode(CoverArtThumbnails.self, forKey: .thumbnails)
  }
}

struct CoverArtURL: Codable {
  let url: URL
  let width: Int?
  let height: Int?

  enum CodingKeys: String, CodingKey {
    case url, width, height
  }

  init(from decoder: Decoder) throws {
    // Handle image as either a String (URL) or an Object with url/width/height
    if let singleValueURL = try? decoder.singleValueContainer().decode(URL.self) {
      self.url = singleValueURL
      self.width = nil
      self.height = nil
    } else {
      let container = try decoder.container(keyedBy: CodingKeys.self)
      self.url = try container.decode(URL.self, forKey: .url)
      self.width = try? container.decode(Int.self, forKey: .width)
      self.height = try? container.decode(Int.self, forKey: .height)
    }
  }
}

struct CoverArtThumbnails: Codable {
  let small: URL?
  let large: URL?
  let thumb250: URL?
  let thumb500: URL?
  let thumb1200: URL?

  enum CodingKeys: String, CodingKey {
    case small, large
    case thumb250 = "250"
    case thumb500 = "500"
    case thumb1200 = "1200"
  }
}
