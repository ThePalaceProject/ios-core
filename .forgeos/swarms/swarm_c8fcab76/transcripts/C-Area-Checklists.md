# Module C — Per-area verification checklists — implementer transcript

**Swarm:** `swarm_c8fcab76`
**Module:** C — Per-area Verification Checklists (DOCS-ONLY)
**Branch:** `swarm/swarm_c8fcab76-C-Area-Checklists`
**Worktree:** `/Users/mauricework/PalaceProject/ios-core/.claude/worktrees/swarm_c8fcab76-C-Area-Checklists`
**Status:** READY FOR INTEGRATION

## Scope delivered

Three new per-area verification checklists, modeled on the auth checklist that landed in PR #1019:

- `docs/architecture/areas/mybooks/verification-checklist.md` — 153 lines
- `docs/architecture/areas/audiobook/verification-checklist.md` — 178 lines
- `docs/architecture/areas/accounts/verification-checklist.md` — 204 lines

Each checklist covers (per contract):

- **(a)** Critical-path invariants for the area — borrow/return/download/DRM (mybooks), session/playback/CarPlay/toolkit (audiobook), state-machine readiness + enum semantics (accounts).
- **(b)** ≥3 cross-referenced source documents (memory pins, audits, architecture docs). Actual counts via `grep -cE '\.forgeos/|reference_|feedback_|docs/architecture/|phase[0-9]_|carplay_|lcp_|enum_conflation|singleton_audit|saml_two_surface|audiobook_first_open'`: mybooks 13, audiobook 17, accounts 19.
- **(c)** Grep-able verification commands the architect-reviewer or pre-commit hook could run (§ 6 / § 7 architect pre-swarm checklist sections in each file).
- **(d)** ≥3 `<!-- audit-verified -->` markers on factual claims: mybooks 4, audiobook 4, accounts 5.

Template fidelity vs `docs/architecture/areas/auth/verification-checklist.md` (read from main checkout — the worktree is off `origin/develop` which does NOT have the auth checklist): each new file has the same load-bearing sections in the same order — Call-site map (or area-equivalent), Module ownership, Test surface, Known traps / anti-patterns, Architect's pre-swarm checklist, Refresh history. Area-specific sections (Decomposition map for mybooks, Cross-vendor smoke + crash catalog for audiobook, State machine surface + Enum semantics + Singleton posture for accounts) replace auth's domain-specific sections (Dispatch matrix / IdP table / Telemetry surface) in equivalent slots.

## Definition of Done — evidence

### 1. SUT instantiation check

**N/A — docs-only.** No `.swift` test files added.

### 2. Function-result usage check

**N/A — docs-only.** No production-code calls added.

### 3. Multi-step test body check

**N/A — docs-only.** No tests added.

### 4. Scope coverage audit

All three contracted files exist, each ≥50 lines, each has ≥3 `<!-- audit-verified -->` markers, each has ≥3 cross-references:

```
$ wc -l docs/architecture/areas/{mybooks,audiobook,accounts}/verification-checklist.md
     153 docs/architecture/areas/mybooks/verification-checklist.md
     178 docs/architecture/areas/audiobook/verification-checklist.md
     204 docs/architecture/areas/accounts/verification-checklist.md
     535 total

$ for f in docs/architecture/areas/{mybooks,audiobook,accounts}/verification-checklist.md; do
    echo "$f: $(grep -c 'audit-verified' "$f")"
  done
docs/architecture/areas/mybooks/verification-checklist.md: 4
docs/architecture/areas/audiobook/verification-checklist.md: 4
docs/architecture/areas/accounts/verification-checklist.md: 5

$ for f in docs/architecture/areas/{mybooks,audiobook,accounts}/verification-checklist.md; do
    echo "$f: $(grep -cE '\.forgeos/|reference_|feedback_|docs/architecture/|phase[0-9]_|carplay_|lcp_|enum_conflation|singleton_audit|saml_two_surface|audiobook_first_open' "$f")"
  done
docs/architecture/areas/mybooks/verification-checklist.md: 13
docs/architecture/areas/audiobook/verification-checklist.md: 17
docs/architecture/areas/accounts/verification-checklist.md: 19
```

All exceed the contract's verification thresholds (≥50 lines, ≥3 audit-verified, ≥3 cross-refs).

### 5. Mutation pass

**N/A — docs-only.** No production code touched.

### 6. Build + verify-pr

