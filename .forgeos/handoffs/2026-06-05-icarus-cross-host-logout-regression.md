# Handoff — Icarus repeated-logout regression: forensics + wall-building

**Created:** 2026-06-05 by Claude (Opus 4.8) during PP-4340 post-merge device testing.
**Status:** Root cause identified + regression commit pinned. Remaining: write walls, repair, test. Pick up in a clean session.
**NOT related to PP-4340** (the Readium 3.9.0 upgrade) — that merge touched zero auth/network/audiobook files. PP-4340 is merged and fine; this is a separate pre-existing develop bug surfaced during its device smoke.

---

## 1. Symptom

On device "Moes Max" (iPhone 17 Pro Max, iOS, signed into **Icarus Test Library** OIDC), the app **repeatedly logs out / pops the sign-in modal — once per minute**, indefinitely.

## 2. Root cause (confirmed from device logs)

Every minute, the **audiobook playtimes tracker** uploads listening time for an audiobook that was borrowed under **A1QA**:

```
POST https://gorgon.staging.palaceproject.io/a1qa-test/playtimes/14/URI/urn:uuid:2265844e-...
     body: { libraryId: urn:uuid:965eb2f9... (A1QA), timeEntries: [...] }
→ 401   "Error uploading audiobook tracker data"  (Code 902, problem doc)
```

…but the **active account is Icarus** (`currentAccountAuthDocURL = https://minotaur.dev.palaceproject.io/icarus-test-library/authentication_document`, a **different host**, `minotaur.dev` ≠ `gorgon.staging`).

`TPPNetworkResponder` handles that 401, `AuthErrorClassifier` does NOT short-circuit it (it's same-host gorgon→gorgon, so the existing *redirect*-based cross-domain guard doesn't fire), the account is browser-auth (OIDC) and the path isn't `/patrons/me`, so it dispatches:

```
TPPNetworkResponder: Server returned 401 for browser-based auth on action endpoint
  — dispatching coordinator with reason=oidcRefreshFailed (was: inline markCredentialsStale)
→ AuthCoordinator.refreshCredentialsIfNeeded(reason: .oidcRefreshFailed)
→ routes to .modal → presents the sign-in modal for the CURRENT (Icarus) account
```

So a **cross-library / cross-host 401 is misattributed to the current account's OIDC session**, and now (post-#1018) it *actively* drives a reauth modal — every minute.

Two compounding bugs:
- **Bug A (causes the visible logout):** the action-endpoint 401 handler doesn't verify the 401's host belongs to the **current account's auth surface** (auth-doc / loans / catalog host). The only host guard is `!response.isSameDomain(as: originalRequestURL)` in `AuthErrorClassifier.classifyCore` (line ~144) — that catches *redirect* cross-domain, not "same-host-but-not-this-account's-host."
- **Bug B (why the bad request exists):** the playtimes tracker keeps uploading for an A1QA book after the active library switched to Icarus. It should stop/scope on active-account change. (In `PalaceAudiobookToolkit` submodule + the Palace audiobook-session lifecycle.)

## 3. Regression pinpoint — it did NOT exist in 3.1.0

**Introduced by PR #1018** = commit `f380e37c3` "[swarm_66819d80] 3.2.0 auth architecture — AuthErrorClassifier + AuthCoordinator + isBrowserBased". This commit first added `AuthErrorClassifier` and rewrote the `TPPNetworkResponder` 401 branch.

Side-by-side of the **action-endpoint browser-auth 401** branch:

- **3.1.0** (`git show 3.1.0:Palace/Network/TPPNetworkResponder.swift`, ~line 459-462):
  ```swift
  // Mark credentials as stale - preserves Adobe DRM activation
  accountsManager.userAccount(for: accountId ?? "").markCredentialsStale()
  Log.info("... credentials marked stale; user-action paths will surface re-auth on next interaction")
  return false
  ```
  → **PASSIVE.** Marks stale; no active modal. A background playtimes 401 set the flag but did not pop a login; deferred to the next real user action (and `/patrons/me` success could reconcile). User-invisible in this scenario.

