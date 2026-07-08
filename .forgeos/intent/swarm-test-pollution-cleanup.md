---
name: swarm test pollution cleanup
author: maurice.carrier
swarm_id: swarm_cd181acd
parent_swarms: [swarm_47883816, swarm_5b500284]
created: 2026-06-04
type: refactor
risk: standard
---

# Test pollution D+E cleanup — drain D-deferred + E-teardown-baseline

## Motivation

Follow-up to swarm_47883816 (parent) and swarm_5b500284 (A-shrink). Drains:
1. D's 8-file UserDefaults deferred handoff (5 production DI seams + 8 test files)
2. E's 37-file teardown baseline

## Claims

1. **5 production DI seams** added via constructor injection (default arg `.standard`, no fallback):
   - `Palace/Accounts/Library/Account.swift` (AccountDetails.init)
   - `Palace/Accounts/Library/AccountsManager.swift`
   - `Palace/Reader2/Bookmarks/TPPBookmarkDeletionLog.swift`
   - `Palace/Packages/PalaceCatalog/Sources/PalaceCatalog/CatalogRepository.swift` (SPM — needs PUBLIC_INTENT)
   - `Palace/SignInLogic/TPPSignInBusinessLogic+ForceReset.swift` (static var swap-and-restore — extensions can't have stored properties)

2. **8 deferred test files** migrated to `testUserDefaults()` injection.

3. **37 → 1 teardown baseline** entries cleared (33 received tearDown overrides; 3 already-compliant stale; 1 false-positive; 1 retained as self-test hold).

4. **Lint whitelist update**: `Accounts/AccountsManagerTests.swift` added to AccountsManagerIsolationLintTests whitelist (tests the DI seam itself, analogous to PalaceWiringTestCaseTests).

5. **Tooling fix**: `scripts/check-blast-radius.py` BR-1 now honors `// PUBLIC_INTENT:` annotation (matches the pre-public-surface-drift.sh hook behavior). The reference memory said both gates honored it; this lands the missing half.

## Anti-claims

- Does NOT change production behavior beyond DI seam (all callers preserved via default arg).
- Does NOT add safety-net fallbacks (`?? .standard`).
- Does NOT touch Keychain integration tests.
- Does NOT flip random test order.

## Files in scope

See claims above. Production: 5 files. Test: ~50 files (8 D-migrations + 33 E-teardowns + lint whitelist edit). Tooling: 1 (check-blast-radius.py PUBLIC_INTENT support).
