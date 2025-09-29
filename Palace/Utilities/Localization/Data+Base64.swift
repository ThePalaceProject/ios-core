import Foundation

public extension Data {
  func base64EncodedStringUrlSafe() -> String {
    base64EncodedString()
      .replacingOccurrences(of: "+", with: "-")
      .replacingOccurrences(of: "/", with: "_")
      .replacingOccurrences(of: "\n", with: "")
  }
}
