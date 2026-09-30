import Foundation
import PalaceLogging
import PalaceNetwork
import PalaceBookModel

/// This class encapsulates analytic events sent to the server
/// and keeps a local queue of failed attempts to retry them
/// at a later time.
///
/// A circulation-domain network client, so it lives under OPDS2 rather than
/// Logging.
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
            // Failures are not enqueued for offline retry. The earlier gate
            // compared an HTTP status against negative NSURLError codes and so
            // never enqueued. Re-wiring offline retry (gated on the NSError
            // code, as TPPAnnotations does) is a pending follow-up; the enqueue
            // shape below is pinned by a contract test for it.
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