Build is not relevant for docs-only. The relevant invariant is the docs-only invariant itself:

```
$ git diff --name-only
adept-ios
adobe-content-filter
ios-audiobook-overdrive
ios-tenprintcover
mobile-bookmark-spec
readium-sdk
readium-shared-js

$ git status --porcelain | grep '^??'
?? docs/architecture/areas/
```

`git diff --name-only` shows only pre-existing submodule typechanges (NOT introduced by this module — they're a worktree-setup artifact from `git status` reporting on submodule links). NO `.swift`, `.pbxproj`, `.py`, `.sh`, `.rb`, `.m`, or `.h` files appear in the diff. Untracked addition is exactly the new `docs/architecture/areas/` subtree containing only the three new checklist files.

Contract verification commands:

```
$ test -f docs/architecture/areas/mybooks/verification-checklist.md && \
  test -f docs/architecture/areas/audiobook/verification-checklist.md && \
  test -f docs/architecture/areas/accounts/verification-checklist.md && echo OK
OK

$ git status --porcelain | grep -E '\.swift$|\.pbxproj$|\.m$|\.h$|\.py$|\.sh$|\.rb$' | grep -v '^??'
(empty)

$ git status --porcelain Palace/SignInLogic/ Palace/Packages/PalaceAuth/ \
    Palace/Accounts/Library/AccountsManager.swift \
    Palace/Accounts/Library/Account+State.swift \
    Palace/Accounts/Library/AccountStateStore.swift | grep -v '^??'
(empty)
```

All contract assertions PASS.

## Template fidelity grep paste

Auth checklist (read from main checkout — the C worktree is off `origin/develop` which does NOT have it):

```
$ grep -E '^##? ' /Users/mauricework/PalaceProject/ios-core/docs/architecture/areas/auth/verification-checklist.md
# Auth area — verification checklist
## 1. Call-site map (sites that handle 401/403, mutate TPPUserAccount, or read AccountDetails)
## 2. Module ownership
## 3. AuthCoordinator dispatch matrix (verify before changing routing logic)
## 4. IdP × scenario truth table (subset — full version at `docs/3.2.0-auth-idp-catalog.md`)
## 5. Telemetry surface points (every auth decision emits)
## 6. Test surface
## 7. Known traps / anti-patterns (lessons from prior work)
## 8. Architect's pre-swarm checklist (what to verify before writing a new contract)
## 9. Refresh history
```

MyBooks checklist:

```
# MyBooks area — verification checklist
## 1. Call-site map (critical-path entry points + invariants)
## 2. Module ownership
## 3. Decomposition map (Phase 7 PR #890 — what came from where)
## 4. Test surface
## 5. Known traps / anti-patterns (lessons from prior work)
## 6. Architect's pre-swarm checklist (what to verify before writing a new contract)
## 7. Refresh history
```

Audiobook checklist:

```
# Audiobook area — verification checklist
## 1. Call-site map (critical-path entry points + invariants)
## 2. Module ownership
## 3. Cross-vendor smoke test (mandatory before merging anything that touches Palace/Audiobooks or bumps the submodule)
## 4. Known crash / regression catalog (recent — keep this current)
## 5. Test surface
## 6. Known traps / anti-patterns (lessons from prior work)
## 7. Architect's pre-swarm checklist (what to verify before writing a new contract)
## 8. Refresh history
```

Accounts checklist:

```
# Accounts area — verification checklist
## 1. State machine surface (Account `LoadState` transitions + the readiness gate)
## 2. Critical-path invariants (what MUST NOT regress)
## 3. Enum semantics — `AccountLoadError.accountNotFound` is overloaded (backlog refactor)
## 4. Singleton posture — `.shared` removal target
## 5. Test surface
## 6. Known traps / anti-patterns (lessons from prior work)
## 7. Architect's pre-swarm checklist (what to verify before writing a new contract)
## 8. Refresh history
```

**Verdict:** load-bearing sections (Call-site map / Module ownership / Test surface / Known traps / Pre-swarm checklist / Refresh history) align section-for-section with the auth template. Area-specific sections (Decomposition map / Cross-vendor smoke + Crash catalog / State machine surface + Enum semantics + Singleton posture) replace auth's domain-specific sections (Dispatch matrix / IdP table / Telemetry surface) in equivalent slots. This is the intended template fidelity — same load-bearing shape, area-specific content.

## audit-before-assert hook status (per contract clause)

The contract instructs: "If `audit-before-assert.py` does not exist on the current branch (it landed in PR #1019 alongside the auth checklist template), the implementer must: 1. Confirm presence with `test -f scripts/audit-before-assert.py`. 2. If absent: SKIP the audit-before-assert pass and instead manually validate each factual claim with a grep paste in the checklist file's PR description. Flag the absence to the orchestrator."

```
$ ls scripts/audit-before-assert.py 2>/dev/null && echo EXISTS || echo MISSING
MISSING
```

**The hook script does NOT exist on this branch.** Per the contract fallback, I have:

1. Manually validated each factual claim in the file-level `<!-- audit-verified -->` comments at the top of each checklist (sourcing every claim to a named memory pin + the grep used to verify the file paths exist on this branch).
2. Each `<!-- audit-verified -->` comment in the body documents the specific memory pin / PR / commit SHA that grounds the claim cluster following it.
3. The hook IS present in the main checkout (`/Users/mauricework/PalaceProject/ios-core/scripts/hooks/audit-before-assert.py`) and will run against these files once this branch is merged through PR #1019's landed hook.

**Flagged to orchestrator:** the audit-before-assert hook is in `scripts/hooks/` in the main checkout but not on `origin/develop`. PR #1019 (which landed the auth checklist + hook) is the source. Module C cannot import the hook itself per the docs-only constraint; the integrator should merge PR #1019 first OR cherry-pick the hook commit before running the hook against this work.

## Anti-scope confirmation

Module C contract anti-scoped `Palace/SignInLogic/`, `Palace/Packages/PalaceAuth/`, `AccountsManager.swift`, `Account+State.swift`, `AccountStateStore.swift`. The accounts checklist DESCRIBES those files (call-site map references the line numbers documented in `enum_conflation_account_not_found.md`) but does NOT modify them:

```
$ git status --porcelain Palace/SignInLogic/ Palace/Packages/PalaceAuth/ \
    Palace/Accounts/Library/AccountsManager.swift \
    Palace/Accounts/Library/Account+State.swift \
    Palace/Accounts/Library/AccountStateStore.swift | grep -v '^??'
(empty)
```

Anti-scope satisfied.

## What I read but did NOT modify (for traceability)

- `/Users/mauricework/PalaceProject/ios-core/docs/architecture/areas/auth/verification-checklist.md` (template — read-only, from main checkout)
- `/Users/mauricework/PalaceProject/ios-core/.forgeos/audits/phase7-synthesis-2026-05-26.md` (Phase 7 audit synthesis — read-only)
- `~/.claude/projects/-Users-mauricework-PalaceProject-ios-core/memory/`:
  - `phase7_borrow_path_regressions_2026_05_14.md`
  - `audiobook_first_open_hang_3_2_0.md`
  - `carplay_crash_3_1_0_build_476.md`
  - `lcp_player_continuation_misuse_2026_05_26.md`
  - `reference_biblioboard_cross_host_token_scoping.md`
  - `reference_audiobook_toolkit_risk_profile.md`
  - `phase1_account_state_machine_2026_05_19.md`
  - `feedback_round_trip_wiring_tests.md`
  - `enum_conflation_account_not_found.md`
  - `singleton_audit_2026_04_24.md`
  - `saml_two_surface_auth_model.md`
  - `feedback_test_patterns_phase7.md`
  - (universal-rule pins) `feedback_no_force_unwraps.md`, `feedback_swift_concurrency_over_gcd.md`, `feedback_tdd_mandatory.md`, `feedback_no_preexisting_failures.md`
- Palace source files (grep-source only, read-only):
  - `Palace/MyBooks/*.swift` (file enumeration for § 1 call-site map)
  - `Palace/Audiobooks/*.swift` (file enumeration for § 1 call-site map)
  - `Palace/Accounts/Library/*.swift` (file enumeration for § 1 state machine surface — described, NOT modified)
  - `Palace/Book/UI/BookDetail/{BorrowReducer,BookButtonMapper}.swift`
  - `PalaceTests/{MyBooks,Audiobooks,Accounts,CarPlay}/*.swift` (test inventory grep for § 4 / § 5 test surface)

## Reporting

**READY FOR INTEGRATION.** Three checklists exist, each meets line-count + audit-verified + cross-reference thresholds, anti-scope respected, no Swift / project / script files touched. Did not commit; did not push. Orchestrator picks up from here.
