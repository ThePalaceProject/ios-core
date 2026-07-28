# Wave 3 coupling map — Accounts ↔ Downloads (verified)

**Status:** write-ahead characterization scouting for god-class-decomposition
**Wave 3** (`docs/architecture/god-class-decomposition-plan.md` §3a-2/§3a-3, §4
Wave 3, §5). **Author:** test-coverage fleet, 2026-07-27. **Scope:** tests +
this doc only — no production change.

This maps the ACTUAL bidirectional coupling between `AccountsManager`
(→ PalaceAccounts, Wave 3a) and the MyBooks download subsystem
(→ PalaceDownloads, Wave 3b), grepped and read against source this session, so
the extraction is provably behavior-neutral. Line numbers are from
`origin/develop` @ `4ce91283f`.

## Headline finding: the coupling is ASYMMETRIC and mostly already inverted

The Downloads side already reaches Accounts almost entirely through
**closure seams** (`userAccountProvider: () -> TPPUserAccount`), the exact
inversion Wave 3 wants. The load-bearing, still-concrete coupling reduces to a
handful of `currentAccountId` / `currentUserAccount` reads plus **one** hard
static back-call from Accounts into Downloads. Wave 3's real work is (a) a single
`AccountScopeProviding` protocol for the `currentAccountId` reads, and (b) a
new reset-notification seam for the one static back-call — NOT a large carving.

The plan's §3a-3 "3a/3b are ∥ only because Wave 2 already cut their mutual edge"
holds with **one caveat** (see Seam S1): the account-switch → borrow-reauth-reset
static call is a live Accounts→Downloads edge that Wave 2 did **not** cut. It
must invert before 3a and 3b can land independently, or 3b serializes behind 3a.

---

## A. Accounts → Downloads (the back-edges)

| # | Site (file:line) | What it does | Status |
|---|---|---|---|
| **A1** | `Accounts/Library/AccountsManager.swift:994` → `MyBooks/MyBooksDownloadCenter+Async.swift:27` → `MyBooks/BorrowOperation.swift:141` | `cleanupActiveContentBeforeAccountSwitch` calls the STATIC `MyBooksDownloadCenter.clearAllBorrowReauthState()` on every real library switch, wiping the process-wide per-book borrow-reauth circuit breaker. | **PINNED** (new `AccountSwitchBorrowReauthCouplingContractTests`). **Un-inverted static — needs a seam (S1).** |
| A2 | `Accounts/Library/AccountsManager.swift:993` (via lazy `networkExecutor`, decl :274 = `AppContainer.production().networkExecutor`) | Account switch cancels non-essential in-flight tasks (incl. downloads). | Covered at the executor level by `AccountSwitchLifecycleTests` + `AccountSwitchCleanupTests`. Reaches `AppContainer.production()` — see S3. |
| A3 | `Accounts/Library/AccountsManager.swift:1131` (doc) | Comment: MyBooksDownloadCenter observes `hasCredentials` transitions on the account. | Advisory only; no direct call. |

The account-switch cleanup also fires (same setter, `currentAccount.didSet` @ :910):
`ImageCache.shared.evictDecodedImages()` (:913), `TPPBookCoverRegistry.shared.resetHostFailures()`
(:917), `AccountStateStore.shared.setState(.detailsEvicted…)` (:953), and an async
`AppContainer.production().navigationCoordinatorHub` pop-to-root (:997). These are
**not** Downloads coupling but are the static reaches that block a clean
`CurrentAccountStore` extraction test (see S3). The setter's **publication order**
is already pinned by `PalaceTests/Decomp/AccountsManagerCurrentAccountSwitchContractTests`.

## B. Downloads → Accounts (the forward reads)

