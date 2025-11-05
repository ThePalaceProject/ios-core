#if LCP

import R2LCPClient
import ReadiumLCP
import ReadiumShared
import PalaceAudiobookToolkit

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
    guard let drmContext = context as? DRMContext else { 
      Log.error(#file, "Invalid DRM context for decryption")
      return nil 
    }
    
    guard !data.isEmpty else {
      Log.error(#file, "Cannot decrypt empty data")
      return nil
    }
    
    do {
      let decrypted = R2LCPClient.decrypt(data: data, using: drmContext)
      if decrypted == nil {
        Log.error(#file, "R2LCPClient.decrypt returned nil for \(data.count) bytes")
      } else {
        Log.debug(#file, "Successfully decrypted \(data.count) bytes -> \(decrypted?.count ?? 0) bytes")
      }
      return decrypted
    } catch {
      Log.error(#file, "Exception during decryption: \(error)")
      return nil
    }
  }

  func findOneValidPassphrase(jsonLicense: String, hashedPassphrases: [String]) -> String? {
    return R2LCPClient.findOneValidPassphrase(jsonLicense: jsonLicense, hashedPassphrases: hashedPassphrases)
  }
}

extension TPPLCPClient {
  func decrypt(data: Data) -> Data? {
    guard let drmContext = context as? DRMContext else { 
      Log.error(#file, "No valid DRM context available for decryption")
      return nil 
    }
    
    guard !data.isEmpty else {
      Log.error(#file, "Cannot decrypt empty data")
      return nil
    }
    
    do {
      let result = R2LCPClient.decrypt(data: data, using: drmContext)
      if result == nil {
        Log.error(#file, "R2LCPClient.decrypt returned nil for \(data.count) bytes")
      } else {
        Log.debug(#file, "Successfully decrypted \(data.count) bytes -> \(result?.count ?? 0) bytes")
      }
      return result
    } catch {
      Log.error(#file, "Exception during decryption: \(error)")
      return nil
    }
  }
}

#endif
