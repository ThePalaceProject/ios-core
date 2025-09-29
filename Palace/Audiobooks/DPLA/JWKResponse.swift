//
//  JWKResponse.swift
//  The Palace Project
//
//  Created by Vladimir Fedorov on 31.08.2020.
//  Copyright © 2020 NYPL Labs. All rights reserved.
//

import Foundation
import PalaceAudiobookToolkit

// MARK: - JWKResponse

struct JWKResponse: Codable {
  let keys: [JWK]
}

// MARK: - JWK

struct JWK: Codable {
  /// Custom JWK structure in response
  private enum JWKKeys: String, CodingKey {
    case publickKeyEncoded = "http://www.feedbooks.com/audiobooks/signature/pem-key"
  }

  let publicKeyData: Data?
  // Need to manually parse the key with the Url as the key
  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: JWKKeys.self)
    let pemString = try container.decode(String.self, forKey: .publickKeyEncoded).replacingOccurrences(
      of: "\n",
      with: ""
    )
    publicKeyData = Data(base64Encoded: RSAUtils.stripPEMKeyHeader(pemString))
  }
}
