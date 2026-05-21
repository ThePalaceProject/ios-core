# Module D — Test cleanup

**Status:** skeleton — architect to refine on triage AND inventory.

## In-scope files (architect determines exact list)

Architect runs `grep -rn "setUp resets shared\|reset.*shared\|setUp.*\.shared" PalaceTests --include='*.swift'` during triage and writes the file list into this contract.

Likely candidates per the ADR:
- `PalaceTests/Audiobook/` — files that reset shared mocks in setUp
- `PalaceTests/SignInLogic/` — SAML test flake-timeout bumps tied to shared-state contention

## Out-of-scope (read-only)

- All production code (Modules A/B/C own those)
- `PalaceTests/Contract/` (cross-swarm; only Module D may touch IF architect explicitly authorizes audiobook-side contract tests)
- `PalaceTests/Audiobook/AudiobookPositionPolicyTests.swift` (P0 read-side regression gate)
- All files in swarm-wide don't-touch list

## Migration approach

For each identified test class:
1. Identify what shared-mock state was reset in `setUp` and why
2. After Module B's singleton elimination, the shared state no longer exists — the reset is a no-op
3. Delete the reset code
4. If the test ALSO had a flake-timeout bump (e.g., `expectation.timeout = 30.0`) tied to the shared-state race, restore the default (`expectation.timeout = 1.0` or remove the line)
5. If the test had `setUp { tearDownShared(); reset(); … }` boilerplate it can ALL be deleted now

## Acceptance criteria

- Net negative LOC on Module D's diff — workarounds removed > new shims added
- No new XCTSkip annotations (we're removing workarounds, not adding skips)
- All Audiobook + SignInLogic tests still pass — `xcodebuild test -only-testing:PalaceTests/<each class>`
- `grep "setUp resets shared\|reset.*Mock.*shared" PalaceTests --include='*.swift'` returns 0

## Implementer prompt

You are Module D implementer for `swarm_03acb10a`. You depend on Modules A, B, C — production code must compile.

PRE-WORK:
1. Write transcript skeleton FIRST.
2. Read the architect's inventory in `transcripts/triage.md` — the file list is there.
3. For each file: delete the `setUp` shared-reset code; restore default test timeouts; verify the test still passes.

This module's success is measured in LOC removed. If the diff is +200/-50 you've gone wrong — re-scope.

Validate: `xcodebuild test` on each migrated test file passes; full audiobook test surface still passes.

Write transcript. Do NOT commit, push, or dispatch agents.
