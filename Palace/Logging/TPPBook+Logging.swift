//
//  TPPBook+Additions.swift
//  The Palace Project
//
//  Created by Ettore Pasquini on 7/9/20.
//  Copyright © 2020 NYPL Labs. All rights reserved.
//

import Foundation
import PalaceBookModel

// de-objc (Wave 2a): plain-Swift extension — @objc members here would emit an illegal
// ObjC category on the now-external PalaceBookModel.TPPBook. Zero ObjC callers.
extension TPPBook {
    /// An informative short string describing the book, for logging purposes.
    func loggableShortString() -> String {
        return "<\(title) ID=\(identifier) Distributor=\(distributor ?? "")>"
    }

    /// An informative dictionary detailing all aspects of the book that could
    /// be interesting for logging purposes.
    func loggableDictionary() -> [String: Any] {
        return [
            "bookTitle": title,
            "bookID": identifier,
            "bookDistributor": distributor ?? "",
            "defaultAcquisitionType": defaultAcquisition?.type ?? "N/A",
            "alternateURL": alternateURL ?? "N/A",
            "contentType": TPPBookContentTypeConverter.stringValue(of: defaultBookContentType)
        ]
    }
}
