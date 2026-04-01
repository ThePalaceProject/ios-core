import Foundation

@objc class TPPOpenSearchDescription: NSObject {

  @objc private(set) var humanReadableDescription: String?
  @objc var opdsURLTemplate: String?
  @objc private(set) var books: [Any]?

  private override init() {
    super.init()
  }

  @objc static func withURL(
    _ url: URL,
    shouldResetCache: Bool,
    completionHandler handler: @escaping (TPPOpenSearchDescription?) -> Void
  ) {
    TPPSession.sharedSession.withURL(url, shouldResetCache: shouldResetCache) { data, _, _ in
      guard let data = data else {
        Log.log("Failed to retrieve data.")
        TPPAsyncDispatch { handler(nil) }
        return
      }

      guard let xml = TPPXML.xml(withData: data) else {
        Log.log("Failed to parse data as XML.")
        TPPAsyncDispatch { handler(nil) }
        return
      }

      guard let description = TPPOpenSearchDescription(xml: xml) else {
        Log.log("Failed to interpret XML as OpenSearch description document.")
        TPPAsyncDispatch { handler(nil) }
        return
      }

      TPPAsyncDispatch { handler(description) }
    }
  }

  @objc init?(xml osdXML: TPPXML) {
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

  @objc init(title: String, books: [Any]) {
    super.init()
    self.humanReadableDescription = title
    self.books = books
  }

  @objc func opdsURL(forSearchingString searchString: String) -> URL? {
    guard let template = opdsURLTemplate,
          let encoded = (searchString as NSString).stringURLEncodedAsQueryParamValue() else {
      return nil
    }
    let urlStr = template.replacingOccurrences(of: "{searchTerms}", with: encoded)
    return URL(string: urlStr)
  }
}
