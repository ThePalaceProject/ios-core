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
  
  private let pdfURL: URL
  private let lcpService = LCPLibraryService()
  private let streamer: Streamer
  
  /// Initialize for an LCP PDF
  /// - Parameter pdfURL: must be a file with `.pdf` extension
  @objc init?(for pdfURL: URL) {
    // Check contentProtection is in place
    guard let contentProtection = lcpService.contentProtection else {
      TPPErrorLogger.logError(nil, summary: "Uninitialized contentProtection in LCPAudiobooks")
      return nil
    }
    self.pdfURL = pdfURL
    self.streamer = Streamer(contentProtections: [contentProtection])
  }

  /// Check if the book is LCP audiobook
  /// - Parameter book: audiobook
  /// - Returns: `true` if the book is an LCP DRM protected audiobook, `false` otherwise
  @objc static func canOpenBook(_ book: TPPBook) -> Bool {
    guard let defualtAcquisition = book.defaultAcquisition() else { return false }
    return book.defaultBookContentType() == .PDF && defualtAcquisition.type == expectedAcquisitionType
  }
}
#endif

