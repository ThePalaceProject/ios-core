//
//  TPPBookContentTypeConverter.swift
//  The Palace Project
//
//  Created by Ettore Pasquini on 8/17/20.
//  Copyright © 2020 NYPL Labs. All rights reserved.
//

import Foundation

class TPPBookContentTypeConverter: NSObject {
    /// PP-4161 / F-011: exhaustive — NO `default:` clause. The next enum-case
    /// addition to `TPPBookContentType` must compile-error here so the
    /// conversion stays honest. Do not reintroduce a default arm.
    @objc class func stringValue(of bookContentType: TPPBookContentType) -> String {
        switch bookContentType {
        case .epub:
            return "Epub"
        case .audiobook:
            return "AudioBook"
        case .pdf:
            return "PDF"
        case .unsupported:
            return "Unsupported"
        case .streamingHTML:
            return "StreamingHTML"
        }
    }
}
