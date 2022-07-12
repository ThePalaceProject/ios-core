//
//  CGSize.swift
//  Palace
//
//  Created by Vladimir Fedorov on 12.07.2022.
//  Copyright © 2022 The Palace Project. All rights reserved.
//

import Foundation

extension CGSize {
  /// Thumbnail image size for PDF viewer
  static var pdfThumbnailSize: CGSize {
    CGSize(width: 50, height: 50)
  }
  /// Preview image size for PDF viewer
  static var pdfPreviewSize: CGSize {
    CGSize(width: 300, height: 300)
  }
}
