#if LCP

import R2LCPClient
import ReadiumLCP
import ReadiumShared
import PalaceAudiobookToolkit
import PalaceLogging
import UIKit

/// Per-process LRU cache of decrypted blocks, keyed by the ciphertext
/// bytes. PDFNavigator walks the PDF cross-ref table on every open,
/// and many blocks (especially the cross-ref index and font tables)
/// are requested repeatedly within the same render pass — caching the
/// decrypted output skips the AES work for every repeat hit, which is
/// what dominates open time on large Marketplace LCP PDFs.
///
/// `NSCache` auto-evicts under memory pressure (matched against
/// `totalCostLimit`), so the cache cannot itself contribute to an OOM
/// on a device that's already tight. The 16MB cap is intentionally
/// conservative: it's enough to hold all the cross-ref + first-page
/// blocks for a typical 50MB book but small enough that the OS will
/// reclaim it before evicting the foreground app.
///
/// `NotificationCenter` listener purges everything on a system memory
/// warning (or our pre-emptive `ReaderService.openPDF` notification).
/// `@unchecked Sendable` invariant: the sole stored property `cache` is an
/// immutable `let` and `NSCache` is documented thread-safe, so concurrent
/// `decrypted(for:)` / `store(_:for:)` calls are safe. The observer is
/// registered once in `init`, and `handleMemoryWarning` only calls the
/// thread-safe `removeAllObjects()`. No unsynchronized mutable state exists.
private final class LCPDecryptCache: @unchecked Sendable {
    static let shared = LCPDecryptCache()
    private let cache = NSCache<NSData, NSData>()

    private init() {
        cache.totalCostLimit = 16 * 1024 * 1024  // 16MB
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleMemoryWarning),
            name: UIApplication.didReceiveMemoryWarningNotification,
            object: nil
        )
    }

    @objc private func handleMemoryWarning() {
        cache.removeAllObjects()
    }

    func decrypted(for ciphertext: Data) -> Data? {
        cache.object(forKey: ciphertext as NSData) as Data?
    }

    func store(_ plaintext: Data, for ciphertext: Data) {
        cache.setObject(plaintext as NSData, forKey: ciphertext as NSData, cost: plaintext.count)
    }
}

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

        // Cache hit: same ciphertext bytes → same plaintext (LCP keys
        // are per-license and stable for the open lifetime). Skips the
        // R2LCPClient AES round-trip entirely.
        if let cached = LCPDecryptCache.shared.decrypted(for: data) {
            LCPPDFOpenProgress.shared.recordDecrypt(byteCount: data.count, fromCache: true)
            return cached
        }

        do {
            let decrypted = R2LCPClient.decrypt(data: data, using: drmContext)
            if let decrypted {
                // Per-call success log dropped intentionally — at ~7k
                // calls/s during a PDF cross-ref walk the string
                // formatting + log-system writes were measurable
                // memory churn on the device. The progress reporter +
                // periodic [PERF] [LCP-PDF] residentMB line carry the
                // same information without the per-call cost.
                LCPDecryptCache.shared.store(decrypted, for: data)
                LCPPDFOpenProgress.shared.recordDecrypt(byteCount: data.count)
            } else {
                Log.error(#file, "R2LCPClient.decrypt returned nil for \(data.count) bytes")
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

    /// PP-4848 (Readium 3.11): `LCPClient` now requires this. Readium ships a
    /// hardcoded default list, but forwarding the value liblcp actually reports
    /// is what lets Readium surface the correct "profile not supported" error
    /// for a license whose profile the embedded `R2LCPClient` can't handle,
    /// instead of failing opaquely. `R2LCPClient.getSupportedLCPProfileURIs()`
    /// returns an optional; an empty list is the honest "none advertised" value.
    func getSupportedLCPProfileURIs() -> [String] {
        R2LCPClient.getSupportedLCPProfileURIs() ?? []
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

        if let cached = LCPDecryptCache.shared.decrypted(for: data) {
            LCPPDFOpenProgress.shared.recordDecrypt(byteCount: data.count, fromCache: true)
            return cached
        }

        do {
            let result = R2LCPClient.decrypt(data: data, using: drmContext)
            if let result {
                LCPDecryptCache.shared.store(result, for: data)
                LCPPDFOpenProgress.shared.recordDecrypt(byteCount: data.count)
            } else {
                Log.error(#file, "R2LCPClient.decrypt returned nil for \(data.count) bytes")
            }
            return result
        } catch {
            Log.error(#file, "Exception during decryption: \(error)")
            return nil
        }
    }
}

#endif
