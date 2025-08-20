import Foundation

public final class OPDSParser {
  func parseFeed(from data: Data) throws -> CatalogFeed {
    guard let xml = TPPXML(data: data) else {
      throw NSError(domain: NSURLErrorDomain, code: NSURLErrorCannotParseResponse)
    }
    let feed = TPPOPDSFeed(xml: xml)
    guard let catalogFeed = CatalogFeed(feed: feed) else {
      throw NSError(domain: NSURLErrorDomain, code: NSURLErrorCannotParseResponse)
    }
    return catalogFeed
  }
}


