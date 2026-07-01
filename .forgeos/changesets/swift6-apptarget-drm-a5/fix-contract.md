# Fix-contract — Swift 6 `targeted` concurrency, Phase A.5 DRM-decryption slice

Drives the Reader2/PDF DRM-decryption files to zero `targeted` concurrency
warnings. These 4 files were named in Phase A.3's checklist but never touched
(0 commits in `fb01695da..210f5713a`); measured at 11 warnings on develop tip
`210f5713a` via Unit Tests run `28520895484` (2026-07-01). Fix-by-ISOLATION,
never `nonisolated(unsafe)` / bare `@unchecked`. `SWIFT_VERSION` stays 5.0
(warnings, not errors). **CI Unit Tests is the only build + warning gate — no
local DRM build possible.**

## Scope (in)

### Group 1 — `LCPPDFOpenProgress.shared` root-cause fix (clears 6 warnings)
- **File:** `Palace/PDF/ReadiumPDF/LCPPDFOpenProgress.swift`
- **Change:** `static let shared` → `nonisolated static let shared`, and
  `private init()` → `nonisolated private init()`. The class stays `@MainActor`
  (drives the SwiftUI overlay via `@Published`); its recorder entry points
  (`recordDecrypt`, `recordExtractedBytes`) are ALREADY `nonisolated` and hop via
  `Task { @MainActor in }`. Only the `.shared` static reference was main-actor-
  isolated, which is why every nonisolated caller warned. Making the immutable
  reference + empty init nonisolated is legal because a `@MainActor` class is
  implicitly `Sendable`; instance state stays isolated.
- **Consequence:** clears TPPLCPClient.swift:169,183,235,243 and
  LCPPDFDiskExtract.swift:165,186 **with zero edits to those two files.**

