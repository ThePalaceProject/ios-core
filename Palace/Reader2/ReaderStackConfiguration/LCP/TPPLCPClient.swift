//
//  TPPLCPClient.swift
//  Palace
//
//  Created by Vladimir Fedorov on 25.08.2021.
//  Copyright © 2021 The Palace Project. All rights reserved.
//
//  This framework facade is required by LCP as described here:
//  https://github.com/readium/r2-lcp-swift/blob/888417b0563c2dc56f80209542bc51c54a0b5e32/README.md

#if LCP

import R2LCPClient
import ReadiumLCP

let lcpService = LCPService(client: TPPLCPClient())

/// Facade to the private R2LCPClient.framework.
class TPPLCPClient: ReadiumLCP.LCPClient {
  func createContext(jsonLicense: String, hashedPassphrase: String, pemCrl: String) throws -> LCPClientContext {
    return try R2LCPClient.createContext(jsonLicense: jsonLicense, hashedPassphrase: hashedPassphrase, pemCrl: pemCrl)
  }

  func decrypt(data: Data, using context: LCPClientContext) -> Data? {
    return R2LCPClient.decrypt(data: data, using: context as! DRMContext)
  }

  func findOneValidPassphrase(jsonLicense: String, hashedPassphrases: [String]) -> String? {
    return R2LCPClient.findOneValidPassphrase(jsonLicense: jsonLicense, hashedPassphrases: hashedPassphrases)
  }
}

#endif
