#if canImport(UIKit)
import Foundation
import Security

/// Keychain-backed store for the Anthropic API key.
///
/// **Why Keychain, not source / Info.plist / .xcconfig / TPPSecrets.**
/// A key baked into the app binary ships to every TestFlight tester and every
/// App Store user; `strings Palace.app/Palace` extracts it in seconds. The
/// only client-side answer that doesn't leak via binary inspection is to
/// store the key in the iOS Keychain, where it lives encrypted at rest
/// behind the secure enclave. The key never touches source control,
/// xcconfig, Info.plist, or any committed file.
///
/// **Bootstrap path for DEBUG builds.** The key gets INTO the keychain via
/// `bootstrapFromEnvironmentIfNeeded()`, which reads the
/// `ANTHROPIC_API_KEY` env var (set in the engineer's Xcode scheme,
/// xcuserdata, which is gitignored), writes it to Keychain, and clears.
/// After first launch the env var is no longer needed; subsequent runs
/// (including TestFlight installs on the same device) read from Keychain.
///
/// **Production path.** A server proxy holds the key; the app authenticates
/// to the proxy with the patron's existing session. Not in scope for
/// the June 9 demo.
public struct AnthropicKeyStore: Sendable {

    public static let serviceName = "org.thepalaceproject.palace.triagebot"
    public static let accountName = "anthropic.api.key.v1"

    public init() {}

    /// Returns the stored key, or nil if not present.
    public func read() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.serviceName,
            kSecAttrAccount as String: Self.accountName,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess,
              let data = item as? Data,
              let value = String(data: data, encoding: .utf8) else {
            return nil
        }
        return value
    }

    /// Stores the key. Overwrites any existing entry.
    @discardableResult
    public func write(_ key: String) -> Bool {
        guard let data = key.data(using: .utf8) else { return false }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.serviceName,
            kSecAttrAccount as String: Self.accountName
        ]
        SecItemDelete(query as CFDictionary)
        var insert = query
        insert[kSecValueData as String] = data
        insert[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(insert as CFDictionary, nil)
        return status == errSecSuccess
    }

    /// Deletes the stored key. Returns true if a key was deleted, false if
    /// none was present.
    @discardableResult
    public func delete() -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.serviceName,
            kSecAttrAccount as String: Self.accountName
        ]
        return SecItemDelete(query as CFDictionary) == errSecSuccess
    }

    /// DEBUG-only first-launch bootstrap. Reads ANTHROPIC_API_KEY from the
    /// process environment (set in the engineer's Xcode scheme), writes it
    /// to Keychain if non-empty AND Keychain doesn't already hold a key.
    /// Always returns the currently-stored key (which may now be from env).
    ///
    /// Safe to call on every app launch — idempotent, fast (~1ms Keychain
    /// lookup). In RELEASE builds this method skips the env-var read and
    /// returns whatever Keychain has (typically nothing, which keeps the
    /// AI fallback disabled until the server-proxy path lands).
    @discardableResult
    public func bootstrapFromEnvironmentIfNeeded() -> String? {
        if let existing = read(), !existing.isEmpty {
            return existing
        }
        #if DEBUG
        let env = ProcessInfo.processInfo.environment["ANTHROPIC_API_KEY"] ?? ""
        let trimmed = env.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard write(trimmed) else { return nil }
        return trimmed
        #else
        return nil
        #endif
    }
}
#endif