### Group 3 — `AdobeDRMContentProtection` ReadiumShared crossing (clears 3 warnings)
- **File:** `Palace/Reader2/ReaderStackConfiguration/AdobeDRM/AdobeDRMContentProtection.swift`
- **Change:** line 12 `import ReadiumShared` → `@preconcurrency import ReadiumShared`
  (the compiler's own fix-it at :12). All three warnings (:12 import, :241
  `stream(consume:)` non-Sendable `(Data)->Void` param, :251 `properties()`
  non-Sendable `ReadResult<ResourceProperties>` return) are Sendable-crossings on
  types owned by the ReadiumShared module (`ResourceProperties`, `ReadResult`, the
  `Resource` protocol requirement signatures). `@preconcurrency` on the module
  import is the idiomatic suppression for a not-yet-Sendable-audited dependency
  (per the playbook §3.1 "module types not Sendable-audited → @preconcurrency
  import"). `DRMDataResource` remains an `actor`; no behavior change.
- **CI fallback (architect-required):** import-level `@preconcurrency` is the first
  attempt and should downgrade :241/:251 (they cross ReadiumShared-owned types), but
  it's unprovable without a build. If the CI log shows :241/:251 surviving, apply
  per-declaration handling and re-run CI — do NOT silently leave them. The
  `:(12|241|251) warning: == 0` grep is the hard acceptance gate.

### Group 2 — `TPPUserAccount: Sendable` (clears 2 warnings) — FOLDED IN (user decision 2026-07-01)
The user chose to fold the `TPPUserAccount`-Sendable credential-storage slice into
this PR rather than defer it, so this becomes a combined DRM + credential-storage
critical-path change. This half gets the same architect + qa SoD rigor the plan
prescribed for it as a standalone slice.

**PR-structure decision (2026-07-01):** architect recommended SPLIT (PR-1 = Groups 1+3,
PR-2 = Group 2); **user chose to KEEP COMBINED.** Per that decision, the commit/PR body
MUST flag the `TPPUserAccount` control-lock change as the risk-bearing half (the DRM
Groups 1+3 are zero-runtime-delta annotations; Group 2 touches the sign-in/sign-out
credential path). Full sign-in/sign-out/session-rotation regression required before merge.

- **Files:**
  - `Palace/Accounts/User/TPPUserAccount.swift` — add `@unchecked Sendable`
    conformance AFTER synchronizing the 3 unsynchronized mutable vars. Everything
    else (`let` immutables, `lazy var _xxx: TPPKeychainVariable`) is already
    keychain-queue-synchronized or immutable-after-init.
  - `Palace/Reader2/ReaderStackConfiguration/AdobeDRM/AdobeCertificate.swift` — no
    edit needed; once `TPPUserAccount` is `Sendable`, the `:393` captures in the
    Adobe `authorize` completion + main-thread hop stop warning.
  - `Palace/SignInLogic/TPPSignInBusinessLogic+SignOut.swift:51` — `signInGeneration
    += 1` (external read-modify-write) → call a new atomic `incrementSignInGeneration()`.
  - `PalaceTests/Mocks/TPPUserAccountMock.swift:271` — mock writes `signInGeneration = 0`.
    Architect-confirmed: mock does NOT override `signInGeneration`, so its `= 0` write
    routes through the parent's locked setter transparently — **no mock override needed
    for this var**, PROVIDED the parent setter stays settable (see amendment below).

- **The 3 vars + call-site map (verified 2026-07-01):**
  - `sessionIdentifier: String` (`:72`, public private(set)) — written `:184`, `:413`
    (`= UUID().uuidString`); read by `AuthFlowSecurityTests` (public). 
  - `signInGeneration: Int` (`:64`) — written `TPPSignInBusinessLogic+SignOut.swift:51`
    (`+= 1`); read `:90`, `:219`; mock `:271`.
  - `notifyAccountChange: Bool` (`:54`, private) — read `:130`, written `:134`, `:217`.

- **⚠ Deadlock constraint (ARCHITECT-CONFIRMED TRUE 2026-07-01):** these setters run
  from INSIDE `atomicUpdate`'s `accountInfoQueue.sync(flags:.barrier)` block. Traced
  production path: `TPPSignInBusinessLogic.updateUserAccount:849 → atomicUpdate:865 →
  barrier:590` then calls `setAuthToken:872`→`:413` (rotates `sessionIdentifier`),
  `setBarcode`→`credentials` setter→`:184` (rotates `sessionIdentifier`), AND
  `setAuthDefinitionWithoutUpdate:883`→`:217` (writes **`notifyAccountChange`**).
  `accountInfoQueue` is a **serial** queue (`:87`), so routing ANY of these accessors
  back through `accountInfoQueue.sync` re-enters the serial queue from inside its own
  barrier → **guaranteed deadlock. TWO of the three vars (`sessionIdentifier` AND
  `notifyAccountChange`) hit this via the barrier path; `signInGeneration` is external
  RMW but still cross-thread.** All three must use the dedicated lock, NEVER `accountInfoQueue`.
  → **Mechanism (architect-pinned): a dedicated `NSLock`** (house pattern per
  `LCPPDFOpenProgress`; NOT a raw stored `os_unfair_lock` — inout-copy footgun.
  `OSAllocatedUnfairLock` acceptable if deployment target allows). It is a strict
  **non-recursive leaf lock** — each accessor takes it, touches one stored value,
  returns; no ordering cycle with `accountInfoQueue`. Backing storage
  `_sessionIdentifier` / `_signInGeneration` / `_notifyAccountChange` guarded by it.
  - `signInGeneration` setter stays **settable at internal access — do NOT make it
    `private(set)`** (mock's cross-file subclass write `= 0` at `TPPUserAccountMock:271`
    would fail to compile). Add `incrementSignInGeneration()` (single locked RMW) for
    the SignOut:51 site only — a get-then-set pair would re-introduce a TOCTOU.
  - `sessionIdentifier` stays `public private(set)` computed (legal on a computed var;
    only the getter is `@objc`-exposed, matching today's selector shape).
  THEN `@unchecked Sendable` with the documented invariant "all mutable state is
  either keychain-queue-synchronized (`_xxx`) or control-lock-synchronized (these 3)."
  No bare `@unchecked`, no `nonisolated(unsafe)`.

- **Verification add-ons for Group 2:**
  - `AdobeCertificate.swift:393` warnings → 0 in the CI log.
  - `grep -c "@unchecked Sendable" Palace/Accounts/User/TPPUserAccount.swift` == 1,
    with an adjacent invariant comment.
  - No `accountInfoQueue.sync` added inside any setter reachable from `atomicUpdate`
    (deadlock guard) — architect + grep verified.
  - Existing `AuthFlowSecurityTests` (sessionIdentifier rotation), the SignOut
    `signInGeneration` race-guard tests, and `TPPUserAccountMock` consumers stay green.
  - Mutation on `TPPUserAccount.swift` diff-scoped ≥ 50% (critical path).

## Verification criteria (grep-able / CI)
- CI Unit Tests run on this branch builds **green** (`** BUILD SUCCEEDED **`) —
  no new `error:`; `SWIFT_VERSION` unchanged at 5.0.
- The 9 in-scope warnings drop to **0** in the build log:
  `gh run view <id> --log | grep -E 'TPPLCPClient.swift:(169|183|235|243)|LCPPDFDiskExtract.swift:(165|186)|AdobeDRMContentProtection.swift:(12|241|251)' | grep -c warning:` → **0**.
- The 2 deferred `AdobeCertificate.swift:393` warnings may remain (documented).
- No new `nonisolated(unsafe)` introduced:
  `git diff origin/develop -- Palace/PDF/ReadiumPDF/LCPPDFOpenProgress.swift | grep -c 'nonisolated(unsafe)'` → **0 added** (the file already has 2 pre-existing on `_openInProgress`; count must not increase).
- No bare `@unchecked Sendable` added anywhere in the diff.

## Tests required
- **DRM groups (1 & 3): no new tests** — pure isolation annotations, zero runtime
  delta. Existing `LCPPDFOpenProgressTests`, `LCPPDFDiskExtractTests`, `TPPLCPClient`
  LCP tests stay green (regression guard). qa_test review confirmed no test owed.
- **Group 2 atomicity test (ADDED per qa_test review, 2026-07-01):**
  `PalaceTests/Accounts/TPPUserAccountConcurrencyTests.swift` →
  `testIncrementSignInGeneration_underConcurrentCallers_countsExactlyOncePerCall`.
  The existing single-threaded `TPPSignInBusinessLogicSignOutTests` kills the
  `+= 1 → += 0`/no-op mutants but cannot distinguish the atomic locked RMW from a
  get-then-set TOCTOU. The new test drives `incrementSignInGeneration()` from
  `DispatchQueue.concurrentPerform(10_000)` and asserts `start + iterations`,
  killing the lost-update mutant (get-then-set / early-unlock). Hermetic (in-memory
  `_signInGeneration` only, no keychain). Registered in the PalaceTests target.
- `sessionIdentifier` rotation stays covered by `AuthFlowSecurityTests`;
  `signInGeneration` arithmetic + sign-out race-guard by `TPPSignInBusinessLogicSignOutTests`.
- Rationale for no new test (per CLAUDE.md "coverage-only tests are banned"):
  there is no new branch, state transition, or observable behavior to pin — a test
  asserting "`.shared` is accessible from a background queue" would be a tautology
  (it tests the compiler's isolation checker, not our logic). The mutation surface
  is unchanged. If the architect disagrees, the fallback is a concurrency test that
  calls `recordDecrypt` from a `DispatchQueue.global` and asserts the `@Published`
  counters converge on the main actor — but that pins the pre-existing hop, not
  this diff.

## Acceptance
- All Verification criteria pass (CI build green + 9 warnings → 0).
- Existing reader/PDF/LCP regression tests stay green.
- Group 2 deferral explicitly recorded (this contract + plan doc + commit body).
- `verify-pr.sh --quick` PASS (or documented CI-only if local DRM build blocks it).
