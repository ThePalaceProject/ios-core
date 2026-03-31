import Foundation

// MARK: - TPPOPDSFeed (Swift port of TPPOPDSFeed.m)

/// Determines the feed type implied by an entry.
private func typeImplied(by entry: TPPOPDSEntry) -> TPPOPDSFeedType {
  var entryIsGrouped = false
  // A catalog entry is an acquisition feed if it contains at least one acquisition link.
  var entryIsCatalogEntry = !entry.acquisitions.isEmpty

  for linkObj in entry.links {
    guard let link = linkObj as? TPPOPDSLink else { continue }
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

  if entryIsCatalogEntry {
    return entryIsGrouped ? .acquisitionGrouped : .acquisitionUngrouped
  }
  return .navigation
}

/// Swift reimplementation of the ObjC TPPOPDSFeed model.
@objc(TPPOPDSFeed)
public final class TPPOPDSFeed: NSObject {

  @objc public let entries: [TPPOPDSEntry]
  @objc public let identifier: String?
  @objc public let links: [TPPOPDSLink]
  @objc public let title: String?
  @objc public let updated: Date?
  @objc public let licensor: NSDictionary?
  @objc public let authorizationIdentifier: String?

  /// Lazily cached feed type.
  private var _type: TPPOPDSFeedType?

  @objc public var type: TPPOPDSFeedType {
    if let cached = _type { return cached }

    guard !entries.isEmpty else {
      _type = .acquisitionUngrouped
      return .acquisitionUngrouped
    }

    let provisional = typeImplied(by: entries.first!)

    if provisional == .invalid {
      _type = .invalid
      return .invalid
    }

    for i in 1..<entries.count {
      if typeImplied(by: entries[i]) != provisional {
        _type = .invalid
        return .invalid
      }
    }

    _type = provisional
    return provisional
  }

  /// Designated initializer. Returns `nil` if the XML is missing required fields.
  @objc init?(xml feedXML: TPPXML?) {
    guard let feedXML = feedXML else {
      return nil
    }

    // Sometimes we get back JUST an entry.
    if feedXML.name == "entry" {
      guard let entry = TPPOPDSEntry(xml: feedXML) else {
        Log.warn(#file, "Error creating single OPDS entry from feed.")
        return nil
      }
      self.entries = [entry]
      self.identifier = nil
      self.links = []
      self.title = nil
      self.updated = nil
      self.licensor = nil
      self.authorizationIdentifier = nil
      super.init()
      return
    }

    // identifier (required)
    guard let idValue = feedXML.firstChild(withName: "id")?.value else {
      Log.warn(#file, "Missing required 'id' element.")
      return nil
    }
    self.identifier = idValue

    // links
    var parsedLinks: [TPPOPDSLink] = []
    for linkObj in feedXML.children(withName: "link") {
      guard let linkXML = linkObj as? TPPXML else { continue }
      guard let link = TPPOPDSLink(xml: linkXML) else {
        Log.warn(#file, "Ignoring malformed 'link' element.")
        continue
      }
      parsedLinks.append(link)
    }
    self.links = parsedLinks

    // title (required)
    guard let titleValue = feedXML.firstChild(withName: "title")?.value else {
      Log.warn(#file, "Missing required 'title' element.")
      return nil
    }
    self.title = titleValue

    // updated (required)
    guard let updatedString = feedXML.firstChild(withName: "updated")?.value,
          let updatedDate = NSDate(rfc3339String: updatedString) as Date? else {
      Log.warn(#file, "Missing or invalid required 'updated' element.")
      return nil
    }
    self.updated = updatedDate

    // entries
    var parsedEntries: [TPPOPDSEntry] = []
    for entryObj in feedXML.children(withName: "entry") {
      guard let entryXML = entryObj as? TPPXML else { continue }
      guard let entry = TPPOPDSEntry(xml: entryXML) else {
        Log.warn(#file, "Ignoring malformed 'entry' element.")
        continue
      }
      parsedEntries.append(entry)
    }
    self.entries = parsedEntries

    // patron / authorizationIdentifier
    if let patronXML = feedXML.firstChild(withName: "patron"),
       let attrs = patronXML.attributes as? [String: String],
       !attrs.isEmpty {
      self.authorizationIdentifier = attrs["simplified:authorizationIdentifier"]
    } else {
      self.authorizationIdentifier = nil
    }

    // licensor
    if let licensorXML = feedXML.firstChild(withName: "licensor"),
       !licensorXML.attributes.isEmpty,
       let vendor = licensorXML.attributes["drm:vendor"],
       let tokenXML = licensorXML.firstChild(withName: "clientToken") {
      let clientToken = tokenXML.value
      self.licensor = ["vendor": vendor, "clientToken": clientToken] as NSDictionary
    } else {
      self.licensor = nil
    }

    super.init()
  }

  // MARK: - Network Fetch

  /// Executes a GET request for the given URL.
  @objc public static func withURL(
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
      DispatchQueue.global().async { handler(nil, nil) }
      return
    }

    let cachePolicy: NSURLRequest.CachePolicy = shouldResetCache
      ? .reloadIgnoringLocalCacheData
      : .useProtocolCachePolicy

    let task = TPPNetworkExecutor.shared.GET(
      url,
      cachePolicy: cachePolicy,
      useTokenIfAvailable: useTokenIfAvailable
    ) { data, response, error in

      if let error = error {
        let problemDict = (error as NSError).problemDocument?.dictionaryValue
        DispatchQueue.global().async { handler(nil, problemDict as NSDictionary?) }
        return
      }

      guard let data = data else {
        TPPErrorLogger.logError(
          withCode: .opdsFeedNoData,
          summary: "NYPLOPDSFeed: no data from server",
          metadata: [
            "Response": response ?? "N/A"
          ]
        )
        DispatchQueue.global().async { handler(nil, nil) }
        return
      }

      if let httpResp = response as? HTTPURLResponse,
         httpResp.statusCode < 200 || httpResp.statusCode > 299 {
        let msg = "Got \(httpResp.statusCode) HTTP status with no error object."
        let dataString = String(data: data, encoding: .utf8)

        var problemDocDict: NSDictionary? = nil
        if let resp = response, resp.isProblemDocument() {
          problemDocDict = try? JSONSerialization.jsonObject(with: data) as? NSDictionary
        }

        TPPErrorLogger.logNetworkError(
          error,
          code: .apiCall,
          summary: "NYPLOPDSFeed: HTTP response error",
          request: nil,
          response: response,
          metadata: [
            "receivedData": dataString ?? "N/A",
            "receivedDataLength (bytes)": data.count,
            "problemDoc": problemDocDict ?? "N/A",
            "context": msg
          ]
        )

        DispatchQueue.global().async { handler(nil, problemDocDict) }
        return
      }

      guard let feedXML = TPPXML.xml(with: data) else {
        Log.info(#file, "Failed to parse data as XML.")
        TPPErrorLogger.logError(
          withCode: .feedParseFail,
          summary: "NYPLOPDSFeed: Failed to parse data as XML",
          metadata: [
            "response": response ?? "N/A"
          ]
        )
        let errorDict = try? JSONSerialization.jsonObject(with: data) as? NSDictionary
        DispatchQueue.global().async { handler(nil, errorDict) }
        return
      }

      guard let feed = TPPOPDSFeed(xml: feedXML) else {
        Log.info(#file, "Could not interpret XML as OPDS.")
        TPPErrorLogger.logError(
          withCode: .opdsFeedParseFail,
          summary: "NYPLOPDSFeed: Failed to parse XML as OPDS",
          metadata: [
            "response": response ?? "N/A"
          ]
        )
        DispatchQueue.global().async { handler(nil, nil) }
        return
      }

      DispatchQueue.global().async { handler(feed, nil) }
    }
    // ObjC version captured originalRequest for logging; not needed here
    _ = task
  }
}
