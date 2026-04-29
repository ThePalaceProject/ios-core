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
  public static func withURL(
    _ url: URL,
    networkClient: NetworkClient,
    completionHandler: @escaping (TPPOpenSearchDescription?) -> Void
  ) {
    Task {
      do {
        let request = NetworkRequest(method: .GET, url: url)
        let response = try await networkClient.send(request)

        guard let xml = TPPXML.xml(withData: response.data) else {
          Log.log("TPPOpenSearchDescription: Failed to parse data as XML.")
          await MainActor.run { completionHandler(nil) }
          return
        }

        guard let description = TPPOpenSearchDescription(xml: xml) else {
          Log.log("TPPOpenSearchDescription: Failed to interpret XML as OpenSearch description document.")
          await MainActor.run { completionHandler(nil) }
          return
        }

        await MainActor.run { completionHandler(description) }
      } catch {
        Log.log("TPPOpenSearchDescription: Network error: \(error)")
        await MainActor.run { completionHandler(nil) }
      }
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
