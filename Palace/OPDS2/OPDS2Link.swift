//
//  OPDS2Link.swift
//  The Palace Project
//
//  Created by Benjamin Anderman on 5/10/19.
//  Copyright © 2019 NYPL Labs. All rights reserved.
//

import Foundation

// MARK: - OPDS2Link

struct OPDS2Link: Codable {
  let href: String
  let type: String?
  let rel: String?
  let templated: Bool?

  let displayNames: [OPDS2InternationalVariable]?
  let descriptions: [OPDS2InternationalVariable]?
}

// MARK: - OPDS2InternationalVariable

struct OPDS2InternationalVariable: Codable {
  let language: String
  let value: String
}
