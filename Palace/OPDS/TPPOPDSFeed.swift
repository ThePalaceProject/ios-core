import Foundation

@objc enum TPPOPDSFeedType: Int {
  case invalid
  case acquisitionGrouped
  case acquisitionUngrouped
  case navigation
}

@objc class TPPOPDSFeed: NSObject {

  @objc private(set) var entries: [Any] = []
  @objc private(set) var identifier: String?
  @objc private(set) var links: [Any] = []
  @objc private(set) var title: String?
  @objc private(set) var updated: Date?
  @objc private(set) var licensor: NSDictionary?
  @objc private(set) var authorizationIdentifier: String?

  private var _type: TPPOPDSFeedType = .invalid
  private var typeIsCached = false

  @objc var type: TPPOPDSFeedType {
    if typeIsCached { return _type }
    typeIsCached = true

    guard let entries = self.entries as? [TPPOPDSEntry], !entries.isEmpty else {
      _type = .acquisitionUngrouped
      return _type
    }

    let provisionalType = Self.typeImplied(by: entries[0])
    if provisionalType == .invalid {
      _type = .invalid
      return _type
    }

    for i in 1..<entries.count {
      if Self.typeImplied(by: entries[i]) != provisionalType {
        _type = .invalid
        return _type
      }
    }

    _type = provisionalType
    return _type
  }

  @objc static func withURL(
    _ url: URL?,
    shouldResetCache: Bool,
    useTokenIfAvailable: Bool,
    completionHandler handler: @escaping (TPPOPDSFeed?, NSDictionary?) -> Void
  ) {
    guard let url = url else {
      TPPErrorLogger.logError(
        withCode: .noURL,
        summary: "NYPLOPDSFeed: nil URL",
        metadata: ["shouldResetCache": shouldResetCache]
      )
      TPPAsyncDispatch { handler(nil, nil) }
      return
    }

    let cachePolicy: NSURLRequest.CachePolicy = shouldResetCache ? .reloadIgnoringLocalCacheData : .useProtocolCachePolicy

    var request: URLRequest?

    let task = TPPNetworkExecutor.shared.get(
      url,
      cachePolicy: cachePolicy,
      useTokenIfAvailable: useTokenIfAvailable
    ) { data, response, error in

      if let error = error {
        TPPAsyncDispatch { handler(nil, (error as NSError).problemDocument?.dictionaryValue as NSDictionary?) }
        return
      }

      guard let data = data else {
        TPPErrorLogger.logError(
          withCode: .opdsFeedNoData,
          summary: "NYPLOPDSFeed: no data from server",
          metadata: [
            "Request": (request as NSURLRequest?)?.loggableString ?? "N/A",
            "Response": response ?? "N/A"
          ]
        )
        TPPAsyncDispatch { handler(nil, nil) }
        return
      }

      if let httpResp = response as? HTTPURLResponse,
         httpResp.statusCode < 200 || httpResp.statusCode > 299 {
        let dataString = String(data: data, encoding: .utf8)

        var problemDocDict: NSDictionary?
        if response?.isProblemDocument == true {
          problemDocDict = try? JSONSerialization.jsonObject(with: data, options: []) as? NSDictionary
        }

        TPPErrorLogger.logNetworkError(
          error,
          code: .apiCall,
          summary: "NYPLOPDSFeed: HTTP response error",
          request: request as NSURLRequest?,
          response: response,
          metadata: [
            "receivedData": dataString ?? "N/A",
            "receivedDataLength (bytes)": data.count,
            "problemDoc": problemDocDict ?? "N/A",
            "context": "Got \(httpResp.statusCode) HTTP status with no error object."
          ]
        )

        TPPAsyncDispatch { handler(nil, problemDocDict) }
        return
      }

      guard let feedXML = TPPXML.xml(withData: data) else {
        Log.log("Failed to parse data as XML.")
        TPPErrorLogger.logError(
          withCode: .feedParseFail,
          summary: "NYPLOPDSFeed: Failed to parse data as XML",
          metadata: [
            "request": (request as NSURLRequest?)?.loggableString ?? "N/A",
            "response": response ?? "N/A"
          ]
        )
        let errorDict = try? JSONSerialization.jsonObject(with: data, options: []) as? NSDictionary
        TPPAsyncDispatch { handler(nil, errorDict) }
        return
      }

      guard let feed = TPPOPDSFeed(xml: feedXML) else {
        Log.log("Could not interpret XML as OPDS.")
        TPPErrorLogger.logError(
          withCode: .opdsFeedParseFail,
          summary: "NYPLOPDSFeed: Failed to parse XML as OPDS",
          metadata: [
            "request": (request as NSURLRequest?)?.loggableString ?? "N/A",
            "response": response ?? "N/A"
          ]
        )
        TPPAsyncDispatch { handler(nil, nil) }
        return
      }

      TPPAsyncDispatch { handler(feed, nil) }
    }

    request = task?.originalRequest
  }

