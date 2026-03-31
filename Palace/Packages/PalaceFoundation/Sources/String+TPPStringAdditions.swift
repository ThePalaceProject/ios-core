import Foundation
import CommonCrypto

extension String {

  /// Decodes a filesystem-safe base64 string.
  public func fileSystemSafeBase64DecodedString() -> String? {
    var s = self
      .replacingOccurrences(of: "-", with: "+")
      .replacingOccurrences(of: "_", with: "/")

    while s.count % 4 != 0 {
      s.append("=")
    }

    guard let data = Data(base64Encoded: s, options: []) else { return nil }
    return String(data: data, encoding: .utf8)
  }

  /// Encodes a string to filesystem-safe base64.
  public func fileSystemSafeBase64EncodedString() -> String? {
    guard let data = self.data(using: .utf8) else {
      return nil
    }
    return data.base64EncodedString(options: [])
      .trimmingCharacters(in: CharacterSet(charactersIn: "="))
      .replacingOccurrences(of: "+", with: "-")
      .replacingOccurrences(of: "/", with: "_")
  }

  /// Returns the SHA-256 hash of the string as a lowercase hex string.
  public func sha256() -> String {
    let data = self.data(using: .utf8)!
    var hash = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
    data.withUnsafeBytes {
      _ = CC_SHA256($0.baseAddress, CC_LONG(data.count), &hash)
    }
    return hash.map { String(format: "%02x", $0) }.joined()
  }

  /// URL-encodes the string for use as a query parameter value.
  public func urlEncodedAsQueryParamValue() -> String? {
    var allowedCharacters = CharacterSet.urlQueryAllowed
    allowedCharacters.remove(charactersIn: ";/?:@&=$+,")
    return self.addingPercentEncoding(withAllowedCharacters: allowedCharacters)
  }

  /// Returns true if the string is empty after trimming whitespace.
  public func isEmptyNoWhitespace() -> Bool {
    return self
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .isEmpty
  }
}
