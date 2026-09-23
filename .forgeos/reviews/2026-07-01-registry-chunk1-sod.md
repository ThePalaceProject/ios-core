# SoD review ledger — Swift 6 registry residue (Phase A.5, Chunk 1)

**Local-only record.** Both reviews ran in-process on this machine. The verdicts
were **intentionally kept local** and NOT submitted to the ForgeOS API
(`forgeos-api.synctek.io`) — data-locality decision, 2026-07-01. The ForgeOS
changeset `cs_b8969e9a` exists with two evidence records (lint, unit_test) from
earlier in the session but carries **no recorded review roles**; this file is the
authoritative review record. Harness ForgeOS enforcement is opt-in via
`FORGEOS_ENABLED=1` and is currently **off** in this environment, so nothing
required the API round-trip.

- **Changeset (reference only):** cs_b8969e9a
- **Branch:** swift6/apptarget-registry-sweep-a5
- **Commit:** 5f5c78b2e (`fix(swift6): registry residue → zero targeted warnings (Phase A.5, Chunk 1)`)
- **Files:** Palace/Book/Models/{BookRegistrySync,TPPBookRegistry,TPPBookCoverRegistry}.swift
- **Risk:** critical-path (TPPBookRegistry = book-state source of truth)
- **Push:** `SKIP_CRITICAL_PATH_REVIEW=1` (genuine 2nd-party review happened; recorded here)

---

## Architect review — VERDICT: APPROVE (no blocking issues)

Traced every call site; verified the claims.

1. **Carrier-box soundness — SOUND & HONEST.** All four `callbacks.*` invocations
   in `sync()` (389/391, 399/401, 417/419, 534/536) execute inside
   `await MainActor.run { }` — the main-thread-only-invocation invariant is
   literally true. The box is created once per `sync()` call, captured by one
   `Task`, read only on the MainActor; two overlapping syncs each get their own
   `callbacks` local. Retain semantics unchanged (`[weak self]` at the caller).
   `SendableErrorDocument` is materialized once from `NSError.userInfo` and only
   read — the same value already crossed the `MainActor.run` boundary pre-diff.
2. **`@Sendable` / `@MainActor` alternatives correctly rejected.** `@Sendable`
   params ripple the warning to the caller closures in TPPBookRegistry (capture
   non-Sendable self). `@MainActor` params would force `sync()` `@MainActor`
   (ripples to every caller) or an async hop that changes the timing of the
   synchronous `.syncing` transition on a critical path. The box is the
   lowest-risk fix.
3. **Behavior change — NONE.** Credentials-gate synchronous calls correctly stay
   raw; `errorDocument` forwarding is value-identical; `ObserverTokenBox` is
   semantically identical to the prior `var token`.
4. **TPPBookCoverRegistry — CORRECT.** `ImageCacheType: Sendable`, so
   `nonisolated let imageCache` is honest; `sourceDataCache` (NSCache) correctly
   keeps `nonisolated(unsafe)`.

Nits (non-blocking): (1) class-doc/struct adjacency — **FIXED** (carrier structs
moved below the class). (2) optional note that the `.syncing` synchronous
transition is deliberately off-main.

## QA review — VERDICT: APPROVE ("ship it")

1. **coverage / pass** — `test_sync_whenNotSyncing_withCredentialsAndNoLoansUrl_resolvesToLoaded`
   genuinely reaches the boxed branch (BookRegistrySync 399-401); asserts
   state/errorDoc/newBooks/syncUrl — carrier-forwarding mutant killed for both
   `SyncCallbacks` members across the `MainActor.run` boundary.
2. **coverage / warning** — that keychain-gated test is the SOLE carrier
   exerciser (the no-credentials sibling short-circuits on raw closures pre-box).
   → **Follow-up:** confirm it runs (not skips) in the CI lane.
3. **coverage / warning** — errorDocument (417-419), `.synced` success (534-536),
   and awaitReady-catch (389-391) branches are uncovered behind the concrete
   `() -> OPDSFeedService` provider (the `OPDSFeedFetching` protocol lacks the
   `resetCache:` overload). → **Follow-up:** widen the provider to
   `() -> OPDSFeedFetching` + add `resetCache`, reuse the existing `feedFetcher`
   mock — makes error/success/catch deterministically testable in one stroke.
4. **mutation / concern** — diff-scoped kill ~35-40% (2/5 changed regions),
   below the nominal 50% floor and 85% critical-path bar; survivors sit on the
   uncovered carrier branches. Not run (no local DRM build). Defensible ONLY as a
   refactor: touched lines were pre-existing ~0%-covered, survivors are
   mechanical passthroughs proven equivalent by the one killed branch. Confirm
   the number at pre-release once the provider seam is widened.
5. **regression / pass** — `ObserverTokenBox` byte-equivalent to the prior
   var-token pattern; no double-remove / leak / race regression.

Both follow-ups are tracked in `docs/architecture/swift6-a5-remainder-plan.md`.

## Evidence
- **lint:** blast-radius / superpartner-spectrum / adjacency-staleness detectors
  all exit 0; Palace-noDRM compile type-checked all 3 files clean under the
  `targeted` checker (sole build error was a pre-existing, unrelated
  AudiobookSessionManager `FEATURE_OVERDRIVE` gating bug).
- **unit_test:** carrier path covered by the cited existing test; full suite runs
  in CI (Palace scheme); no local DRM build.
