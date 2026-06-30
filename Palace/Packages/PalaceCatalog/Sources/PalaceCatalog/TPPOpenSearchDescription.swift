import Foundation
import PalaceLogging
import PalaceNetwork

@objc public class TPPOpenSearchDescription: NSObject {

  @objc public private(set) var humanReadableDescription: String?
  @objc public var opdsURLTemplate: String?
  @objc public private(set) var books: [Any]?

  private override init() {
    super.init()
  }

  /// Fetches an OpenSearch description document from `url` and parses it.
  ///
  /// Note: prior to PalaceCatalog extraction this method reached for
  /// `AppContainer.production().networkExecutor`. Callers now pass a
  /// `NetworkClient` explicitly (typically the app target's
  /// `networkExecutor` exposed via `AppContainer`).
  /// Returns `nil` on any failure (network error, unparseable XML, or XML that
  /// is not a valid OpenSearch description); failures are logged at the call
  /// site here rather than surfaced as thrown errors to preserve the prior
  /// completion-handler contract.
  ///
  /// Rewritten from a completion-handler signature to `async` during the Swift 6
  /// strict-concurrency migration: the old form captured a non-`Sendable`
  /// `(TPPOpenSearchDescription?) -> Void` closure inside a `Task`, which is an
  /// error under the Swift 6 language mode. Hopping back to the caller via
  /// `await` instead of `MainActor.run { completionHandler(...) }` removes the
  /// `@Sendable` capture entirely.
  public static func withURL(
    _ url: URL,
    networkClient: NetworkClient
  ) async -> TPPOpenSearchDescription? {
    do {
      let request = NetworkRequest(method: .GET, url: url)
      let response = try await networkClient.send(request)

      guard let xml = TPPXML.xml(withData: response.data) else {
        Log.log("TPPOpenSearchDescription: Failed to parse data as XML.")
        return nil
      }

      guard let description = TPPOpenSearchDescription(xml: xml) else {
        Log.log("TPPOpenSearchDescription: Failed to interpret XML as OpenSearch description document.")
        return nil
      }

      return description
    } catch {
      Log.log("TPPOpenSearchDescription: Network error: \(error)")
      return nil
    }
  }

  @objc public init?(xml osdXML: TPPXML) {
    super.init()

    humanReadableDescription = osdXML.firstChild(withName: "Description")?.value
    guard humanReadableDescription != nil else {
      Log.log("Missing required description element.")
      return nil
    }

    for urlXML in osdXML.childrenWithName("Url") {
      if let type = (urlXML.attributes as? [String: String])?["type"],
         type.contains("opds-catalog") {
        opdsURLTemplate = (urlXML.attributes as? [String: String])?["template"]
        break
      }
    }

    guard opdsURLTemplate != nil else {
      Log.log("Missing expected OPDS URL.")
      return nil
    }
  }

  @objc public init(title: String, books: [Any]) {
    super.init()
    self.humanReadableDescription = title
    self.books = books
  }

  @objc public func opdsURL(forSearchingString searchString: String) -> URL? {
    guard let template = opdsURLTemplate,
          let encoded = (searchString as NSString).stringURLEncodedAsQueryParamValue() else {
      return nil
    }
    let urlStr = template.replacingOccurrences(of: "{searchTerms}", with: encoded)
    return URL(string: urlStr)
  }
}
