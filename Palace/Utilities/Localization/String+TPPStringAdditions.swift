// Swift replacement for NSString+TPPStringAdditions.m
//
// String utility extensions for base64, hashing, URL encoding, and whitespace checks.

import Foundation
import CommonCrypto

extension String {

  /// Decodes a filesystem-safe base64 string using the given encoding.
  /// Replaces `-` with `+` and `_` with `/`, and re-pads with `=`.
  func fileSystemSafeBase64DecodedString(encoding: String.Encoding) -> String? {
    var s = self
      .replacingOccurrences(of: "-", with: "+")
      .replacingOccurrences(of: "_", with: "/")

    while s.count % 4 != 0 {
      s.append("=")
    }

    guard let data = Data(base64Encoded: s) else { return nil }
    return String(data: data, encoding: encoding)
  }

  /// Encodes a string as filesystem-safe base64 using the given encoding.
  /// Strips `=` padding, replaces `+` with `-` and `/` with `_`.
  func fileSystemSafeBase64EncodedString(encoding: String.Encoding) -> String? {
    guard let data = self.data(using: encoding) else { return nil }
    return data.base64EncodedString()
      .trimmingCharacters(in: CharacterSet(charactersIn: "="))
      .replacingOccurrences(of: "+", with: "-")
      .replacingOccurrences(of: "/", with: "_")
  }

  /// Returns the SHA-256 hex digest of the string (UTF-8 encoded).
  func sha256() -> String {
    let data = Data(self.utf8)
    var hash = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
    data.withUnsafeBytes {
      _ = CC_SHA256($0.baseAddress, CC_LONG(data.count), &hash)
    }
    return hash.map { String(format: "%02x", $0) }.joined()
  }

  /// Returns a percent-encoded string suitable for use as a URL query parameter value.
  var stringURLEncodedAsQueryParamValue: String? {
    var allowed = CharacterSet.urlQueryAllowed
    allowed.remove(charactersIn: ";/?:@&=$+,")
    return self.addingPercentEncoding(withAllowedCharacters: allowed)
  }

  /// Returns true if the string is empty after trimming whitespace and newlines.
  var isEmptyNoWhitespace: Bool {
    return self.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }
}

// MARK: - NSString ObjC compatibility

extension NSString {

  @objc(fileSystemSafeBase64DecodedStringUsingEncoding:)
  func _fileSystemSafeBase64DecodedString(encoding: UInt) -> NSString? {
    return (self as String).fileSystemSafeBase64DecodedString(
      encoding: String.Encoding(rawValue: encoding)
    ) as NSString?
  }

  @objc(fileSystemSafeBase64EncodedStringUsingEncoding:)
  func _fileSystemSafeBase64EncodedString(encoding: UInt) -> NSString? {
    return (self as String).fileSystemSafeBase64EncodedString(
      encoding: String.Encoding(rawValue: encoding)
    ) as NSString?
  }

  @objc(SHA256)
  func _sha256() -> NSString {
    return (self as String).sha256() as NSString
  }

  @objc(stringURLEncodedAsQueryParamValue)
  var _stringURLEncodedAsQueryParamValue: NSString? {
    return (self as String).stringURLEncodedAsQueryParamValue as NSString?
  }

  @objc(isEmptyNoWhitespace)
  var _isEmptyNoWhitespace: Bool {
    return (self as String).isEmptyNoWhitespace
  }
}
