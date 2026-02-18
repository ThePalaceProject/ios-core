//
//  CGPDFPage+previews.swift
//  Palace
//
//  Created by Vladimir Fedorov on 22.06.2022.
//  Copyright © 2022 The Palace Project. All rights reserved.
//

import Foundation

extension CGPDFPage {
  /// Render PDF image in a specified rectangle
  /// - Parameter rect: Rectangle to render the page to
  /// - Returns: Pendered PDF page image
  func image(of size: CGSize? = nil, for documentBox: CGPDFBox? = .mediaBox) -> UIImage? {
    var pageRect = getBoxRect(documentBox ?? .mediaBox)
    var pdfScale = 1.0
    if let size = size {
      pdfScale = min(size.width / pageRect.size.width, size.height / pageRect.size.height)
      pageRect.origin = .zero
      pageRect.size = CGSize(width: pageRect.size.width * pdfScale, height: pageRect.size.height * pdfScale)
    }
    
    UIGraphicsBeginImageContext(pageRect.size);
    
    guard let context = UIGraphicsGetCurrentContext() else {
      return nil
    }
    
    context.setFillColor(UIColor.white.cgColor)
    context.fill(pageRect)
    context.saveGState()
    
    context.translateBy(x: 0, y: pageRect.size.height)
    context.scaleBy(x: 1, y: -1)
    context.scaleBy(x: pdfScale, y: pdfScale)
    context.drawPDFPage(self)
    context.restoreGState()
    
    let image = UIGraphicsGetImageFromCurrentImageContext()
    
    UIGraphicsEndImageContext()
    return image
  }
  
  /// Thumbnail image of the page
  var thumbnail: UIImage? {
    image(of: .pdfThumbnailSize, for: .mediaBox)
  }
  
  /// Preview image of the page
  var preview: UIImage? {
    image(of: .pdfPreviewSize, for: .mediaBox)
  }
}
