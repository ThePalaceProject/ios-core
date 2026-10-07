//
//  EmailAddress.swift
//  Palace
//
//  Created by Maurice Carrier on 5/24/22.
//  Copyright © 2022 The Palace Project. All rights reserved.
//  https://www.swiftbysundell.com/articles/validating-email-addresses/
//

import Foundation

@objc public class EmailAddress: NSObject, RawRepresentable, Codable {
    @objc public let rawValue: String

    /// Built once: every Account in the library registry validates its help
    /// link here at launch, and building a detector per call cost seconds on
    /// slow devices. NSDataDetector is an NSRegularExpression, which Apple
    /// documents as immutable and safe to match from several threads at once:
    /// https://developer.apple.com/documentation/foundation/nsregularexpression#Concurrency-and-Thread-Safety
    private static let linkDetector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)

    public required init?(rawValue: String) {
        let sanitizedString = rawValue.replacingOccurrences(of: " ", with: "")
        let range = NSRange(sanitizedString.startIndex..<sanitizedString.endIndex, in: sanitizedString)
        let matches = Self.linkDetector?.matches(in: sanitizedString, range: range)

        guard let match = matches?.first, matches?.count == 1 else {
            return nil
        }

        guard match.url?.scheme == "mailto", match.range == range else {
            return nil
        }

        self.rawValue = sanitizedString.replacingOccurrences(of: "mailto:", with: "")
    }
}
