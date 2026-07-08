---
name: swarm test pollution shrink
author: maurice.carrier
swarm_id: swarm_5b500284
parent_swarm: swarm_47883816
created: 2026-06-04
type: refactor
risk: standard
---

# Test pollution shrink — drain A-deferred-files.txt (follow-up to swarm_47883816)

## Motivation

Swarm `swarm_47883816` migrated the top 14 high-concentration `AppContainer.production()` files but deferred 56 files (Option b phasing) so the lint could land cleanly. The deferred list at `.forgeos/swarms/swarm_47883816/A-deferred-files.txt` includes critical-path tests (BookReturnService*, AudiobookSessionManager*, TPPSignInOIDC, CredentialGuard, TokenRefreshAndRetryQueue) that the architect flagged as MUST-migrate before flipping `randomTestExecutionOrder = true`.

This swarm drains the deferred list to zero (or near-zero with documented residue) so the random-order flip becomes safe.

## Claims (what the diff WILL deliver)

1. **Migrate all 56 deferred files** from `AppContainer.production()` to `makeTestAppContainer()` (factory already exists from parent swarm at `PalaceTests/Support/TestAppContainerFactory.swift`).
2. **Shrink the deferred list** — `A-deferred-files.txt` reduces to ≤ 5 entries (with documented reason per residue).
3. **Update the lint exception list** in `PalaceTests/MetaTests/AppContainerIsolationLintTests.swift` so any remaining residue is whitelisted by explicit reason (not just deferral).
4. **Critical-path coverage**: per CLAUDE.md, files touching `Palace/Audiobooks/`, `Palace/SignInLogic/`, `Palace/MyBooks/Download*`, `Palace/Packages/PalaceAuth/`, `Palace/Network/TPP*` get extra mutation scrutiny since the migration could expose latent test-pollution bugs.

## Anti-claims (what the diff WILL NOT do)

- Does NOT change production behavior — pure test-target migration using the existing factory.
- Does NOT add new factory APIs — reuses `makeTestAppContainer()` from parent swarm.
- Does NOT modify `Palace/` production code.
- Does NOT flip random test order — that is a follow-up gated on this swarm landing AND 1 week CI-green.

## Files-in-scope

All 56 files listed in `.forgeos/swarms/swarm_47883816/A-deferred-files.txt`, plus:
- `PalaceTests/MetaTests/AppContainerIsolationLintTests.swift` (update exception list)
- `.forgeos/swarms/swarm_47883816/A-deferred-files.txt` (shrink to residue list)

## Verification

- `grep -rn "AppContainer\.production()" PalaceTests --include="*.swift"` post-migration must show only the explicit whitelist + ≤5 documented residue files.
- All migrated test files pass when run in isolation.
- `AppContainerIsolationLintTests` passes.
- Mutation kill rate on any production file inadvertently touched (expected: 0 production files).

## Out-of-scope

- D's 8-file UserDefaults deferred list (separate follow-up pass).
- E's 37-file teardown baseline shrink (separate follow-up).
- F's 5 fire-and-forget tickets (process work).
- Random test order flip.
