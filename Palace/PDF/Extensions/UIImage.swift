//
//  UIImage.swift
//  Palace
//
//  Created by Vladimir Fedorov on 13.07.2022.
//  Copyright © 2022 The Palace Project. All rights reserved.
//

import Foundation

extension UIImage {
  
  /// Create an image
  /// - Parameters:
  ///   - color: Color of the image
  ///   - size: Image size
  convenience init?(color: UIColor, size: CGSize) {
    let rect = CGRect(origin: .zero, size: size)
    UIGraphicsBeginImageContextWithOptions(rect.size, false, 0.0)
    color.setFill()
    UIRectFill(rect)
    let image = UIGraphicsGetImageFromCurrentImageContext()
    UIGraphicsEndImageContext()
    guard let cgImage = image?.cgImage else { return nil }
    self.init(cgImage: cgImage)
  }
  
}
