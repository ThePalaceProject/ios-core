//
//  AudioBookVendorsHelper.swift
//  The Palace Project
//
//  Created by Vladimir Fedorov on 10.09.2020.
//  Copyright © 2020 NYPL Labs. All rights reserved.
//

import Foundation

public enum AudioBookVendorsHelper {

    /// Get vendor for the book JSON data.
    ///
    /// Exposed (was `private`) so callers can resolve the vendor synchronously
    /// before entering an async closure. Capturing the `[String: Any]` book
    /// dictionary across an async boundary causes EXC_BREAKPOINT crashes in
    /// `block_destroy_helper` when the closure tears down on cantook DRM books
    /// (Crashlytics issue 7bf923ee). Resolving the vendor up front lets the
    /// caller skip the async hop entirely for non-DRM books and avoid
    /// capturing the dictionary in the DRM path.
    static func feedbookVendor(for book: [String: Any]) -> AudioBookVendors? {
        guard let metadata = book["metadata"] as? [String: Any],
              let signature = metadata["http://www.feedbooks.com/audiobooks/signature"] as? [String: Any],
              let issuer = signature["issuer"] as? String
        else {
            return nil
        }
        switch issuer {
        case "https://www.cantookaudio.com": return .cantook
        default: return nil
        }
    }

    /// Refresh the DRM certificate for a vendor that was already resolved
    /// synchronously by the caller via ``feedbookVendor(for:)``. Caller is
    /// responsible for not capturing the source `[String: Any]` book
    /// dictionary in the completion closure.
    static func updateDrmCertificate(
        for vendor: AudioBookVendors,
        completion: @escaping (_ error: NSError?) -> Void
    ) {
        vendor.updateDrmCertificate { error in
            completion(self.nsError(for: error))
        }
    }

    /// Convenience entry point that resolves vendor + refreshes cert in one
    /// call. Prefer the two-step form (``feedbookVendor(for:)`` +
    /// ``updateDrmCertificate(for:completion:)``) at hot async sites.
    static func updateVendorKey(
        book: [String: Any],
        completion: @escaping (_ error: NSError?) -> Void
    ) {
        if let vendor = feedbookVendor(for: book) {
            updateDrmCertificate(for: vendor, completion: completion)
        } else {
            completion(nil)
        }
    }

    private static func nsError(for error: Error?) -> NSError? {
        guard let error = error else {
            return nil
        }
        let domain = "SimplyE.AudioBookVendorsHelper"
        let code = 0
        var description = error.localizedDescription
        if let dplaError = error as? DPLAAudiobooks.DPLAError {
            description = dplaError.readableError
        }
        return NSError(domain: domain, code: code, userInfo: [
            NSLocalizedDescriptionKey: description
        ])
    }
}
