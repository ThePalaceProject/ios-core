---
name: swift6-apptarget-registry-targeted
created: 2026-07-01
author: Maurice Carrier
branch: swift6/apptarget-registry-sweep-a5
initiative: Swift 6 app-target Phase A.5 — registry/cover residue slice (critical-path: book-state source of truth)
priority: critical-path
---

# Intent: Swift 6 `targeted` strict-concurrency — registry residue slice (Chunk 1)

## Context

Phase A.5 remainder (`docs/architecture/swift6-a5-remainder-plan.md`). This is
**Chunk 1 only** — the `TPPBookRegistry` book-state residue (11 of the 31 sites),
which is independent of PR #1155. `SWIFT_STRICT_CONCURRENCY = targeted` (warnings,
`SWIFT_VERSION` stays 5.0). Fix-by-isolation only — never `nonisolated(unsafe)`
(except REMOVING an unnecessary one), no bare `@unchecked Sendable`. No local DRM
build — CI "Unit Tests" is the warning gate.

The `TPPAgeCheck` ×4 + `TriageBotFactory` cascade and all of Chunk 2 are
**deferred** (they depend on #1155's `TPPUserAccount`/`AccountDetails` Sendable
work merging first).

## Claims

- Fixes the 9 `capture of 'setState'/'completion'/'errorDocument' in @Sendable
  closure` warnings in `BookRegistrySync.sync(...)` by introducing two documented
  `@unchecked Sendable` carrier structs (`SyncCallbacks`, `SendableErrorDocument`)
  and routing the `Task { … }` / `MainActor.run { … }` captures through them.
  Mirrors the existing `ImageCompletionBox` pattern in `ImageLoaderImpl`. NO
  signature change to `sync`/`load` → no caller ripple.
- Fixes `TPPBookRegistry.waitForLoadThenRunSync` `'token' mutated after capture by
  sendable closure` by holding the observer token in a `@unchecked Sendable`
  `ObserverTokenBox` (write-once-then-read) instead of a captured `var`.
- Removes the now-unnecessary `nonisolated(unsafe)` on
  `TPPBookCoverRegistry.imageCache` (its type `ImageCacheType` is now `Sendable`),
  replacing it with `nonisolated let`. Leaves the `sourceDataCache`
  `nonisolated(unsafe)` intact (`NSCache` is genuinely non-Sendable) and de-couples
  its stale cross-reference comment.

## Anti-claims

- Does NOT mark `setState`/`completion` params `@Sendable` — that would relocate
  the warning to the three caller closures in `TPPBookRegistry` (which capture the
  non-Sendable `TPPBookRegistry`). The carrier-box approach avoids the ripple.
- Does NOT change any observable registry behavior — the setState/completion/
  errorDocument values forwarded are byte-identical; only the capture mechanism
  changed.
- Does NOT touch `TPPAgeCheck`, `TriageBotFactory`, `AccountsManager`,
  `AccountDetails`, `TPPUserAccount`, or any Chunk 2 file (deferred; blocked on
  #1155).
- Does NOT change the `BookRegistrySync` `@unchecked Sendable` invariant, the
  `store`/`diskWriteQueue` serialization, or the account-capture contract.
- Does NOT use `nonisolated(unsafe)` (except removing one) or
  `MainActor.assumeIsolated`.

## Files in scope

- Palace/Book/Models/BookRegistrySync.swift
- Palace/Book/Models/TPPBookRegistry.swift
- Palace/Book/Models/TPPBookCoverRegistry.swift

## Testing note

Behavior-preserving isolation refactor. The setState/completion carrier path is
covered by the existing `BookRegistrySyncTests.test_sync_whenNotSyncing_withCredentialsAndNoLoansUrl_resolvesToLoaded`
(drives sync → `callbacks.setState(.loaded)` + `callbacks.completion?(nil,false)`,
asserts state/errorDoc/newBooks). The feed-fetch-failure `errorDocument` forward
is a pre-existing seam-less gap (`sync` takes the concrete `OPDSFeedService` actor,
not the `OPDSFeedFetching` protocol) and the change there is a pure `.value`
passthrough — no new test fabricated (would be flaky real-network or a tautology).
