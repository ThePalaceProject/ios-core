---
name: swarm_eefef87a-contract-C-Tooling
type: immutable
status: active
created: 2026-05-26T15:00:00Z
last_refresh: 2026-05-27
freshness_window: never
owners: [accounts, mybooks]
description: "Module C — Tooling: verify-pr.sh gate + critical-path ADR"
---

# Module C — Tooling: verify-pr.sh gate + critical-path ADR

**Improvements #2 (script portion) and #3 (regex audit + ADR) merged into one tooling-side contract.** Reason: both edit `scripts/verify-pr.sh`. Merging into one implementer is the simplest disjoint partition.

## In-scope files (exclusive write)

- MOD `scripts/verify-pr.sh` — TWO edits:
  1. Expand `CRITICAL_MUTATION_PATHS_REGEX` (currently at line 73) to cover every critical-path surface, after enumerating below.
  2. Add a NEW gate after the mutation step: "Audiobook cross-vendor smoke" — when any `Palace/Audiobooks/` or `ios-audiobooktoolkit/` file is in the diff, invoke `xcodebuild ... -only-testing:PalaceTests/AudiobookCrossVendorSmokeTests test`. Block if any of the four smoke cases fail.
- NEW `docs/architecture/critical-path-mutation-coverage.md` — ADR documenting the regex, the enumeration methodology, the files included, the files explicitly NOT included (with reasoning), and the maintenance contract.

## OFF-LIMITS for this module

- `Palace/` (no production code edits)
- `PalaceTests/` (no test edits — Module B owns the smoke Swift file)
- Other ADRs in `docs/architecture/`

## Critical-path enumeration (output of Improvement #3 — must be in ADR)

Walk every Palace/ file that touches one of the user-money / access-bearing surfaces below. Cross-reference with the current regex at `scripts/verify-pr.sh:73` (`^Palace/(Audiobooks|SignInLogic|MyBooks/Download|Book/UI/BookDetail/BookButtonMapper)`).

For EACH surface, list every file the audit covers AND every file currently missing from the regex:

| Surface | Currently in regex | Files to include |
|---|---|---|
| **Sign-in** | `Palace/SignInLogic` ✓ | Enumerate: also `Palace/Accounts/User/TPPUserAccount.swift`? `Palace/Accounts/Library/AccountsManager.swift`? `Palace/Network/TPPNetworkExecutor.swift`? Make the call in the ADR — these are auth-critical but live outside `SignInLogic/`. |
| **Borrow** | None directly ✗ | `Palace/MyBooks/BorrowOperation.swift`, `Palace/MyBooks/BorrowReducer.swift`, `Palace/MyBooks/BorrowErrorPresenter.swift`, `Palace/MyBooks/BookSignInRedirectHandler.swift`. The Phase 7 borrow-path regressions live here. |
| **Download** | `Palace/MyBooks/Download` ✓ | Confirm prefix matches: `DownloadStartCoordinator.swift`, `DownloadStartDispatcher.swift`, `DownloadAuthRetryHandler.swift`, `DownloadCompletionParser.swift`, `DownloadQueueOrchestrator.swift`, `DownloadStateManager.swift`, `DownloadTaskLifecycleService.swift`, `DownloadThrottlingService.swift`, `DownloadAlertPresenter.swift`, `DownloadCancellationHandler.swift`, `DownloadProgressPublisher.swift`. |
| **DRM** | None ✗ | `Palace/MyBooks/AdobeDRMHandler.swift`, `Palace/MyBooks/LCPFulfillmentHandler.swift`, `Palace/MyBooks/RightsManagementDispatcher.swift`. Also `Palace/Reader2/ReaderStackConfiguration/AdobeDRM/*` if those exist. |
| **Playback** | `Palace/Audiobooks` ✓ + Reader2? ✗ | Audiobooks already covered. Reader2 playback (EPUB rendering + bookmarks + position sync) is XCTest-invisible per the task description — covered by Module D contract snapshots instead, not by mutation testing. The ADR must explicitly document this exemption. |
| **Payment** | n/a | Palace is a library app, no payment surface — note "N/A by product surface" in the ADR. |
| **Catalog routing** (the `BookButtonMapper` finding from phase7 audit) | `Palace/Book/UI/BookDetail/BookButtonMapper` ✓ | Already added by PR #1003. Confirm coverage extends to siblings: walk `Palace/Book/UI/BookDetail/` for other state-router files. |

