---
name: wave2b-contract-tests
created: 2026-07-27
author: claude-opus-4-8
type: test
tracking: God-class decomposition Wave 2b — pin the TPPBookRegistry sync/persistence cluster's CURRENT behavior so the eventual SPM extraction (BookRegistrySync + AccountScopeProviding inversion) is provably behavior-neutral. Companion to PR-W2-pre (#1337).
related_prs: []
---

# Intent: Wave 2b parallel-safe characterization/contract tests

## Claims
- Adds THREE new test-only files under `PalaceTests/Contract/` that pin the
  ordered dependency-call behavior of the `TPPBookRegistry` sync/persistence
  cluster (`BookRegistrySync.sync`/`save`, the facade's account-capture-at-
  dispatch contract, and the INV-1 post-corrupt rebuild-window save refusal):
  - `TPPBookRegistrySyncContractTests` — drives the REAL `BookRegistrySync.sync`
    with an injected recording `OPDSFeedFetching` fetcher + a spy
    `LocalBookContentService` (delete seam) + a seeded credentialed fixture
    account, and snapshots the ordered effect sequence for: happy-path
    reconcile (merge + fresh + deletion + authoritative save + .synced),
    no-credentials early exit, awaitReady failure revert, and the empty-feed
    bulk-deletion guard.
  - `TPPBookRegistryAccountCaptureContractTests` — the PP-4129 pin: a fixture
    AccountsManager whose `currentAccount` FLIPS between mutation dispatch and
    barrier execution; asserts each async-gap mutation family (addBook,
    setState, a readium-bookmark wrapper) persists to the ORIGINALLY-captured
    account's on-disk registry file, plus saveSync (synchronous capture).
  - `TPPBookRegistryRebuildRefusalContractTests` — INV-1: a non-authoritative
    empty save during the rebuild window is REFUSED (backup + flag intact); an
    authoritative empty save is ALLOWED and clears the flag. Pins the ordered
    decision sequence, not just the terminal outcome.
- Registers all three in the pbxproj `PalaceTests` target via
  `scripts/pbxproj_add_swift.rb`.
- Records a mutation baseline (no gate) in
  `docs/architecture/wave2b-mutation-baseline.md`.

## Anti-claims
- Modifies NO production code under `Palace/**`. Every seam used already exists
  (`BookRegistrySync` DI init, `OPDSFeedFetching` provider, `MyBooksDownloadCenter`
  `localContentService` injection, `AccountsManager._seedAccountForTesting`,
  `Account._setState`, `TPPBookRegistry.registryUrl(for:)`).
- Does NOT duplicate the #1337 facade/mutation contract suites
  (`TPPBookRegistryFacadeContractTests`, `TPPBookRegistryMutationContractTests`).
- Does NOT add `AccountScopeAdapterTests` (the adapter type does not exist yet).
- Does NOT change the record-then-assert ContractSnapshot framework.

## Files in scope
- PalaceTests/Contract/TPPBookRegistrySyncContractTests.swift (new)
- PalaceTests/Contract/TPPBookRegistryAccountCaptureContractTests.swift (new)
- PalaceTests/Contract/TPPBookRegistryRebuildRefusalContractTests.swift (new)
- PalaceTests/Contract/__Snapshots__/** (recorded baselines)
- docs/architecture/wave2b-mutation-baseline.md (new)
- Palace.xcodeproj/project.pbxproj (test-target registration only)

## Verification
- Build + run each new suite twice on a claimed sim with a fresh
  `-derivedDataPath` (first run records the snapshot baselines, second asserts
  green). Report the exact `-only-testing` commands + `** TEST SUCCEEDED **`.

**Not done / deferred:** a spyable `save(for:serverAuthoritative:)` seam and a
`DownloadCenter` protocol would let the extraction pin the authoritative-save
call directly (currently pinned by its on-disk effect). The `AccountScopeProviding`
inversion + its adapter test land in the extraction PR, not here.
