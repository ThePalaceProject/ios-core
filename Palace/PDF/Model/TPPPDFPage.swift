//
//  TPPPDFPage.swift
//  Palace
//
//  Created by Vladimir Fedorov on 22.06.2022.
//  Copyright © 2022 The Palace Project. All rights reserved.
//

import Foundation

/// PDF page location object.
///
/// This structure is used for encoding and decoding page location in PDF files
/// in TPPBookLocation object.
struct TPPPDFPage: Codable {
  let pageNumber: Int
}
