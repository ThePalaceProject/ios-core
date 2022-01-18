import Foundation

@objcMembers public class OverdriveToken: NSObject {
  let accessToken: String
  let scope: String
  let tokenType: String
  let expiryDate: Date
    
  init?(json: [String: Any]) {
    guard let scope = json["scope"] as? String,
      let accessToken = json["access_token"] as? String,
      let tokenType = json["token_type"] as? String,
      let expiryTime = json["expires_in"] as? Int else {
        return nil
    }
    
    self.scope = scope
    self.accessToken = accessToken
    self.tokenType = tokenType
    self.expiryDate = Date(timeIntervalSinceNow: Double(expiryTime))
  }
  
  public func isExpired() -> Bool {
    return expiryDate < Date()
  }
  
  override public var description: String {
    return """
    Overdrive Bearer Token Detail:
      Scope: \(String(describing: scope))
      Access token: \(String(describing: accessToken))
      Token Type: \(String(describing: tokenType))
      Expiry Date: \(String(describing: expiryDate))
    """
  }
}
