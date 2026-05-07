#if LCP

import R2LCPClient
import ReadiumLCP
import ReadiumShared
import PalaceAudiobookToolkit
import PalaceLogging

enum LCPContextError: Error {
    case creationReturnedNil
    case nativeException(name: String, reason: String)
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
        var caughtNativeException: NSException?

        // R2LCPClient → LCPWrapper (ObjC) → lcp::DRMService (C++) → Botan can
        // throw C++ exceptions that escape the binary framework's bridge
        // unhandled (notably Botan::Decoding_Error when the CRL bytes are
        // malformed). A Swift do/catch cannot catch those — they bypass the
        // Swift error machinery entirely and reach std::terminate. We catch
        // both NSException AND C++ exceptions here so a bad CRL surfaces as
        // a Swift-throwable error instead of crashing the app
        // (Crashlytics 0ca62d8244 — 27 users, 249 events).
        contextQueue.sync {
            caughtNativeException = TPPObjCExceptionCatcher.catchAllExceptions {
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
        }

        if let exception = caughtNativeException {
            let name = exception.name.rawValue
            let reason = exception.reason ?? "Unknown native exception"
            Log.error(#file, "LCP createContext threw native exception: \(name) — \(reason)")
            throw LCPContextError.nativeException(name: name, reason: reason)
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
