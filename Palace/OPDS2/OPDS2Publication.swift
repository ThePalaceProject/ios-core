//
//  OPDS2Publication.swift
//  The Palace Project
//
//  Created by Benjamin Anderman on 5/10/19.
//  Copyright © 2019 NYPL Labs. All rights reserved.
//

import Foundation

// MARK: - OPDS2Publication

struct OPDS2Publication: Codable {
  struct Metadata: Codable {
    let updated: Date
    let description: String?
    let id: String
    let title: String
  }

  let links: [OPDS2Link]
  let metadata: Metadata
  let images: [OPDS2Link]?
}

private let imageType = "image/png"

extension OPDS2Publication {
  var imageURL: URL? {
    guard let image = images?.first(where: { $0.type == imageType }) else {
      return nil
    }
    return URL(string: image.href)
  }

  var thumbnailURL: URL? {
    guard let thumbnail = images?.first(where: { $0.type == imageType && ($0.rel ?? "").contains("thumbnail") }) else {
      return nil
    }
    return URL(string: thumbnail.href)
  }

  var coverURL: URL? {
    guard let cover = images?.first(where: { $0.type == imageType && ($0.rel ?? "").contains("cover") }) else {
      return nil
    }
    return URL(string: cover.href)
  }
}
