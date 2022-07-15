//
//  DispatchQueue.swift
//  Palace
//
//  Created by Vladimir Fedorov on 12.07.2022.
//  Copyright © 2022 The Palace Project. All rights reserved.
//

import Foundation

extension DispatchQueue {
  /// Dispatch queue for thumbnails rendering
  static var pdfThumbnailRenderingQueue: DispatchQueue {
    DispatchQueue(label: "org.thepalaceproject.palace.thumbnailRenderingQueue", qos: .userInitiated)
  }
  /// Dispatch queue for image rendering
  static var pdfImageRenderingQueue: DispatchQueue {
    DispatchQueue(label: "org.thepalaceproject.palace.imageRenderingQueue", qos: .userInitiated)
  }

}