  @objc init?(xml feedXML: TPPXML?) {
    super.init()

    guard let feedXML = feedXML else { return nil }

    // Sometimes we get back JUST an entry
    if feedXML.name == "entry" {
      guard let entry = TPPOPDSEntry(xml: feedXML) else {
        Log.log("Error creating single OPDS entry from feed.")
        return nil
      }
      entries = [entry]
      return
    }

    guard let id = feedXML.firstChild(withName: "id")?.value else {
      Log.log("Missing required 'id' element.")
      return nil
    }
    identifier = id

    var parsedLinks = [TPPOPDSLink]()
    for linkXML in feedXML.childrenWithName("link") {
      guard let link = TPPOPDSLink(xml: linkXML) else {
        Log.log("Ignoring malformed 'link' element.")
        continue
      }
      parsedLinks.append(link)
    }
    links = parsedLinks

    guard let t = feedXML.firstChild(withName: "title")?.value else {
      Log.log("Missing required 'title' element.")
      return nil
    }
    title = t

    guard let updatedString = feedXML.firstChild(withName: "updated")?.value else {
      Log.log("Missing required 'updated' element.")
      return nil
    }
    guard let updatedDate = NSDate.date(withRFC3339String: updatedString) as Date? else {
      Log.log("Element 'updated' does not contain an RFC 3339 date.")
      return nil
    }
    updated = updatedDate

    var parsedEntries = [TPPOPDSEntry]()
    for entryXML in feedXML.childrenWithName("entry") {
      guard let entry = TPPOPDSEntry(xml: entryXML) else {
        Log.log("Ignoring malformed 'entry' element.")
        continue
      }
      parsedEntries.append(entry)
    }
    entries = parsedEntries

    if let patronXML = feedXML.firstChild(withName: "patron"),
       let attrs = patronXML.attributes as? [String: String],
       !attrs.isEmpty {
      authorizationIdentifier = attrs["simplified:authorizationIdentifier"]
    }

    if let licensorXML = feedXML.firstChild(withName: "licensor"),
       let attrs = licensorXML.attributes as? [String: String],
       !attrs.isEmpty {
      if let vendor = attrs["drm:vendor"],
         let tokenXML = licensorXML.firstChild(withName: "clientToken") {
        let clientToken = tokenXML.value
        licensor = ["vendor": vendor, "clientToken": clientToken] as NSDictionary
      } else {
        Log.log("Licensor not saved. Error parsing clientToken into XML.")
      }
    } else {
      Log.log("No Licensor found in OPDS feed. Moving on.")
    }
  }

  private static func typeImplied(by entry: TPPOPDSEntry) -> TPPOPDSFeedType {
    var entryIsGrouped = false
    var entryIsCatalogEntry = !entry.acquisitions.isEmpty

    for link in entry.links {
      if let rel = link.rel {
        if rel.hasPrefix("http://opds-spec.org/acquisition") {
          entryIsCatalogEntry = true
        } else if rel == TPPOPDSRelationGroup {
          entryIsGrouped = true
        }
      }
    }

    if entryIsGrouped && !entryIsCatalogEntry {
      return .invalid
    }

    return entryIsCatalogEntry
      ? (entryIsGrouped ? .acquisitionGrouped : .acquisitionUngrouped)
      : .navigation
  }
}
