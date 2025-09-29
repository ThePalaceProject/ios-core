import Foundation

public final class OPDSParser {
  public enum ParserError: Error, LocalizedError {
    case invalidXML
    case invalidFeed

    public var errorDescription: String? {
      switch self {
      case .invalidXML: "Unable to parse OPDS XML."
      case .invalidFeed: "Invalid or unsupported OPDS feed format."
      }
    }
  }

  func parseFeed(from data: Data) throws -> CatalogFeed {
    guard let xml = TPPXML(data: data) else {
      throw ParserError.invalidXML
    }
    let feed = TPPOPDSFeed(xml: xml)
    guard let catalogFeed = CatalogFeed(feed: feed) else {
      throw ParserError.invalidFeed
    }
    return catalogFeed
  }
}
