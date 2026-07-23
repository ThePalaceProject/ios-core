import Foundation
import PalaceLogging
import PalaceNetwork

/// This class encapsulates analytic events sent to the server
/// and keeps a local queue of failed attempts to retry them
/// at a later time.
///
/// Wave 1c (god-class decomposition): relocated from Palace/Logging/ — this is
/// a circulation-domain network client, not logging (its Logging placement was
/// the whole Logging↔Network folder cycle #3).
///
/// De-objc'd in Wave 1c (standing goal): the `@objcMembers`/`NSObject` shell was
/// vestigial — every caller is Swift (`BookDetailViewModel`, `CirculationAnalyticsTests`),
/// there are zero .m/.h/.mm callers, no `#selector`/KVO/bridging-header usage, and
/// both members (`postEvent`, `addToOfflineAnalyticsQueue`) are plain-Swift static
/// funcs. The existential-param seam args on `addToOfflineAnalyticsQueue` are now
/// first-class (no `@objcMembers`-skips-non-representable-member reliance).
final class TPPCirculationAnalytics {

    static func postEvent(_ event: String, withBook book: TPPBook) {
        if let requestURL = book.analyticsURL?.appendingPathComponent(event) {
            post(event, withURL: requestURL)
        }
    }

    private static func post(_ event: String, withURL url: URL) {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 3
        config.timeoutIntervalForResource = 3
        config.waitsForConnectivity = false
        let session = URLSession(configuration: config)

        var request = URLRequest(url: url)
        request.httpMethod = "GET"

        let task = session.dataTask(with: request) { (_, response, error) in
            if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 {
                Log.info(#file, "Analytics Upload: Success for event \(event)")
                return
            }
            if let error = error as NSError?, error.domain == NSURLErrorDomain, error.code == NSURLErrorTimedOut {
                // Downgrade noisy timeouts; nothing is enqueued — see note below.
                Log.debug(#file, "Analytics request timed out for event \(event)")
                return
            }
            // DEAD-BRANCH REMOVAL (Wave 1c, behavior-preserving): the previous
            // `handleFailure` gated the offline enqueue on
            // `NetworkQueue.StatusCodes.contains(httpResponse.statusCode)` —
            // but StatusCodes are NEGATIVE NSURLError codes and statusCode is a
            // POSITIVE HTTP status, so the gate was false for every real
            // response since inception (and on timeout `response` is nil).
            // Observable behavior is identical without it. Re-wiring the
            // offline path deliberately (gate on the NSError code, mirroring
            // TPPAnnotations.swift:319, + dedup/product review) is the filed
            // follow-up — see the Wave 1c PR's Deferred stanza. The enqueue
            // shape below stays pinned by the request-shape contract test so
            // that follow-up lands against a locked contract.
        }
        task.resume()
    }

    /// The offline-retry enqueue. `internal` (not `private`) + fully seam-injected
    /// so PalaceTests/Decomp/TPPCirculationAnalyticsRequestShapeContractTests can
    /// pin the enqueue shape (the ephemeral URLSession in `post` is un-interceptable
    /// — documented in that test file). Currently has no production caller (see
    /// dead-branch note in `post`); it is the pinned contract for the follow-up
    /// that re-wires offline retry.
    static func addToOfflineAnalyticsQueue(
        _ event: String,
        _ bookURL: URL,
        accountsManager: TPPCurrentLibraryAccountProvider = AppContainer.production().accountsManager,
        requestProvider: AuthorizedRequestProviding = AppContainer.production().networkExecutor,
        offlineQueue: OfflineRequestEnqueuing = AppContainer.production().networkQueue
    ) {
        let libraryID = accountsManager.currentAccount?.uuid ?? ""
        let headers = requestProvider.authorizedRequest(for: bookURL).allHTTPHeaderFields
        offlineQueue.enqueueOfflineRequest(
            libraryID: libraryID,
            updateID: nil,
            url: bookURL,
            method: .GET,
            parameters: nil,
            headers: headers
        )
    }
}
