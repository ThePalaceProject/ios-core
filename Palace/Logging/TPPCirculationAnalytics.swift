import Foundation

/// This class encapsulates analytic events sent to the server
/// and keeps a local queue of failed attempts to retry them
/// at a later time.
@objcMembers final class TPPCirculationAnalytics : NSObject {

  class func postEvent(_ event: String, withBook book: TPPBook) -> Void
  {
    if let requestURL = book.analyticsURL?.appendingPathComponent(event) {
      post(event, withURL: requestURL)
    }
  }
  
  private class func post(_ event: String, withURL url: URL) {
    Task {
      do {
        let (_, response) = try await TPPNetworkExecutor.shared.GET(url)
        if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 {
          Log.info(#file, "Analytics Upload: Success for event \(event)")
        } else {
          handleFailure(event: event, url: url, response: response)
        }
      } catch {
        Log.error(#file, "Analytics request failed: \(error.localizedDescription)")
        handleFailure(event: event, url: url, response: nil)
      }
    }
  }

  private class func handleFailure(event: String, url: URL, response: URLResponse?) {
    if let httpResponse = response as? HTTPURLResponse, NetworkQueue.StatusCodes.contains(httpResponse.statusCode) {
      addToOfflineAnalyticsQueue(event, url)
    }
  }


  private class func addToOfflineAnalyticsQueue(_ event: String, _ bookURL: URL) -> Void
  {
    let libraryID = AccountsManager.shared.currentAccount?.uuid ?? ""
    let headers = TPPNetworkExecutor.shared.request(for: bookURL).allHTTPHeaderFields
    NetworkQueue.shared().addRequest(libraryID, nil, bookURL, .GET, nil, headers)
  }
}