- **post-#1018** (`Palace/Network/TPPNetworkResponder.swift` ~line 497-513):
  ```swift
  let coordinator = AppContainer.production().authCoordinator
  let reason: ReauthReason = ... .oidcRefreshFailed ...
  Task { _ = await coordinator.refreshCredentialsIfNeeded(reason: reason) }
  return false
  ```
  → **ACTIVE.** `.oidcRefreshFailed` routes to `.modal` in `AuthCoordinator` (`AuthCoordinator.swift` ~line 418-427 `recoveryStrategy` switch → `presentModal`). Drives a sign-in modal every minute.

**Both** versions lack the host-vs-current-account guard (the latent misattribution is old), but 3.1.0's *passive* mark-stale masked it; #1018's *active* coordinator dispatch turned it into a visible, repeating logout. NOTE: the next session should also confirm whether the playtimes POST routed through `TPPNetworkResponder` in 3.1.0 at all (the `PalaceAudiobookToolkit` submodule networking may have changed) — that's a secondary thread, but the passive→active responder change is the primary regression.

## 4. How it got through (gap analysis — drives the walls)

1. **#1018 was a large auth-architecture swarm refactor.** Its tests (`Palace/Packages/PalaceAuth/Tests/PalaceAuthTests/AuthErrorClassifierPropertyTests.swift`) exercise cross-domain via **redirect** (URLs: gorgon/cdn/biblioboard/icarus, `response.url` vs `originalRequest.url`). They never test **same-host-but-not-current-account-host** (e.g., a `gorgon/<other-library>/playtimes` 401 while account = a `minotaur` library).
2. **No test pinned the behavioral change** passive-mark-stale → active-modal. There's no test asserting "a background / non-user-initiated action-endpoint 401 from a host that is not the current account's auth host must NOT present a reauth modal."
3. **The classifier has account context but doesn't use it for host scoping.** `AuthErrorClassifier` takes an account-UUID closure (see its header, ~line 32/47) but never compares the 401 host to the account's auth-doc/loans/catalog host.
4. **No multi-account × audiobook-playtimes integration test** — the scenario (audiobook from library A still posting playtimes after switching the active account to library B) is untested.
5. The **wall-failure catalog / round-trip rules** (CLAUDE.md) cover state-machine re-entry but had no clause for "auth-error classification must be scoped to the current account's host surface."

## 5. Walls to build (per CLAUDE.md "Wall-failure catalog" process)

Create `.forgeos/wall-failures/2026-06-05-pr1018-icarus-cross-host-logout.md` from `TEMPLATE.md`, classify the walls that should have caught it (TDD + reviewer + contract), and add **structurally-preventing** fixes:

1. **Repair test FIRST (TDD), proves the fix:**
   - In `AuthErrorClassifierPropertyTests` (or a new `AuthErrorClassifierHostScopingTests`): a 401 whose host is NOT the current account's auth-surface host classifies as `.ok` ("not our creds"). Drive with: account auth host = `minotaur.dev/icarus-test-library`, request URL = `gorgon.staging/a1qa-test/playtimes/...`, status 401 → expect `.ok` (or a new `.foreignHost` outcome that the responder treats as no-op).
   - A `TPPNetworkResponder` integration test: browser-auth (OIDC) account current, a playtimes-style cross-host 401 arrives → assert **no** `authCoordinator.refreshCredentialsIfNeeded` dispatch and **no** `markCredentialsStale` on the current account (spy the coordinator + account). This is the air-tight critical-path test the rigor bar demands.
