//
// TPPSignInBusinessLogic+ForceReset.swift
// The Palace Project
//
// "Reset This Library Account" — patron-self-service stuck-state recovery.
// Mirrors the cleanup work in TPPSignInBusinessLogic+SignOut.swift but
// runs UNCONDITIONALLY: every step proceeds regardless of whether the
// CM-side DELETE call succeeded. This is the difference that matters for
// patrons whose app is already broken (HelpSpot 17716 Cornell SAML and
// the broader pattern Carissa flagged on 2026-05-05) — Sign Out's network
// DELETE often hangs or fails for them, leaving downstream cleanup
// short-circuited and the patron stuck across delete-and-reinstall.
//
// What this clears (locally):
//   - FCM device-token registration with the CM (best-effort DELETE; no gating)
//   - Stored credentials in Keychain (`userAccount.removeAll`)
//   - Account.hasUpdatedToken flag
//   - bookDownloadsCenter + bookRegistry state for this library
//   - selectedIDP + samlHelper state
//   - NetworkExecutor cache + URLCache
//   - WKWebsiteDataStore.default() — ALL data types (cookies, local storage,
//     IndexedDB, the lot) — unconditionally
//   - Sets a one-shot flag so the NEXT OIDC `ASWebAuthenticationSession`
//     forces `prefersEphemeralWebBrowserSession = true`. This defeats the
//     Safari-shared-cookie reuse that survives app deletion for OIDC
//     libraries (PR #909 / cross-platform audit finding).
//
// What this does NOT clear (out of client reach):
//   - CM-side device-token rows for this patron (CM team intervention or
//     reaper task — recommended in audit)
//   - The library's IdP-side session at the identity provider
//   - iCloud-backup-restored stale state (next reset still helps once the
//     user re-launches and writes new state)
//
// Diagnostic: every step emits a `[RESET_ACCOUNT]` log line so a patron
// sysdiagnose can be grepped to confirm the reset ran end-to-end.
//
// Copyright © 2026 The Palace Project. All rights reserved.
//

import Foundation
import WebKit

extension TPPSignInBusinessLogic {

    /// UserDefaults key for the one-shot "use ephemeral browser session for
    /// the next OIDC sign-in" flag. Set by `performForceReset(...)`. Read
    /// (and cleared) by the OIDC sign-in entry points.
    public static let nextOIDCSessionEphemeralKey =
        "PalaceForceReset.nextOIDCSessionEphemeral"

