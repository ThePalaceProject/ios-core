import Foundation

@objc class TPPMyBooksSimplifiedBearerToken: NSObject {

  @objc private(set) var accessToken: String
  @objc private(set) var expiration: Date
  @objc private(set) var location: URL

  @objc init(accessToken: String, expiration: Date, location: URL) {
    self.accessToken = accessToken
    self.expiration = expiration
    self.location = location
    super.init()
  }

  @objc static func simplifiedBearerToken(with dictionary: NSDictionary) -> TPPMyBooksSimplifiedBearerToken? {
    guard let locationString = dictionary["location"] as? String,
          let location = URL(string: locationString) else {
      return nil
    }

    guard let accessToken = dictionary["access_token"] as? String else {
      return nil
    }

    let expirationString = dictionary["expiration"] as? String
    let expirationSeconds = expirationString.flatMap { Int($0) } ?? 0

    let expiration: Date
    if expirationSeconds > 0 {
      expiration = Date(timeIntervalSinceNow: TimeInterval(expirationSeconds))
    } else {
      expiration = .distantFuture
    }

    return TPPMyBooksSimplifiedBearerToken(accessToken: accessToken, expiration: expiration, location: location)
  }
}
