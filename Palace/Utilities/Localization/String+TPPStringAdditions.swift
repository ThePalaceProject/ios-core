import Foundation
import CommonCrypto

extension NSString {

  /// Decodes a filesystem-safe base64 string.
  @objc func fileSystemSafeBase64DecodedString(usingEncoding encoding: UInt) -> String? {
    var s = (self as String)
      .replacingOccurrences(of: "-", with: "+")
      .replacingOccurrences(of: "_", with: "/")

    while s.count % 4 != 0 {
      s.append("=")
    }

    guard let data = Data(base64Encoded: s, options: []) else { return nil }
    return String(data: data, encoding: String.Encoding(rawValue: encoding))
  }

  /// Encodes a string to filesystem-safe base64.
  @objc func fileSystemSafeBase64EncodedString(usingEncoding encoding: UInt) -> String? {
    guard let data = (self as String).data(using: String.Encoding(rawValue: encoding)) else {
      return nil
    }
    return data.base64EncodedString(options: [])
      .trimmingCharacters(in: CharacterSet(charactersIn: "="))
      .replacingOccurrences(of: "+", with: "-")
      .replacingOccurrences(of: "/", with: "_")
  }

  /// Returns the SHA-256 hash of the string as a lowercase hex string.
  @objc(SHA256)
  func sha256() -> String {
    let data = (self as String).data(using: .utf8)!
    var hash = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
    data.withUnsafeBytes {
      _ = CC_SHA256($0.baseAddress, CC_LONG(data.count), &hash)
    }
    return hash.map { String(format: "%02x", $0) }.joined()
  }

  /// URL-encodes the string for use as a query parameter value.
  @objc func stringURLEncodedAsQueryParamValue() -> String? {
    var allowedCharacters = CharacterSet.urlQueryAllowed
    allowedCharacters.remove(charactersIn: ";/?:@&=$+,")
    return (self as String).addingPercentEncoding(withAllowedCharacters: allowedCharacters)
  }

  /// Returns true if the string is empty after trimming whitespace.
  @objc func isEmptyNoWhitespace() -> Bool {
    return (self as String)
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .isEmpty
  }
}
