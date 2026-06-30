# App-target Swift 6 modernization — scoped plan

<!-- audit-verified -->
Status: **planned** (per-package modernization complete; this is the final, largest module).
Author: claude · Drafted 2026-06-30.

PR-state at drafting (verified via `gh pr view` / `git log origin/develop`):
PalaceCatalog **merged** (commit `e3496d867`); PalaceAuth PR still **OPEN** (CI
running) — so the Auth-side Sendable ripple below is **pending that merge**, not
yet present on develop.

## Context

The 7 first-party SPM packages are now Swift 6 (`Logging → Keychain →
ReadingPosition → TriageBot → Network → Catalog → Auth`; Auth pending its merge).
The remaining surface is the **`Palace` app target itself** — currently
`SWIFT_VERSION = 5.0` with **no `SWIFT_STRICT_CONCURRENCY` setting at all** (not
even `targeted`). This is the "center of mass" + main-target work the #1129 sizing
always called out as the final heavy lift. It is a multi-wave initiative, not a
single PR.

## Why incremental (not a big-bang flip)

Flipping `SWIFT_VERSION` to 6.0 directly turns every concurrency warning into a
hard error at once — for the whole app that is unreviewable and unbisectable.
The supported path is to ratchet the diagnostic level, fixing each wave to zero
before tightening:

1. **Wave 0 — measure.** Set `SWIFT_STRICT_CONCURRENCY = targeted` in a branch,
   build the app for the iOS sim (needs frameworks — run in the main checkout or
   CI, NOT a fresh worktree), and capture the warning count + categories. This is
   the first concrete action and the input to sizing the rest.
2. **Wave 1 — `targeted` → 0.** Fix the `targeted`-level warnings (Sendable on
   types crossing explicit concurrency boundaries, `@Sendable` closures). Land in
   reviewable slices by subsystem (Network, MyBooks/Download, Audiobooks,
   SignInLogic, Reader2, …). Keep `SWIFT_VERSION = 5.0`.
3. **Wave 2 — `complete` → 0.** Bump to `SWIFT_STRICT_CONCURRENCY = complete`,
   re-measure, fix the (larger) wave the same way.
4. **Wave 3 — language mode.** Only once `complete` is clean, set
   `SWIFT_VERSION = 6.0`. Should be near-zero new errors if waves 1–2 were honest.

Each wave: fix by **isolation, never `nonisolated(unsafe)`** (the #1129 playbook);
full-app CI `build-and-test` is the gate; critical-path slices (auth, borrow,
return, download, DRM, audiobooks, migrations) get architect + qa SoD.

## Immediate first slice — the two Sendable ripple follow-ups

These are the warnings the Catalog and Auth package work introduce into the
Swift-5 app (warnings, not errors). They are the natural Wave-1 starting point
and are **critical-path**, so they get `/rigorous-fix`:

1. **`TPPNetworkExecutor` (auth-error decision point)** — live now (Catalog
   merged): `URLSessionNetworkClient: NetworkClient` is now `Sendable`, so the
   executor it holds should be Sendable. But `TPPNetworkExecutor` has **mutable**
   state: `private var _accountsManager` (lazy check-then-set) and
   `var tokenRefreshWatchdogSeconds`. Do NOT slap on a bare `@unchecked Sendable`.
   Required: confirm/serialize the `_accountsManager` lazy init (it already guards
   against circular-init deadlock — verify the read/write is safe under
   concurrency, lock if not); decide whether the watchdog var must be settable
   post-init (likely test-only — make it injectable-at-init or lock it); THEN
   `@unchecked Sendable` with a documented invariant. Architect + qa SoD.
2. **`TPPUserAccount` (credential storage)** — pending the Auth merge: once
   `TPPUserAccountReading/Writing` land as `Sendable`, the conformer must be
   Sendable-honest. Architect N1: route `signInGeneration`, `notifyAccountChange`,
   `sessionIdentifier` (mutated on sign-in/account-change,
   `TPPUserAccount.swift:134/184/217/413`) through the existing `accountInfoQueue`
   (the rest of the mutable state already is), THEN `@unchecked Sendable` — do
   **not** blanket-`@unchecked` over the un-synchronized vars. Also a pre-existing
   benign TOCTOU in `markCredentialsStale` (architect N2) — fold the fix in if
   cheap.

Both verified by full-app CI; both critical-path → SoD. Do them together as one
`/rigorous-fix` PR once the Auth merge lands (so both Sendable changes are on
develop).

## Other tracked follow-ups (fold into the relevant wave)

- `execute(completion:)` test for `TokenRequest` (qa nit, needs global URLProtocol
  stubbing) — Wave 1, SignInLogic slice.
- Refresh stale `cacheQueue` comments in `CatalogRepositoryTests` (qa optional).

## Out of scope here

- Chaos-replay **activation** (admin: `ENABLE_CHAOS_QA_RUNNER` var + self-hosted
  runner + populate `.simdrive/replays/chaos/`) — tracked separately.
- ~68 pre-existing non-concurrency style warnings in PalaceCatalog (redundant
  `public`, always-true casts).