| # | Site (file:line) | What it does | Status |
|---|---|---|---|
| B1 | `MyBooks/BookFileManager.swift:67` (`fileUrl(for:)` → `accountsManager.currentAccountId`); stored dep :28/:49 | Per-account download-file directory: the on-disk path follows the current library; sideloaded ids pin to the fixed sideload account (:92–96). | **PINNED** (new `BookFileManagerAccountScopingTests`). Needs S2. |
| B2 | `MyBooks/MyBooksDownloadCenter.swift:784` (`captureCurrentAccountId` → `accountsManager.currentAccountId`) | Capture-at-start of `currentAccountId`, threaded through the whole download → bearer-auth path (fixes spurious login modal on mid-download library swap). | **Already PINNED** (`MyBooksDownloadCenterAccountIdThreadingTests`, 7 cases incl. concurrency). Needs S2. |
| B3 | `MyBooks/MyBooksDownloadCenter.swift:105–107` (`userAccount` → `accountsManager.currentUserAccount`); :114–119 (`userAccount(forCapturedId:)` → `accountsManager.userAccount(for:)`) | Legacy resolver-fallback + captured-id resolution for download credentials. | Thin delegators; the coordinator-level capture (B2) is the tested surface. Needs S2. |
| B4 | `MyBooks/MyBooksDownloadCenter.swift:1778` (`reset(account:)`: `if accountsManager.currentAccountId == account`) | Content-reset only clears the pending-removal marker when resetting the CURRENT account. | Not separately pinned (needs a full MBDC). Needs S2. |
| B5 | `MyBooks/MyBooksDownloadCenter.swift:1992` (`account: accountsManager.currentAccountId ?? ""`) | Current-account id stamped into a registry/announce call. | Not separately pinned. Needs S2. |
| B6 | `MyBooks/MyBooksDownloadCenter.swift:479, 610` (`AppContainer.production().accountsManager.currentAccount?.authSurfaceHosts`) | Foreign-host guard for the auth-error classifier — locator reach, NOT the injected `accountsManager`. | Needs S2 **and** S3 (kills a `AppContainer.production()` locator). |
| B7 | Closure-inverted, **already seam-clean**: `BorrowOperation.swift:229`, `BookReturnService.swift:96`, `BorrowErrorPresenter.swift:98`, `CredentialPromptCoordinator.swift:60`, `RightsManagementDispatcher.swift:78`, `BookSignInRedirectHandler.swift:63`, `DownloadAuthRetryHandler.swift:90` (all `userAccountProvider: () -> TPPUserAccount`) | Per-flow current-account resolution. | No inversion needed — these already take a closure. They move to PalaceDownloads intact. |

---

## Production SEAMS the Wave 3 extraction will need

These are the DI seams that do **not** exist yet. Each is a place a test could
not exercise the coupling without a production change — recorded here rather than
added (tests-only rule). This is the analogue of the four missing seams the
Wave 2b contract work surfaced.

