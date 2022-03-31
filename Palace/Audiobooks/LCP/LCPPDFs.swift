//
//  LCPPDFs.swift
//  Palace
//
//  Created by Maurice Carrier on 3/22/22.
//  Copyright © 2022 The Palace Project. All rights reserved.
//

#if LCP

import Foundation
import R2Shared
import R2Streamer
import ReadiumLCP

/// LCP PDF helper class
@objc class LCPPDFs: NSObject {
  private static let expectedAcquisitionType = "application/vnd.readium.lcp.license.v1.0+json"
 
  /// Check if the book is LCPPDF
  /// - Parameter book: pdf
  /// - Returns: `true` if the book is an LCP DRM protected PDF, `false` otherwise
  @objc static func canOpenBook(_ book: TPPBook) -> Bool {
    guard let defualtAcquisition = book.defaultAcquisition() else { return false }
    return book.defaultBookContentType() == .PDF && defualtAcquisition.type == expectedAcquisitionType
  }
}
#endif
