#if LCP

import R2LCPClient
import ReadiumLCP
import ReadiumShared

enum LCPContextError: Error {
  case creationReturnedNil
}

let lcpService = LCPLibraryService()

/// Facade to the private R2LCPClient.framework.
class TPPLCPClient: ReadiumLCP.LCPClient {

  private var _context: LCPClientContext?
  public var context: LCPClientContext? {
    contextQueue.sync { _context }
  }

  private let contextQueue = DispatchQueue(
    label: "com.yourapp.tpplcpclient.contextQueue",
    qos: .userInitiated
  )
  
  deinit {
    contextQueue.sync {
      _context = nil
    }
  }

  func createContext(
     jsonLicense: String,
     hashedPassphrase: String,
     pemCrl: String
   ) throws -> LCPClientContext {
     var rawResult: LCPClientContext?
     var caughtError: Error?

     contextQueue.sync {
       do {
         rawResult = try R2LCPClient.createContext(
           jsonLicense: jsonLicense,
           hashedPassphrase: hashedPassphrase,
           pemCrl: pemCrl
         )
       } catch {
         caughtError = error
       }
     }

     if let error = caughtError {
       throw error
     }

     guard let newCtx = rawResult else {
       throw LCPContextError.creationReturnedNil
     }

     contextQueue.sync {
       self._context = newCtx
     }

     return newCtx
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