- **S1 — `BorrowReauthResetting` (NEW; not in the plan).** `AccountsManager`'s
  account-switch cleanup calls `MyBooksDownloadCenter.clearAllBorrowReauthState()`
  as a hard STATIC (A1). Once AccountsManager is in PalaceAccounts and
  BorrowOperation is in PalaceDownloads, PalaceAccounts cannot name the download
  type. Introduce a narrow protocol (e.g. `protocol BorrowReauthResetting { func
  clearAllBorrowReauthState() }`) declared in **PalaceAccounts** (or a shared
  lower layer) and injected into the account-switch cleanup; the download
  subsystem registers the impl at composition. **This edge was NOT cut by Wave 2**
  — until S1 exists, Wave 3b's borrow-reauth-reset behavior is coupled to 3a, so
  either land S1 first or serialize 3b behind 3a (per §3a-3's own escape clause).
  Behavior to preserve is locked by `AccountSwitchBorrowReauthCouplingContractTests`.

- **S2 — `AccountScopeProviding` (named in plan §3b-1/§2.3, scope wider than
  stated).** The plan introduces `AccountScopeProviding` (`currentAccountID`,
  `accountDidChange`) for `PalaceBookRegistry`. Wave 3 needs the SAME protocol to
  cover every Downloads→Accounts read (B1–B6), replacing the concrete
  `accountsManager: AccountsManager` dependency in `BookFileManager` and
  `MyBooksDownloadCenter` with `currentAccountId` (and `userAccount(for:)` /
  `currentUserAccount` for the credential reads). Confirm the protocol surface is
  widened from the registry-only `{currentAccountID, accountDidChange}` to also
  vend `userAccount(for:) -> TPPUserAccount` and `currentUserAccount`, or split
  into `AccountScopeProviding` + `AccountCredentialProviding`.

- **S3 — de-locator the account-switch cleanup + MBDC host guard.** The
  `currentAccount` setter's cleanup reaches `ImageCache.shared`,
  `TPPBookCoverRegistry.shared`, `AccountStateStore.shared`, and
  `AppContainer.production().{networkExecutor,navigationCoordinatorHub}` directly
  (A2 + §A note), and MBDC reads `AppContainer.production().accountsManager` for
  the foreign-host guard (B6). These block a deterministic spy-based test of the
  cleanup ORDERING (why `AccountsManagerCurrentAccountSwitchContractTests` observes
  via `NotificationCenter` rather than injected spies, and why this suite pins the
  Downloads coupling through `BorrowOperation` directly rather than the setter).
  The `CurrentAccountStore` extraction should take these as injected collaborators
  (`ImageCaching`, cover-registry, `NetworkTaskCancelling`, nav hub) so the
  post-extraction facade's cleanup order becomes spy-testable.

## What this write-ahead pack locks (so the extraction is provably neutral)

| Suite (new) | Direction | Pins |
|---|---|---|
| `PalaceTests/Contract/AccountSwitchBorrowReauthCouplingContractTests` | Accounts→Downloads (A1) | Ordered seam sequence across repeat borrows: 1st auth-error → reauth; 2nd (same book) → breaker suppresses to generic error; `clearAllBorrowReauthState()` (what a switch calls) re-enables; the wipe is GLOBAL across books; the breaker is keyed per-book. 4 byte-equal JSON snapshots. |
| `PalaceTests/MyBooks/BookFileManagerAccountScopingTests` | Downloads→Accounts (B1) | Download-file path follows `currentAccountId` (A→B re-points the same book); sideloaded content pins to the fixed sideload account across a switch; prefix-without-membership falls back to per-account scoping. 5 unit assertions. |

Already-covered coupling (verified this session; NOT duplicated): capture-once /
bearer-auth threading (B2, `MyBooksDownloadCenterAccountIdThreadingTests`),
per-library credential + registry isolation across a switch
(`AccountSwitchLifecycleTests`), and the `currentAccount` setter publication
order (`Decomp/AccountsManagerCurrentAccountSwitchContractTests`).

---

## Post-2b refresh (2026-07-27)

Re-verified against `origin/develop` @ `c231b5a43` (Wave 2b, PR #1341, landed
after this map was first written). Rebased `feat/wave3-writeahead-tests` onto
this tip — **conflict-free**, no test edits needed, both new suites still pass
(byte-equal contract snapshots, unchanged). Facts below are grepped/read from
current source this session, not carried over from the pre-2b draft.

- **Line drift.** The A1 static call site is now
  `AccountsManager.swift:995` (was `:994` pre-2b — a one-line shift from an
  intervening edit, not a behavior change):
  `MyBooksDownloadCenter.clearAllBorrowReauthState()`, still fired
  unconditionally from `cleanupActiveContentBeforeAccountSwitch`. The B1 read
  moved to `BookFileManager.swift:68` (was `:67`):
  `accountsManager.currentAccountId` inside `fileUrl(for:)`. The breaker
  itself, `BorrowOperation.clearAllBorrowReauthState()`, is now at `:142` (was
  `:141`). All three are pure line-number churn — the pinned call-order and
  seam sequence in both new suites are unaffected.

- **Cycle-1 Accounts→registry down-edge is now COMMENT-ONLY.** Pre-2b,
  `AccountsManager` had a live code edge into the book registry; Wave 2b's
  `PalaceBookRegistry` extraction + `AccountScopeProviding` inversion cut it.
  `AccountsManager.swift` today has exactly one `import PalaceBookRegistry`
  (for the adapter conformance, in the separate
  `AccountsManagerAccountScopeAdapter.swift`) and two remaining mentions of
  `TPPBookRegistry`/`BookRegistrySync`, both inside doc comments (`:369-370`,
  `:1049`) — no live call. The registry now depends on Accounts only through
  the protocol; Accounts does not reach back into the registry in code.

- **`AccountScopeProviding` shipped 4-member**, confirmed at
  `Palace/Packages/PalaceBookRegistry/Sources/PalaceBookRegistry/AccountScopeProviding.swift`:
  `currentAccountID: String?`, `accountDidChangePublisher:
  AnyPublisher<Void, Never>`, `hasCredentials(forAccount:) -> Bool`,
  `loansURL(forAccount:) async throws -> URL?`. This **supersedes §S2 above**:
  the decision (made during 2b) is AGAINST widening this shared protocol for
  Downloads' B1–B6 reads. `AccountScopeProviding` stays value-only
  (registry-only consumer); Wave 3b's S2 introduces its own
  Downloads-owned protocol(s) (`DownloadAccountScopeProviding` /
  `DownloadCredentialsProviding`) rather than extending this one — a
  capability-boundary split, not a shared surface.

- **Sequencing refinement: S1/A1 structurally blocks 3a only, not 3b.**
  Restated from the original §S1: a packaged `AccountsManager` (3a) cannot
  name the app-target `MyBooksDownloadCenter` type, so A1 must invert before
  3a can extract. 3b (packaging the Downloads side) does **not** have the same
  hard blocker — the MBDC shell can stay app-target with a static forwarder
  into package-side `BorrowOperation`, so 3b alone would still compile without
  S1. S1 still lands first regardless: it is small, removes the one edge that
  would otherwise force a serialization decision mid-wave, and makes the
  account-switch cleanup ordering spy-testable (feeds S3). This refines, not
  reverses, the original "serialize 3b behind 3a" framing — the constraint is
  narrower than first stated.

No other divergences found. The pinned suites
(`AccountSwitchBorrowReauthCouplingContractTests`,
`BookFileManagerAccountScopingTests`) remain valid unmodified against
post-2b source.

<!-- audit-verified -->
