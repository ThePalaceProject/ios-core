//
//  TPPBook+Extensions.swift
//  Palace
//
//  Created by Maurice Carrier on 6/7/22.
//  Copyright © 2022 The Palace Project. All rights reserved.
//

import Foundation
import ObjectiveC

// MARK: - Associated Object Keys for Keychain Variables

private var bearerTokenVariableKey: UInt8 = 0
private var fulfillURLVariableKey: UInt8 = 0

@objc extension TPPBook {
    typealias DisplayStrings = Strings.TPPBook

    /// Cached keychain variable for bearer token (reused across get/set calls)
    @nonobjc private var _bearerTokenVariable: TPPKeychainVariable<String> {
        if let existing = objc_getAssociatedObject(self, &bearerTokenVariableKey) as? TPPKeychainVariable<String> {
            return existing
        }
        let variable: TPPKeychainVariable<String> = self.identifier.asKeychainVariable(with: bookTokenQueue)
        objc_setAssociatedObject(self, &bearerTokenVariableKey, variable, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        return variable
    }

    /// Cached keychain variable for fulfill URL (reused across get/set calls)
    @nonobjc private var _fulfillURLVariable: TPPKeychainVariable<String> {
        if let existing = objc_getAssociatedObject(self, &fulfillURLVariableKey) as? TPPKeychainVariable<String> {
            return existing
        }
        let key = "\(self.identifier)-fulfillURL"
        let variable: TPPKeychainVariable<String> = key.asKeychainVariable(with: bookTokenQueue)
        objc_setAssociatedObject(self, &fulfillURLVariableKey, variable, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        return variable
    }

    var bearerToken: String? {
        get {
            _bearerTokenVariable.read()
        }
        set {
            _bearerTokenVariable.write(newValue)
        }
    }

    var bearerTokenFulfillURL: URL? {
        get {
            guard let urlString = _fulfillURLVariable.read() else { return nil }
            return URL(string: urlString)
        }
        set {
            _fulfillURLVariable.write(newValue?.absoluteString)
        }
    }

    /// Readable book format based on its content type
    var format: String {
        switch defaultBookContentType {
        case .epub: return DisplayStrings.epubContentType
        case .pdf: return DisplayStrings.pdfContentType
        case .audiobook: return DisplayStrings.audiobookContentType
        case .unsupported: return DisplayStrings.unsupportedContentType
        }
    }

    var hasSample: Bool { sample != nil }
    var hasAudiobookSample: Bool { hasSample && defaultBookContentType == .audiobook }
    var showAudiobookToolbar: Bool { hasAudiobookSample && SampleType(rawValue: sampleAcquisition?.type ?? "")?.needsDownload ?? false }
}

extension TPPBook {
    var sample: Sample? {
        guard let acquisition = self.sampleAcquisition else { return nil }
        switch self.defaultBookContentType {
        case .epub, .pdf:
            guard let sampleType = SampleType(rawValue: acquisition.type) else { return nil }
            return EpubSample(url: acquisition.hrefURL, type: sampleType)
        case .audiobook:
            guard let sampleType = SampleType(rawValue: acquisition.type) else { return nil }
            return AudiobookSample(url: acquisition.hrefURL, type: sampleType)
        default:
            return nil
        }
    }
}
