//
//  The line a download-failure alert shows under "The download for X failed",
//  built from the error that ended the download (PP-5541). Callers that have
//  an error and pass nil get the generic "check your connection" line, which
//  hides Adobe and server faults from patrons, QA and the error log.
//

import Foundation

enum DownloadFailureDetail {

    /// Returns a short, technical line naming the error, or nil when there is
    /// no error, so the alert keeps its generic line.
    ///
    /// Adobe puts its own error name under `originalCode`, often followed by
    /// the Adobe URL it called (`E_ADEPT_REQUEST_EXPIRED http://...`). The name
    /// is the useful part; the URL is dropped. The domain and code always
    /// follow, because two different faults can share a description.
    static func message(for error: Error?) -> String? {
        guard let error else { return nil }
        let ns = error as NSError
        let code = "\(ns.domain) \(ns.code)"

        if let original = ns.userInfo[AdobeDeauthorization.adobeOriginalCodeKey] as? String,
           let name = original.split(whereSeparator: \.isWhitespace).first {
            return "Error: \(name) (\(code))"
        }

        // With no description of its own, an error reports Foundation's
        // "The operation couldn't be completed. (domain error N.)", which only
        // repeats the code. Cocoa and URL errors build real descriptions on
        // demand, so `localizedDescription` is kept unless it is that default.
        let description = ns.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        let isDefault = description.isEmpty || description.hasSuffix("(\(ns.domain) error \(ns.code).)")
        let detail = isDefault ? "Error: \(code)" : "Error: \(description) (\(code))"

        // A network failure is the one case where "check your connection" is
        // the right advice, so it stays above the detail.
        guard ns.domain == NSURLErrorDomain else { return detail }
        return "\(Strings.MyDownloadCenter.downloadFailedUnknownReason)\n\(detail)"
    }
}
