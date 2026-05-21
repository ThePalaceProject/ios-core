# Contract: Notifications-OPDS-Errors

**Bucket items:** P1 #6 (Notifications-FCM SAML-stale retry) + P2 #9 (OPDS user-facing error strings) + P3 #11 (Info.plist UIBackgroundModes verify)
**Priority:** P1 / P2 / P3 — folded into one implementer per CLAUDE.md "200–600 LOC sweet spot." Item #11 is a 30-second verification.
**LOC estimate:** ~250–350 LOC (production + tests)

## Scope summary

Three small, independent changes folded into one implementer because each is too small to justify its own bucket:

1. **`NotificationService.updateToken` silent skip on stale SAML (line 180–237)** — when the user account is in `.credentialsStale` state, `getProfileDocument` returns nil and the FCM registration aborts (line 197–200) with only a log line. There is no retry trigger when credentials transition back to `.loggedIn`. Patrons who briefly enter `.credentialsStale` (e.g. SAML cookie expired but bearer is fine, then re-auth happens) never re-register their FCM token until app cold-launch / sign-out / library switch. Need: subscribe to `accountsManager` auth-state-change publisher; when state transitions to `.loggedIn` AND `hasUpdatedToken == false`, schedule one `updateToken()` retry. Use Combine — there's already a state machine in `NotificationServiceStateMachineTests` to guide.
2. **`PalaceError.opdsFeedInvalid` raw string "Invalid OPDS feed" (line 296)** — user-visible, untranslated, technical jargon. Replace with a localized, plain-language message: roughly "We couldn't load this catalog. Please try again or contact your library." (final wording per design — but DO NOT ship new copy without design approval; flag this in the PR description and use a placeholder NSLocalizedString key the design team can wire later). Memory ref: `feedback_no_new_copy_without_design`. The implementer MUST surface this in the PR description for human review.
3. **`OPDSFeedService.swift` line 86 fallback `PalaceError.parsing(.opdsFeedInvalid)`** — same underlying issue. When the network completes without a problem document AND without an error, we currently throw `opdsFeedInvalid` with no context. Consider whether this branch is actually reachable (it shouldn't be — the URLSession completion always has either error or data); if it's reachable, the message needs the same treatment as #9. If not reachable, document with a `Log.error` + `assertionFailure` in debug builds.
4. **Info.plist UIBackgroundModes (item #11) — ALREADY SATISFIED.** `PalaceConfig/Palace-Info.plist` confirmed to include `audio` in `UIBackgroundModes` array. The "verify" task is complete; the implementer just confirms in the PR description and notes file path `PalaceConfig/Palace-Info.plist` (NOT `Palace/Info.plist` as the original spec said — path drift confirmed).

## Files in scope

- `Palace/Notifications/NotificationService.swift` (lines ~180–237 + an auth-state-change subscription, probably in init or `start()`)
- `Palace/ErrorHandling/PalaceError.swift` (line 296 message change; add NSLocalizedString key)
- `Palace/OPDS2/OPDSFeedService.swift` (line 86 — audit reachability, fix if reachable)
- `PalaceTests/Notifications/NotificationServiceTokenTests.swift` (extend)
- `PalaceTests/Notifications/NotificationServiceStateMachineTests.swift` (extend — this is the right home for the state-transition retry)
- `PalaceTests/ErrorHandling/PalaceErrorTests.swift` (extend — pin new messages)
- `PalaceTests/OPDS2/OPDSFeedServiceTests.swift` (extend if line 86 logic changes)
- `PalaceConfig/Palace-Info.plist` — VERIFY ONLY, no edits expected.

## Files OFF-LIMITS

- Anything in `Palace/Reader2/`, `Palace/Audiobooks/`, `Palace/MyBooks/`.
- `Palace/Accounts/` — even though `accountsManager` is referenced, you do NOT modify accounts code. Subscribe to its public publisher only.
- Localized .strings files — see "user-facing copy" rule below.

## Public type / protocol / signature changes

- **None expected.** `NotificationService.updateToken` already exists; the auth-state subscription is internal init wiring. If `NotificationService` doesn't take `accountsManager` via DI yet (it does — see line 192), confirm and reuse.
- `PalaceError` message strings change but the enum cases do NOT. Pure string swap.

## DI seam updates

- `NotificationService` already injects `accountsManager` (used at line 181, 192, 195). Hook into its existing publisher — there's a `currentAccount` change publisher and an auth-state-change publisher already used elsewhere. Do NOT add a new singleton subscription.
- If you need to inject a Combine scheduler for testability, use the closure-default pattern from `feedback_test_patterns_phase7`.

## Test contracts

### `NotificationServiceStateMachineTests` (extend; mutation-killing recommended)

- `testAuthStateTransition_staleToLoggedIn_triggersTokenRetry` — feed a stub `accountsManager` two state values; assert `updateToken` is called exactly once on the transition. Use a `CallLog` recorder, not real Messaging.
- `testAuthStateTransition_loggedInToStale_doesNotTriggerRetry` — opposite direction must not fire.
- `testAuthStateTransition_loggedInToLoggedIn_doesNotTriggerRetry` — idempotency guard.
- `testHasUpdatedTokenTrue_blocksRetryOnTransition` — even on the right transition, if `hasUpdatedToken == true` already, do not retry.
- All tests use a fake `accountsManager` with a `PassthroughSubject<AuthState, Never>`. NEVER real Firebase, NEVER `.shared`.

### `NotificationServiceTokenTests` (extend)

- `testUpdateToken_profileDocumentNil_doesNotLatchHasUpdatedToken` — pin existing behavior (regression guard for the HelpSpot 17680 fix).
- Verify all four `[FCM_REG]` log markers still fire on the appropriate branches.

### `PalaceErrorTests` (extend)

- `testOpdsFeedInvalid_errorDescriptionIsUserFacing` — assert the new message is non-empty, not the literal "Invalid OPDS feed", and contains plain-language guidance. **Do not assert the exact final wording** — use `XCTAssertFalse(msg.contains("OPDS"))` instead. This lets design tweak copy without breaking tests.
- `testOpdsFeedInvalid_recoverySuggestionPresent` — assert `recoverySuggestion` is non-nil.

### `OPDSFeedServiceTests` (extend, only if line 86 branch is reachable)

- If the branch IS reachable, test it returns the new error. If NOT reachable, no test change needed; document the audit in the PR.

## Acceptance criteria

- `scripts/verify-pr.sh --quick` passes.
- Mutation kill rate ≥50% on `NotificationService.swift` diff-scoped. Token-retry branch must kill at least one mutant.
- Info.plist verification confirmed in PR body: "PalaceConfig/Palace-Info.plist UIBackgroundModes already contains 'audio' — no change needed."
- **User-facing copy rule (CRITICAL):** the new OPDS error message MUST be flagged in the PR description as "NEW USER-FACING COPY — REQUIRES DESIGN APPROVAL." Use a placeholder NSLocalizedString key (`"opds.error.feed_invalid"` or similar) the design team can override. Do not invent final wording. Memory ref: `feedback_no_new_copy_without_design`.
- No `.shared`, no real Firebase, no real network in tests.
- No new public APIs.
- Commit message has `**Scope:**` + `**Not done:**` stanzas. The `**Not done:**` stanza should explicitly note: "Final OPDS error wording awaits design review; placeholder key used."
- DO NOT commit. DO NOT push.
