# Module A — Accounts + MyBooks AccountId Threading — Transcript

Branch: `swarm/swarm_eefef87a-module-A`
Swarm: `swarm_eefef87a` (A+ Posture Push, Improvement #1)
ForgeOS changeset: `cs_34366ad3`

## 1. Files added / modified

- MOD `Palace/Network/TPPNetworkExecutor.swift` (+50) — added `bearerAuthorized(request:accountId:)` overload; legacy `bearerAuthorized(request:)` delegates with `accountId: nil`
- MOD `Palace/MyBooks/MyBooksDownloadCenter.swift` (+101) — capture `accountIdAtDownloadStart` at startDownloadAsync entry; thread through 8 fallback sites
- MOD `Palace/MyBooks/DownloadStartCoordinator.swift` (+81) — propagate accountId from boundary
- MOD `Palace/MyBooks/DownloadStartDispatcher.swift` (+86) — line 182 callsite uses bearerAuthorized(request:accountId:)
- MOD `PalaceTests/Accounts/AccountsManagerStateMachineWiringTests.swift` (+149) — Test 8 round-trip A→nil→A→B
- NEW `PalaceTests/MyBooks/MyBooksDownloadCenterAccountIdThreadingTests.swift` (≥6 cases)
- MOD `Palace.xcodeproj/project.pbxproj` (+4) — new test file registration via scripts/pbxproj_add_swift.rb

## 2. Tests added

- Test 8 in AccountsManagerStateMachineWiringTests: `testStartDownload_currentAccountIdFlipsToNilDuringDownload_useCapturedAccountId` — full A→nil→A→B round-trip through `startDownloadAsync` production seam (NOT via `_setCapturedAccountId` shortcuts per the round-trip wiring test rule)
- 6 cases in MyBooksDownloadCenterAccountIdThreadingTests covering: capture-once, sentinel-on-nil, no-re-resolve-after-capture, explicit-accountId-token-application, nil-delegates-to-resolver, no-AppContainer-touch

## 3. Key decisions

- Option 1 only (capture-at-start). Options 2 (last-known-good cache) and 3 (full fallback removal) deferred to follow-up changesets per the contract's scope-tightening directive.
- `AccountsManager.currentUserAccount` resolver left untouched (Option 2 mitigation `lastKnownCurrentUserAccount` already deployed there).
- `AppContainer.production()` retained ONLY in the legacy no-arg overload's resolver path, documented as the migration tail.
- Sentinel UUID `AccountsManager.noAccountSentinelUUID` used when `currentAccountId` is nil at capture time — explicit placeholder, NOT a silent fallback to a different account.

## 4. Gaps for the integrator

- Behavior change: long-running downloads against a swapped-away library will refresh tokens against the captured-at-start account. Intentional per the contract; flag in PR description.
- Mutation kill rate not measured in worktree due to AudioEngine duplicate-command build issue (same as Module B). Re-run from main checkout post-merge.

## 5. Mutation results + verify-pr posture

Deferred — see Gaps. To be measured during integration.
