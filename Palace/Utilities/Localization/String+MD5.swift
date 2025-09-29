// Adapted from: https://stackoverflow.com/a/31932898/9964065
// TODO: Migrate to new Crypto API coming soon

import CommonCrypto
import Foundation

public extension String {
  func md5() -> Data {
    let messageData = data(using: .utf8)!
    var digestData = Data(count: Int(CC_MD5_DIGEST_LENGTH))

    _ = digestData.withUnsafeMutableBytes { digestBytes in
      messageData.withUnsafeBytes { messageBytes in
        CC_MD5(messageBytes, CC_LONG(messageData.count), digestBytes)
      }
    }

    return digestData
  }

  func md5hex() -> String {
    md5().map { String(format: "%02hhx", $0) }.joined()
  }
}

@objc public extension NSString {
  func md5String() -> NSString {
    (self as String).md5hex() as NSString
  }
}