2. **Production fix (Bug A):** before the action-endpoint reauth dispatch (`TPPNetworkResponder` ~line 485-513) — or inside `AuthErrorClassifier.classifyCore` — add a guard: if the request host is not the current account's auth-doc/loans/catalog host (nor a same-host of those), classify as `.ok`. Generalize the existing redirect-only cross-domain guard to "host ∉ current account's auth surface." The account's hosts are reachable via `accountsManager.currentAccount` / the auth document.
3. **Production fix (Bug B, root, likely separate ticket):** stop or re-scope the audiobook playtimes tracker when the active account changes (so it never posts cross-library). Lives in `PalaceAudiobookToolkit` + the Palace audiobook-session lifecycle. Confirm whether `ReaderService.stopActiveAudiobookSessionIfNeeded()` (reader-open path) has a library-switch analogue — there may be none.
4. **Structural wall (prevent recurrence):** add a check or contract test asserting any auth-error-classification path is account-host-scoped — e.g., a contract-snapshot test for `AuthErrorClassifier` that includes a foreign-host 401 row, wired so a future refactor that drops the host scoping drifts the snapshot and fails loudly. Consider a CLAUDE.md clause under "Risk-driven rigor bar": *"Any 401/credentials-stale decision must be scoped to the current account's auth-surface host; a 401 from a non-account host is never an account session expiry."*
5. **Mutation-verify** the new tests on the changed files (`AuthErrorClassifier.swift`, `TPPNetworkResponder.swift`) per check #5.

## 6. Ticket + process

- File a **new Jira ticket** (iOS) for this — it's a critical-path auth regression, separate from PP-4340. Reference PR #1018 as the regressing change.
- Use **`/rigorous-fix`** (single-module critical path: auth) — architect + SoD review required regardless of LOC.
- This is a **reviewer/TDD wall failure**: #1018's review + tests passed despite the missing host-scoping. The wall-failure entry is mandatory within 24h per CLAUDE.md; fix within 1 week.

## 7. Evidence / repro

- Device: "Moes Max" UDID `00008150-00142D540A87801C`. Capture: `idevicesyslog -u <udid> --process Palace`.
- Saved excerpt: `/tmp/icarus-evidence.txt` (ephemeral — re-capture if gone; the per-minute `browser-based auth on action endpoint` + `uploading audiobook tracker data` 401 lines are the signal).
- Repro: sign into a browser-auth (OIDC/SAML) library on host A; have a borrowed+playing audiobook from a *different* library on host B (e.g. A1QA `gorgon.staging`); the per-minute playtimes upload 401s and pops the host-A sign-in modal.

## 8. Key files

- `Palace/Network/TPPNetworkResponder.swift` (~440-534) — the 401 branch + coordinator dispatch.
- `Palace/Packages/PalaceAuth/Sources/PalaceAuth/AuthErrorClassifier.swift` (`classifyCore` ~119-173, cross-domain guard ~142-147).
- `Palace/Packages/PalaceAuth/Sources/PalaceAuth/AuthCoordinator.swift` (`refreshCredentialsIfNeeded` ~105, `recoveryStrategy` switch ~418-427 → `.modal`).
- `Palace/Packages/PalaceAuth/Tests/PalaceAuthTests/AuthErrorClassifierPropertyTests.swift` — extend here.
- Audiobook playtimes tracker: in `ios-audiobooktoolkit` submodule (grep `playtimes` / "uploading audiobook tracker data").
- Regression commit: `f380e37c3` (PR #1018). 3.1.0 baseline: `git show 3.1.0:Palace/Network/TPPNetworkResponder.swift`.

## Resolution log

| Bug | Resolved by | Date | Owning file | Notes |
|-----|-------------|------|-------------|-------|
| Bug B (playtimes cross-host upload) | swarm_162a3219 / Module C | 2026-06-05 | `Palace/Audiobooks/Tracker/AudiobookDataManager.swift` | Cross-account scope guard added to `syncValues()`: queued entries whose `libraryId` does not match `currentAccountIdProvider()` are skipped (POST never fires) but retained in the queue for flush on switch-back. `subscribeToAccountChanges()` observes `.TPPCurrentAccountDidChange` for diagnostic logging only (no destructive queue clear). Background-task counting fixed so the all-skip case ends `endBackgroundTask` cleanly. Commit SHA: TBD (filled in by integrator). |
| Bug A (action-endpoint 401 misattribution) | swarm_162a3219 / Module B (handled by foreign-host-401 detector + parallel inline guards) | 2026-06-05 | `Palace/Network/TPPNetworkResponder.swift`, `Palace/MyBooks/TokenRefreshInterceptor.swift`, `Palace/MyBooks/DownloadAuthRetryHandler.swift` | Per Module B's contract; tracked separately. |
