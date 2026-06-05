# Module B — Foreign-Host 401 Scoping Detector

**Owner module:** scripts/ + .claude/settings.json + scripts/verify-pr.sh
**Risk:** critical_path (catches the PR #1044 / PR #1018 class — auth misattribution → repeated logout)
**Est LOC:** ~250 (Python detector ~150, tests ~70, wire-in ~10, fixtures ~20)

## Scope (in)

| File | Change | Est LOC |
|------|--------|---------|
| `scripts/check-foreign-host-401-scoping.py` (NEW) | The detector. Reads a unified diff OR file list; emits findings; exit codes mirror `check-blast-radius.py`. Uses `scripts/_checklib.py` helpers. | +150 |
| `scripts/test_check_foreign_host_401_scoping.py` (NEW) | pytest: PASS fixture (proper scoping), FAIL fixture (raw 401 dispatch with no host check), annotated-exception fixture (`// no-host-scoping:` allows it). At minimum 6 tests: detect_dispatch_without_guard, allow_with_authSurfaceHosts_grep, allow_with_currentAccountHostsProvider_grep, allow_with_no_host_scoping_annotation, allow_when_no_401_in_scope, allow_when_no_dispatch_in_scope. | +70 |
| `scripts/tests/fixtures/foreign_host_401/violation.swift` (NEW) | minimal Swift fixture: `if (response as? HTTPURLResponse)?.statusCode == 401 { Task { await coordinator.refreshCredentialsIfNeeded(reason: .unknown401) } }` — no host scoping. | +12 |
| `scripts/tests/fixtures/foreign_host_401/clean_with_provider.swift` (NEW) | minimal fixture mirroring `Palace/Network/TPPNetworkResponder.swift` — same 401 dispatch but with `currentAccountHostsProvider` referenced. | +15 |
| `scripts/tests/fixtures/foreign_host_401/clean_with_inline_guard.swift` (NEW) | minimal fixture mirroring `Palace/MyBooks/TokenRefreshInterceptor.swift` — same dispatch but with `authSurfaceHosts` referenced in the same function. | +15 |
| `scripts/tests/fixtures/foreign_host_401/annotated_skip.swift` (NEW) | fixture with `// no-host-scoping: legacy CarPlay path documented in foo.md` annotation on the dispatch line. | +10 |
| `scripts/verify-pr.sh` | Add a new step block after the "## 3a-3e. M1 universal-rigor-floor gates" section, before "## 4. Coverage floors". Use the existing `run_m1_check` helper. Script invocation in `--quick` and full modes. Skipped under `--mutation-only`. | +12 |
| `.claude/settings.json` | Add one PreToolUse Bash hook entry pointing to `bash scripts/hooks/pre-commit-foreign-host-401-scoping.sh` in the existing "Edit|Write|MultiEdit" or `Bash` cluster — see Module A's pattern. Timeout 8s. | +8 |
| `scripts/hooks/pre-commit-foreign-host-401-scoping.sh` (NEW) | thin wrapper: get staged diff, pipe to `python3 scripts/check-foreign-host-401-scoping.py --diff -`, exit non-zero on failure. Mirror `scripts/hooks/pre-public-surface-drift.sh` shape. | +25 |

**NOTE on test path:** the task brief specified `scripts/tests/test_check_foreign_host_401_scoping.py`. The existing project convention is `scripts/test_check_<name>.py` directly under `scripts/` (8 detectors already follow it). Module B will land tests at the existing convention path `scripts/test_check_foreign_host_401_scoping.py`. Fixtures land at `scripts/tests/fixtures/foreign_host_401/` (the test-data directory IS new and matches the brief's intent for `scripts/tests/...`). If Maurice wants the test file relocated under `scripts/tests/`, that's a one-line directory move in the contract; flag at Phase 1a.

## Detector specification

**Identifies a call site that:**

1. Has `statusCode == 401` (or `.statusCode == 401`) in scope — defined as the enclosing function body — AND
2. Calls one of:
   - `markCredentialsStale()` (any receiver)
   - `coordinator.refreshCredentialsIfNeeded` (any qualifier — `coordinator.` / `self.coordinator.` / `authCoordinator.`)
   - `AuthCoordinator.refreshCredentialsIfNeeded` (static-style)
   - `Task { ... await coordinator... }` / `Task { ... await authCoordinator... }` body containing `refreshCredentialsIfNeeded` or `markCredentialsStale`
3. AND in the same enclosing function body, does NOT reference any of:
   - `authSurfaceHosts`
   - `currentAccountHostsProvider`
   - `// no-host-scoping:` annotation (anywhere on the dispatch line or the 3 preceding lines)

**Function-body scope detection:** simple bracket-counting parser (mirrors `check-blast-radius.py`'s `_AddedLine` walker). Don't try to handle every Swift edge case — a heuristic that catches the class is sufficient. False-positive escape hatch: `// no-host-scoping: <reason>`.

**Output:** greppable `<file>:<line>: FH-1: high: 401 dispatch site has no current-account host-scoping reference in function body — Wall: PR #1044 / .forgeos/wall-failures/2026-06-05-pr1018-icarus-cross-host-logout.md`

**Exit codes:** 0 (no findings ≥ floor), 1 (≥1 finding at high), 2 (script error). Mirror `check-blast-radius.py` exactly.

**Flags:** `--diff <file>` (default stdin), `--severity-floor`, `--no-block`, `--quiet`, `--dry-run`. Same set as sibling detectors.

**Scan mode:** when called with `--scan <repo-root>` instead of `--diff`, walk all Swift files under `Palace/` directly (not a diff) and emit findings the same way. This is how the orchestrator (and the architect predicting survivors below) runs the one-time wipe.

## Predicted survivors (architect's pre-run guess)

After PR #1044, the 3 known foreign-host 401 dispatch sites are guarded:
- `Palace/Network/TPPNetworkResponder.swift` line ~510 (uses `currentAccountHostsProvider`)
- `Palace/MyBooks/TokenRefreshInterceptor.swift` line ~106 (uses inline `authSurfaceHosts` guard)
- `Palace/MyBooks/DownloadAuthRetryHandler.swift` line ~212 (uses inline `authSurfaceHosts` guard)

**Predicted survivors: 1 (revised post-Phase-1a review).** Beyond the `statusCode == 401` literal, the architect-reviewer caught a sibling semantic site:
- `Palace/Network/TPPNetworkExecutor.swift:582-585` dispatches `markCredentialsStale()` on `userAccount(for: capturedAccountId ?? currentAccountId ?? "")` when `nsError.code == 401`. The `??` fallback to current account is NOT host-scoped — same bug class as PR #1044, different syntax.

**Detector predicate (Phase-1a-revised):** extend to also match `nsError.code == 401`, `error.code == 401`, `(error as NSError).code == 401` when paired with credential-stale dispatch in the same function scope. Mirror the same `// no-host-scoping:` annotation escape hatch. The architect's original predicate matched only `statusCode == 401` literal and would have missed this site.

The 3 known PR #1044 sites remain guarded; the new survivor will be wiped using the same canonical pattern (inline host-scope guard before the mark-stale + dispatch, or replacement of the `??` fallback with an `authSurfaceHosts`-checking branch).

**Possible false-positive sites that need `// no-host-scoping:`:**
- `Palace/SignInLogic/TPPSignInBusinessLogic+SignOut.swift` — sign-out flow may dispatch `markCredentialsStale` in a 401-adjacent path. If detector flags, annotate with `// no-host-scoping: explicit sign-out; current account by definition`.

If the run discovers survivors:
- Trivial (single inline scope fix): apply in this same PR via the PR #1044 canonical pattern (`currentAccountHostsProvider` closure OR `authSurfaceHosts` inline guard).
- Non-trivial (entangled dispatch): scope-defer per the guardrail in Module A's Phase 3.5 spec, file a follow-up Jira, the detector still lands and gates the deferred site at its next-touch commit.

## Scope (out — DO NOT touch)

- `Palace/Packages/PalaceAuth/Sources/PalaceAuth/AuthErrorClassifier.swift` — already fixed by PR #1044; the detector does not need to touch it. The detector treats `currentAccountHostsProvider` as the canonical wiring evidence.
- `Palace/Accounts/Library/Account.swift` `authSurfaceHosts` property — already exists from PR #1044. Detector treats its reference as wiring evidence.
- The 3 known dispatch sites — already guarded post-#1044. Detector should record them as clean (PASS); if it flags them, the heuristic is wrong and needs tightening.
- Production code style/coverage outside the detector's class — Module B is the detector + wipe. Don't widen.
- Module A's docs — Module A owns those; Module B may cite them but does NOT edit them.

## Verification criteria (grep-able)

1. `python3 scripts/check-foreign-host-401-scoping.py --scan Palace/ --quiet` exit 0 (zero survivors predicted; if not, wipe per discipline guardrails)
2. `python3 scripts/check-foreign-host-401-scoping.py --diff scripts/tests/fixtures/foreign_host_401/violation.swift --quiet` exit 1 with FH-1 finding
3. `python3 scripts/check-foreign-host-401-scoping.py --diff scripts/tests/fixtures/foreign_host_401/clean_with_provider.swift --quiet` exit 0
4. `python3 scripts/check-foreign-host-401-scoping.py --diff scripts/tests/fixtures/foreign_host_401/clean_with_inline_guard.swift --quiet` exit 0
5. `python3 scripts/check-foreign-host-401-scoping.py --diff scripts/tests/fixtures/foreign_host_401/annotated_skip.swift --quiet` exit 0
6. `pytest scripts/test_check_foreign_host_401_scoping.py -v` 6/6 PASS
7. `grep -n "check-foreign-host-401-scoping" scripts/verify-pr.sh` ≥ 1 line
8. `grep -n "pre-commit-foreign-host-401-scoping" .claude/settings.json` ≥ 1 line
9. `scripts/verify-pr.sh --quick` PASS on the post-Module-B branch

## Tests required

`scripts/test_check_foreign_host_401_scoping.py` — 6 tests minimum:
- `test_detector_flags_raw_401_dispatch_without_scoping` (FH-1 emitted)
- `test_detector_clean_with_currentAccountHostsProvider_reference`
- `test_detector_clean_with_inline_authSurfaceHosts_reference`
- `test_detector_clean_with_no_host_scoping_annotation`
- `test_detector_clean_when_no_401_in_scope` (dispatch without 401 — not our class)
- `test_detector_clean_when_no_dispatch_in_scope` (401 logged but no markCredentialsStale/refresh)

Each test invokes the detector's main entry point with a tempfile of fixture Swift, asserts exit code + the FH-1 line shape (or absence).

## Acceptance

- All 9 verification criteria pass
- `pytest scripts/test_check_foreign_host_401_scoping.py` 6/6 PASS
- `scripts/verify-pr.sh --quick` PASS
- The architect's predicted-0-survivors guess proven correct OR the wipe is applied with PR #1044 canonical pattern at any survivor site
- `.claude/settings.json` hook entry registered and `bash scripts/hooks/pre-commit-foreign-host-401-scoping.sh` is executable (chmod +x)
- A wall-failure entry already exists for this class (`2026-06-05-pr1018-icarus-cross-host-logout.md`); update its frontmatter to set `detector_script: scripts/check-foreign-host-401-scoping.py` and `detector_status: built`, and add a `## Detector script` body section. This counts as a backfill of Module A's TEMPLATE convention and is in-scope for Module B.

## Round-trip wiring requirement

N/A — detector is stateless.

## Mutation requirement

Python — palace_mutate.py is Swift-only. Code-coverage on `scripts/check-foreign-host-401-scoping.py` via the pytest run is the equivalent gate. Aim for `coverage report` line coverage ≥ 80% on the script. (Existing detectors do not run palace_mutate.py against Python — this is the established convention.)
