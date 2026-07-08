---
name: swarm-0286b100-test-isolation-foundational-awaitReady-drain-saveSync-fuzz
created: 2026-06-10
author: claude-opus-4-8
tracking: unblocks PR #1053 (per-test-timeout) by fixing the foundational test-suite hang/flake tail
related_prs: []
---

# Intent: foundational test-suite hang/flake fixes (swarm_0286b100)

## Problem
PR #1053's per-test timeout exposed a foundational hang/flake tail. The swarm
architect collapsed 5 failing tests into root causes; the B-implementer's
investigation reduced them further:

- **A (keystone):** `Account.awaitReady()` parks on `for await` over the
  process-wide `AccountStateStore.shared`. The teardown drain
  `_resetAllForTesting()` sent the NON-TERMINAL `.notLoaded`, so parked
  awaiters hit `case .notLoaded: continue` and stayed suspended forever —
  leaking Tasks that accumulate and starve the cooperative thread pool. This is
  the deeper leak under the AccountsManager-crawl leak fixed by #1057. Victims:
  CatalogPreloader >60s hang, OPDS blocksUntilLoaded flake, DownloadThrottling
  pauseAll flake, AND the ParserFuzz annotations "hang" (a victim, not a parser
  bug — see B).
- **C:** `BookRegistrySync.saveSync(for:)` wrote directly on the calling thread,
  bypassing `diskWriteQueue`, racing the async `save(for:)` atomic write to the
  same URL — the TPPBookRegistryPersistence concurrent-save race.
- **B:** No annotations parser bug. The annotations fuzz test runs 0.5s in
  isolation; its CI "hang" was cause-A pool starvation. (FuzzRunner had no
  per-input timeout.)

## Claims
- `AccountStateStore._resetAllForTesting()` now sends the TERMINAL
  `.detailsEvicted(.libraryDeselected)` to each subject (then the `.notLoaded`
  baseline reset), unparking leaked `awaitReady()` awaiters via the proven
  value-yield path. No clearing of `subjects` (a parked awaiter is subscribed to
  the existing subject). DEBUG-only; production `awaitReady` semantics unchanged.
- `BookRegistrySync.saveSync(for:)` runs on `diskWriteQueue.sync { }`, sharing
  the async save's FIFO serialization domain (snapshot taken inside the queue).
  Preserves the PP-4129 per-account snapshot capture + `.atomic` write.
- `FuzzRunner.runOne` adds a non-masking per-input wall-clock REGRESSION
  DETECTOR (XCTFail with repro bytes if any single input exceeds 2.0s); 500
  iterations preserved; no XCTSkip / no relaxed corpus.

## Anti-claims
- No relaxed/raised test timeouts, no XCTSkip, no test sleeps as fixes, no
  reduced fuzz iterations.
- No production parser bound (no parser bug was reproducible).
- No change to production `awaitReady()` on the live path; the drain is
  `#if DEBUG` and only invoked at test teardown.
- No change to `save(for:)`'s contract.

## Files in scope
- `Palace/Accounts/Library/AccountStateStore.swift`
- `Palace/Book/Models/BookRegistrySync.swift`
- `PalaceTests/Accounts/AccountStateMachineTests.swift`
- `PalaceTests/Fuzz/FuzzRunner.swift`
