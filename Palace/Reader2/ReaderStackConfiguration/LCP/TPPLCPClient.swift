#if LCP

import R2LCPClient
import ReadiumLCP
import ReadiumShared

let lcpService = LCPLibraryService()

/// Facade to the private R2LCPClient.framework.
class TPPLCPClient: ReadiumLCP.LCPClient {

  private var context: LCPClientContext?

  deinit {
    context = nil
  }

  func createContext(jsonLicense: String, hashedPassphrase: String, pemCrl: String) throws -> LCPClientContext {
    let newContext = try R2LCPClient.createContext(
      jsonLicense: jsonLicense,
      hashedPassphrase: hashedPassphrase,
      pemCrl: pemCrl
    )

    self.context = newContext
    return newContext
  }

  func decrypt(data: Data, using context: LCPClientContext) -> Data? {
    guard let drmContext = context as? DRMContext else {
      return nil
    }
    return R2LCPClient.decrypt(data: data, using: drmContext)
  }

  func findOneValidPassphrase(jsonLicense: String, hashedPassphrases: [String]) -> String? {
    return R2LCPClient.findOneValidPassphrase(jsonLicense: jsonLicense, hashedPassphrases: hashedPassphrases)
  }
}

/// Provides access to data decryptor
extension TPPLCPClient {
  func decrypt(data: Data) -> Data? {
    guard let drmContext = context as? DRMContext else {
      return nil
    }
    return R2LCPClient.decrypt(data: data, using: drmContext)
  }
}

#endif
