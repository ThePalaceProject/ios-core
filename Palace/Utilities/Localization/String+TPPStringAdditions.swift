import Foundation
import CommonCrypto

extension NSString {

  @objc func fileSystemSafeBase64DecodedString(usingEncoding encoding: UInt) -> String? {
    var s = (self as String)
      .replacingOccurrences(of: "-", with: "+")
      .replacingOccurrences(of: "_", with: "/")

    while s.count % 4 != 0 {
      s.append("=")
    }

    guard let data = Data(base64Encoded: s),
          let result = String(data: data, encoding: String.Encoding(rawValue: encoding)) else {
      return nil
    }
    return result
  }

  @objc func fileSystemSafeBase64EncodedString(usingEncoding encoding: UInt) -> String? {
    guard let data = (self as String).data(using: String.Encoding(rawValue: encoding)) else {
      return nil
    }
    return data.base64EncodedString()
      .trimmingCharacters(in: CharacterSet(charactersIn: "="))
      .replacingOccurrences(of: "+", with: "-")
      .replacingOccurrences(of: "/", with: "_")
  }

  @objc func sha256() -> String {
    guard let data = (self as String).data(using: .utf8) else { return "" }
    var hash = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
    data.withUnsafeBytes {
      _ = CC_SHA256($0.baseAddress, CC_LONG(data.count), &hash)
    }
    return hash.map { String(format: "%02x", $0) }.joined()
  }

  @objc func stringURLEncodedAsQueryParamValue() -> String? {
    var allowedCharacters = CharacterSet.urlQueryAllowed
    allowedCharacters.remove(charactersIn: ";/?:@&=$+,")
    return (self as String).addingPercentEncoding(withAllowedCharacters: allowedCharacters)
  }

  @objc var isEmptyNoWhitespace: Bool {
    return (self as String).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }
}
