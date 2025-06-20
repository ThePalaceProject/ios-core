#if LCP

import R2LCPClient
import ReadiumLCP
import ReadiumShared

enum LCPContextError: Error {
  case creationReturnedNil
}

let lcpService = LCPLibraryService()

class TPPLCPClient: ReadiumLCP.LCPClient {

  private var _context: LCPClientContext?
  private let contextLock = NSLock()
  
  deinit {
    contextLock.lock()
    _context = nil
    contextLock.unlock()
  }

  func createContext(
      jsonLicense: String,
      hashedPassphrase: String,
      pemCrl: String
    ) throws -> LCPClientContext {
      let newCtx: LCPClientContext = try {
        guard let ctx = try? R2LCPClient.createContext(
          jsonLicense: jsonLicense,
          hashedPassphrase: hashedPassphrase,
          pemCrl: pemCrl
        ) else {
          throw LCPContextError.creationReturnedNil
        }
        return ctx
      }()

      // 2) Store it under lock
      contextLock.lock()
      _context = newCtx
      contextLock.unlock()

      return newCtx
    }

  func decrypt(data: Data, using context: LCPClientContext) -> Data? {
    guard let drmContext = context as? DRMContext else { return nil }

    if Thread.isMainThread {
      return R2LCPClient.decrypt(data: data, using: drmContext)
    }

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

extension TPPLCPClient {
  func decrypt(data: Data) -> Data? {
    guard let drmContext = _context as? DRMContext else { return nil }

    if Thread.isMainThread {
      return R2LCPClient.decrypt(data: data, using: drmContext)
    }

    var result: Data?
    DispatchQueue.main.sync {
      result = R2LCPClient.decrypt(data: data, using: drmContext)
    }
    return result
  }
}

#endif