    /// Reads-and-clears the one-shot ephemeral-session flag. Returns true
    /// exactly once after `performForceReset` set it; subsequent reads
    /// return false until the next reset. The OIDC sign-in code calls this
    /// to decide whether to force `prefersEphemeralWebBrowserSession = true`
    /// for this single session, defeating Safari-shared-cookie reuse.
    @objc public static func consumeNextOIDCSessionEphemeralFlag() -> Bool {
        let value = UserDefaults.standard.bool(forKey: nextOIDCSessionEphemeralKey)
        if value {
            UserDefaults.standard.removeObject(forKey: nextOIDCSessionEphemeralKey)
            Log.error(#file, "[RESET_ACCOUNT] consumed nextOIDCSessionEphemeral flag — next ASWebAuthenticationSession will use ephemeral cookies")
        }
        return value
    }

    /// Patron-driven force reset. UNCONDITIONALLY clears every piece of
    /// local state for this library account. Used by the Settings →
    /// Account → "Reset This Library Account" button.
    ///
    /// - Parameter completion: invoked on the main queue after every
    ///   cleanup step has finished (or skipped). Always called exactly once.
    @objc public func performForceReset(completion: @escaping () -> Void) {
        Log.error(#file, "[RESET_ACCOUNT] start — libraryAccountID=\(libraryAccountID)")

        // 1. Best-effort DELETE FCM token from CM. Don't gate any cleanup on
        //    the result — that's the bug Sign Out has when the patron's app
        //    is already in a broken state.
        if let account = libraryAccountsProvider.account(libraryAccountID) {
            NotificationService.shared.deleteToken(for: account)
            account.hasUpdatedToken = false
            Log.error(#file, "[RESET_ACCOUNT] step 1 ok — FCM token DELETE dispatched (fire-and-forget); hasUpdatedToken cleared")
        } else {
            Log.error(#file, "[RESET_ACCOUNT] step 1 skipped — no Account for libraryAccountID=\(libraryAccountID)")
        }

        // 2. Reset book downloads + registry for this library.
        bookDownloadsCenter.reset(libraryAccountID)
        bookRegistry.reset(libraryAccountID)
        Log.error(#file, "[RESET_ACCOUNT] step 2 ok — bookDownloadsCenter + bookRegistry reset for \(libraryAccountID)")

        // 2.5. Best-effort Adobe DRM device deauthorize. CRITICAL for the
        //      patron-visible "can borrow but can't read" symptom: server-side
        //      operations (borrow/return/sync) use the CM bearer token, but
        //      reading requires the local Adobe RMSDK device activation to
        //      decrypt the EPUB. When activation gets desynced (PP-3649,
        //      Crashlytics "On-demand Adobe device activation failed" — 89
        //      events / 15 users on 3.0.0), the patron downloads books fine
        //      but Read just spins. Without this deauth, Reset Account would
        //      clear credentials but the local activation files would persist
        //      — the next sign-in would try to refresh the broken activation
        //      instead of doing a clean activation, and the patron would stay
        //      stuck. Mirrors the call site in TPPSignInBusinessLogic+SignOut.swift
        //      `deauthorizeDevice()`. Fire-and-forget: RMSDK clears local
        //      activation state regardless of network result; success=false
        //      with E_DEACT_USER_MISMATCH or similar is expected for stuck
        //      patrons and that's exactly the case we want to recover.
        //      MUST run BEFORE step 3 (credential clear) — deauth needs the
        //      licensor + Adobe userID/deviceID stored on userAccount.
        deauthorizeDeviceForReset()

        // 3. Wipe stored credentials. After this, hasCredentials() returns
        //    false and any in-flight authenticated request will fail cleanly
        //    instead of replaying a stale token.
        userAccount.removeAll()
        selectedIDP = nil
        samlHelper.clearState()
        Log.error(#file, "[RESET_ACCOUNT] step 3 ok — userAccount.removeAll, selectedIDP=nil, samlHelper.clearState")

        // 4. Network + URL caches. Catches any cached responses that might
        //    replay stale auth state on next request.
        TPPNetworkExecutor.shared.clearCache()
        URLCache.shared.removeAllCachedResponses()
        Log.error(#file, "[RESET_ACCOUNT] step 4 ok — networkExecutor cache + URLCache cleared")

        // 5. Set the one-shot ephemeral-session flag for the next OIDC
        //    sign-in. Defeats Safari-shared-cookie reuse that otherwise
        //    survives app deletion for OIDC libraries.
        UserDefaults.standard.set(true, forKey: Self.nextOIDCSessionEphemeralKey)
        Log.error(#file, "[RESET_ACCOUNT] step 5 ok — nextOIDCSessionEphemeral flag set")

        // 6. WKWebsiteDataStore — ALL data types, unconditionally. This is
        //    the big one Sign Out gates on auth-type routing; reset doesn't.
        let dataStore = WKWebsiteDataStore.default()
        let dataTypes = WKWebsiteDataStore.allWebsiteDataTypes()
        let epoch = Date(timeIntervalSince1970: 0)
        dataStore.removeData(ofTypes: dataTypes, modifiedSince: epoch) {
            Log.error(#file, "[RESET_ACCOUNT] step 6 ok — WKWebsiteDataStore wiped (all types, since epoch)")
            Log.error(#file, "[RESET_ACCOUNT] complete — patron should be returned to sign-in flow")
            DispatchQueue.main.async {
                completion()
            }
        }
    }

    /// Best-effort Adobe DRM device deauthorize. Mirrors the licensor-parsing
    /// + deauthorize call from `TPPSignInBusinessLogic+SignOut.swift:337-396`,
    /// but fire-and-forget — Reset Account explicitly does NOT gate downstream
    /// cleanup on the deauth callback (the callback may never fire if Adobe's
    /// deauth endpoint is the thing that's broken). RMSDK clears the local
    /// activation files regardless of network result; that's what enables a
    /// clean re-activation on the next sign-in.
    ///
    /// Skipped (with log) when there's no DRM authorizer (e.g. -noDRM build)
    /// or no licensor (e.g. patron never activated). In those cases there's
    /// no Adobe state to clear and the rest of Reset proceeds unchanged.
    private func deauthorizeDeviceForReset() {
        guard let drmAuthorizer = drmAuthorizer else {
            Log.error(#file, "[RESET_ACCOUNT] step 2.5 skipped — no drmAuthorizer (likely -noDRM build)")
            return
        }
        guard let licensor = userAccount.licensor else {
            Log.error(#file, "[RESET_ACCOUNT] step 2.5 skipped — no licensor on userAccount (patron never activated)")
            return
        }

        var licensorItems = (licensor["clientToken"] as? String)?
            .replacingOccurrences(of: "\n", with: "")
            .components(separatedBy: "|")
        let tokenPassword = licensorItems?.last
        licensorItems?.removeLast()
        let tokenUsername = licensorItems?.joined(separator: "|")
        let adobeUserID = userAccount.userID
        let adobeDeviceID = userAccount.deviceID

        Log.error(#file, "[RESET_ACCOUNT] step 2.5 — dispatching DRM deauthorize (fire-and-forget)")

        drmAuthorizer.deauthorize(
            withUsername: tokenUsername,
            password: tokenPassword,
            userID: adobeUserID,
            deviceID: adobeDeviceID
        ) { success, error in
            // Non-success is expected for stuck patrons (E_DEACT_USER_MISMATCH
            // or similar) — RMSDK still clears local activation, which is what
            // matters for the next sign-in's clean re-activation.
            Log.error(#file, "[RESET_ACCOUNT] step 2.5 — DRM deauthorize callback (success=\(success), error=\(error?.localizedDescription ?? "nil")). Local activation cleared regardless.")
        }
    }
}
