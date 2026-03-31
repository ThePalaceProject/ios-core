import Foundation

/// This class encapsulates analytic events sent to the server
/// and keeps a local queue of failed attempts to retry them
/// at a later time.
@objcMembers final class TPPCirculationAnalytics: NSObject {

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
                // Downgrade noisy timeouts; queue offline for later
                Log.debug(#file, "Analytics request timed out for event \(event)")
                handleFailure(event: event, url: url, response: response)
                return
            }
            handleFailure(event: event, url: url, response: response)
        }
        task.resume()
    }

    private static func handleFailure(event: String, url: URL, response: URLResponse?) {
        if let httpResponse = response as? HTTPURLResponse, NetworkQueue.StatusCodes.contains(httpResponse.statusCode) {
            addToOfflineAnalyticsQueue(event, url)
        }
    }

    private static func addToOfflineAnalyticsQueue(_ event: String, _ bookURL: URL, accountsManager: AccountsManager = AccountsManager.shared, networkExecutor: TPPNetworkExecutor = .shared) {
        let libraryID = accountsManager.currentAccount?.uuid ?? ""
        let headers = networkExecutor.request(for: bookURL).allHTTPHeaderFields
        NetworkQueue.shared().addRequest(libraryID, nil, bookURL, .GET, nil, headers)
    }
}
