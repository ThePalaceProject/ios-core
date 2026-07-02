//
//  TPPBook+Extensions.swift
//  Palace
//
//  Created by Maurice Carrier on 6/7/22.
//  Copyright © 2022 The Palace Project. All rights reserved.
//

import Foundation
import ObjectiveC
import PalaceKeychain

// MARK: - Associated Object Keys for Keychain Variables

/// Stable, unique association keys. `objc_{get,set}AssociatedObject` only needs
/// a distinct constant pointer per key; a `static let` of a `Sendable`
/// `UnsafeRawPointer` gives that without the nonisolated-global-mutable-`var`
/// concurrency warning (previously `private var …Key: UInt8 = 0`, whose address
/// was taken via `&`). The 1-byte allocations are intentionally never freed —
/// the keys live for the app's lifetime.
private enum TPPBookAssociatedKeys {
    static let bearerTokenVariable = UnsafeRawPointer(UnsafeMutableRawPointer.allocate(byteCount: 1, alignment: 1))
    static let fulfillURLVariable = UnsafeRawPointer(UnsafeMutableRawPointer.allocate(byteCount: 1, alignment: 1))
}

@objc extension TPPBook {
    typealias DisplayStrings = Strings.TPPBook

    /// Cached keychain variable for bearer token (reused across get/set calls)
    @nonobjc private var _bearerTokenVariable: TPPKeychainVariable<String> {
        if let existing = objc_getAssociatedObject(self, TPPBookAssociatedKeys.bearerTokenVariable) as? TPPKeychainVariable<String> {
            return existing
        }
        let variable: TPPKeychainVariable<String> = self.identifier.asKeychainVariable(with: bookTokenQueue)
        objc_setAssociatedObject(self, TPPBookAssociatedKeys.bearerTokenVariable, variable, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        return variable
    }

    /// Cached keychain variable for fulfill URL (reused across get/set calls)
    @nonobjc private var _fulfillURLVariable: TPPKeychainVariable<String> {
        if let existing = objc_getAssociatedObject(self, TPPBookAssociatedKeys.fulfillURLVariable) as? TPPKeychainVariable<String> {
            return existing
        }
        let key = "\(self.identifier)-fulfillURL"
        let variable: TPPKeychainVariable<String> = key.asKeychainVariable(with: bookTokenQueue)
        objc_setAssociatedObject(self, TPPBookAssociatedKeys.fulfillURLVariable, variable, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
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
        // PP-4161: streaming-media (text/html) renders via the in-app web
        // reader. The format label is informational only — users tap Read to
        // open the WKWebView shell.
        case .streamingHTML: return DisplayStrings.streamingHTMLContentType
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
        case .streamingHTML:
            // PP-4161: streaming-media titles don't surface preview samples —
            // the asset is the page itself, online-only. Tap Read to open.
            return nil
        case .unsupported:
            return nil
        }
    }
}