The implementer's job: do the enumeration with `find` + `grep`, write the result table into the ADR, then construct the regex that matches every chosen file. The regex MUST be tested with the ADR-listed files (positive cases) and a sampler of non-critical files (negative cases) — show the test commands in the ADR's "Verification" section.

## Acceptance criteria

- `scripts/verify-pr.sh:73`: regex updated. Tested against every file listed in the ADR's "Critical-path files" section.
- New audiobook smoke gate added after the existing mutation step. Gated on `git diff` containing `^Palace/Audiobooks/` or `^ios-audiobooktoolkit/`. Runs `-only-testing:PalaceTests/AudiobookCrossVendorSmokeTests`. Fails the verify-pr run if any smoke case fails.
- `docs/architecture/critical-path-mutation-coverage.md` exists. Sections required:
  1. **Context** — why a critical-path mutation gate exists; reference `phase7-synthesis-2026-05-26.md` and the `BookButtonMapper` finding.
  2. **Enumeration methodology** — exactly how the implementer walked the codebase to pick files. Reproducible.
  3. **Critical-path files** — the complete table with surface → file mapping.
  4. **Exempted files** — files that touch a critical surface but are explicitly NOT in the regex (e.g. Reader2 — note Module D's contract-snapshot strategy as the alternative coverage).
  5. **Verification** — bash commands that prove the regex matches and rejects the right files. Include the actual output.
  6. **Maintenance** — when to re-run this audit (after any file rename in the listed surfaces; after any PR that adds a new state machine, retry handler, or borrow/download/DRM router).
- `scripts/verify-pr.sh --quick` on a docs-only change still hits the docs fast-path (don't regress that).
- The audiobook smoke gate does NOT run when no audiobook files changed (don't slow non-audiobook PRs).
- No edits in off-limits list.

## Implementer prompt

You are Module C implementer for `swarm_eefef87a`. You merge two improvements that both touched `scripts/verify-pr.sh`. Read the current `scripts/verify-pr.sh` (~750 lines) and `.forgeos/audits/phase7-synthesis-2026-05-26.md` (96 lines) before writing.

**Step order:**
1. Write `transcripts/C-Tooling.md` skeleton FIRST.
2. Enumerate the critical-path files (Improvement #3's audit work). Use `find Palace -name "*.swift" -path "*Borrow*" -o -name "*Download*" -o -name "*Auth*" -o -name "*DRM*"` as the starting query but VERIFY each match by reading the file's purpose — don't include test scaffolding or mock files.
3. Construct the new regex. Test it against:
   - Every file in your enumeration (must match).
   - A sample of 5+ non-critical files like `Palace/Views/SomeView.swift` (must NOT match).
   - Edge cases: file names that contain "Borrow" but aren't borrow surfaces.
4. Write the ADR. Include the bash verification commands and their actual output.
5. Update `scripts/verify-pr.sh:73` with the new regex.
6. Add the audiobook smoke gate. Pattern:
   ```bash
   # Audiobook cross-vendor smoke
   echo "--- Audiobook Cross-Vendor Smoke ---"
   AUDIOBOOK_CHANGED=$(echo "$ALL_CHANGED" | grep -E '^Palace/Audiobooks/|^ios-audiobooktoolkit/' || true)
   if [ -n "$AUDIOBOOK_CHANGED" ]; then
     SMOKE_OUTPUT=$(xcodebuild ... -only-testing:PalaceTests/AudiobookCrossVendorSmokeTests test 2>&1 || true)
     ...
   else
     record "audiobook_smoke" "pass" "Skipped (no audiobook files changed)"
   fi
   ```
   Match the existing `record` / pass-fail pattern. Maintain the JSON report output schema.
7. Run `scripts/verify-pr.sh --quick` on the current diff to confirm the script still functions.
8. Fill out the transcript.

**No edits to Palace/ or PalaceTests/.** If you find a critical-path file that needs a behavior change, escalate — that's Module A or a follow-up PR, not this module.

Do NOT commit. Do NOT push. Stage for the integrator.
