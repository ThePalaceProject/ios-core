#if LCP

import R2LCPClient
import ReadiumLCP
import ReadiumShared

let lcpService = LCPLibraryService()

/// Facade to the private R2LCPClient.framework.
class TPPLCPClient: ReadiumLCP.LCPClient {

  private var context: LCPClientContext?

  deinit {
    let oldContext = context
    context = nil
    if let toRelease = oldContext {
      DispatchQueue.main.sync {
        _ = toRelease
      }
    }
  }

  func createContext(
    jsonLicense: String,
    hashedPassphrase: String,
    pemCrl: String) throws -> LCPClientContext {
    var newContext: LCPClientContext!
    try DispatchQueue.main.sync {
      newContext = try R2LCPClient.createContext(
        jsonLicense: jsonLicense,
        hashedPassphrase: hashedPassphrase,
        pemCrl: pemCrl
      )
    }
    self.context = newContext
    return newContext
  }

  func decrypt(data: Data, using context: LCPClientContext) -> Data? {
    guard let drmContext = context as? DRMContext else { return nil }
    var decrypted: Data?
    DispatchQueue.main.sync {
      decrypted = R2LCPClient.decrypt(data: data, using: drmContext)
    }
    return decrypted
  }

  func findOneValidPassphrase(jsonLicense: String, hashedPassphrases: [String]) -> String? {
    return R2LCPClient.findOneValidPassphrase(jsonLicense: jsonLicense, hashedPassphrases: hashedPassphrases)
  }
}

/// Provides access to data decryptor
extension TPPLCPClient {
  func decrypt(data: Data) -> Data? {
    guard let drmContext = context as? DRMContext else { return nil }
    var result: Data?
    DispatchQueue.main.sync {
      result = R2LCPClient.decrypt(data: data, using: drmContext)
    }
    return result
  }
}

#endif
