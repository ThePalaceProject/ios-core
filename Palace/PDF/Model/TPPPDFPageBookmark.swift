//
//  TPPPDFPageBookmark.swift
//  Palace
//
//  Created by Vladimir Fedorov on 11.08.2022.
//  Copyright © 2022 The Palace Project. All rights reserved.
//

import Foundation
import PalaceBookModel

/// Page bookmark object for page synchronization between devices
///
/// Swift 6 `complete` — `@unchecked Sendable` invariant: `type` and `page` are
/// immutable `let`s; `annotationID` is a `String?` set once (right after decode /
/// server round-trip, when the annotation URL comes back) and only read thereafter
/// — write-once-then-read confinement, no concurrent mutation. Lets arrays of these
/// cross the `@Sendable` bookmark-fetch completion into the main-actor
/// `pdfBookmarks` assignment in `TPPPDFDocumentMetadata`. Documented invariant.
@objc class TPPPDFPageBookmark: NSObject, Codable, Bookmark, @unchecked Sendable {
    let type: String
    let page: Int
    var annotationID: String?

    enum CodingKeys: String, CodingKey {
        case type = "@type"
        case page
    }

    init(page: Int, annotationID: String? = nil) {
        self.type = Types.locatorPage.rawValue
        self.page = page
        self.annotationID = annotationID
    }

    enum Types: String {
        case locatorPage = "LocatorPage"
    }
}
