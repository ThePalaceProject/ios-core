#if LCP

import R2LCPClient
import ReadiumLCP
import ReadiumShared
import PalaceAudiobookToolkit
import PalaceLogging

enum LCPContextError: Error {
    case creationReturnedNil
    case nativeException(name: String, reason: String)
    /// The pemCrl input did not look like a PEM-encoded X509 CRL.
    /// Defense-in-depth — Botan's BER parser used to crash with an
    /// uncaught C++ exception (Crashlytics 0ca62d8244, 11 users on
    /// 3.0.0) when the server returned HTML / JSON / partial bytes.
    /// The ObjC++ exception wrapper now catches that, but it's faster
    /// to reject up front and easier to diagnose from the log.
    case invalidPemCrl(prefix: String)
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
        // F-002 defense-in-depth: pre-validate the PEM CRL header before
        // handing it to the C++ Botan parser. A valid X509 CRL in PEM form
        // starts with the literal "-----BEGIN X509 CRL-----" marker. When the
        // server returns HTML/JSON/partial bytes, Botan throws an uncaught
        // Decoding_Error that the wrapper below catches — but rejecting up
        // front gives a much cleaner failure mode (clear log, no native frame
        // in the crash report, no wasted C++ entry/exit) and lets us see in
        // logs how often this happens in the wild.
        let trimmed = pemCrl.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty && !trimmed.hasPrefix("-----BEGIN X509 CRL-----") {
            let prefix = String(trimmed.prefix(40))
            Log.error(#file, "LCP createContext: pemCrl does not look like a PEM-encoded CRL (prefix: \(prefix)) — rejecting before Botan parse")
            throw LCPContextError.invalidPemCrl(prefix: prefix)
        }

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
                LCPPDFOpenProgress.shared.recordDecrypt(byteCount: data.count)
            }
            return decrypted
        } catch {
            Log.error(#file, "Exception during decryption: \(error)")
            return nil
        }
    }

    func findOneValidPassphrase(jsonLicense: String, hashedPassphrases: [String]) -> String? {
        // F-002 symmetric gap: R2LCPClient.findOneValidPassphrase → Botan can
        // throw C++ exceptions (notably std::logic_error "id value cannot not
        // be null" on empty license JSON, "expected null, got not" on non-JSON
        // license strings) that escape Swift's do/catch entirely and reach
        // std::terminate. Mirror the createContext wrapper so a bad license
        // surfaces as a nil return ("no valid passphrase found") instead of a
        // crash. Returning nil is the same shape callers already handle for
        // the no-match case, so no upstream contract changes.
        var result: String?
        let caughtNativeException = TPPObjCExceptionCatcher.catchAllExceptions {
            result = R2LCPClient.findOneValidPassphrase(
                jsonLicense: jsonLicense,
                hashedPassphrases: hashedPassphrases
            )
        }

        if let exception = caughtNativeException {
            let name = exception.name.rawValue
            let reason = exception.reason ?? "Unknown native exception"
            Log.error(#file, "LCP findOneValidPassphrase threw native exception: \(name) — \(reason)")
            return nil
        }

        return result
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
                LCPPDFOpenProgress.shared.recordDecrypt(byteCount: data.count)
            }
            return result
        } catch {
            Log.error(#file, "Exception during decryption: \(error)")
            return nil
        }
    }
}

#endif
