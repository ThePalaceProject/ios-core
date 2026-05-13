# Palace iOS — Testing Posture

Last updated: 2026-04-16

## Testing Pyramid

```
                    ┌─────────┐
                    │ Manual  │  Device testing, SAML IdP flows,
                    │ Device  │  audiobook playback, DRM fulfillment
                    ├─────────┤
                 ┌──┤ E2E     │  simdrive (canonical, vision-first) drives
                 │  │ (sim    │  iOS sim. Active: .simdrive/fixtures/flows/,
                 │  │  drive) │  .simdrive/journeys/, .simdrive/replays/chaos/.
                 │  │         │  Legacy: .simdrive/_archive/ (do not extend)
                 │  ├─────────┤
              ┌──┤  │ Integra-│  6 integration tests, contract tests,
              │  │  │ tion    │  mock backend scenarios
              │  │  ├─────────┤
           ┌──┤  │  │ Unit    │  5,823 tests, 367 files, 674 classes
           │  │  │  │         │  Mutation testing, coverage floors
           └──┴──┴──┴─────────┘
```

| Layer | Count | Automation | CI Gated |
|-------|-------|------------|----------|
| Unit tests | 5,823 methods / 674 classes | Fully automated | Yes (blocking) |
| Integration | 6 test files | Fully automated | Yes (in unit suite) |
| Contract/API | 1 suite + 35 fixtures | Fully automated | Yes (in unit suite) |
| Snapshot | 11 test files | Automated capture | Artifact only |
| E2E (simdrive) | Active: `.simdrive/fixtures/flows/` + `.simdrive/journeys/` + `.simdrive/replays/chaos/`; legacy SpecterQA corpus (26/43) archived under `.simdrive/_archive/` | MCP-driven replay (SSIM- + structural-gated) + chaos-replay CI workflow | Manual trigger; chaos-replay runs in CI |
| Security | 3 test files | Fully automated | Yes (in unit suite) |
| Chaos | 2 test files | Fully automated | Yes (in unit suite) |
| Fuzz | 3 test files + 9 corpus | Fully automated | Yes (in unit suite) |
| Performance | 2 test files + scripts | Manual + scripted | No |
| Accessibility | Static analysis + audit | Ledger (non-blocking) | Partial |
| Manual device | Checklist-driven | Not automatable | No |

## Tool Inventory

### Unit Testing
- **Framework**: XCTest (Xcode 26, iOS 16.0+ deployment target)
- **Simulator**: iPhone 16 Pro (iOS 18.4, id: DF4A2A27-9888-429D-A749-2E157A049A37)
- **Mock infrastructure**: 23 shared mocks in `PalaceTests/Mocks/`
- **HTTP hermetic**: `NoNetworkURLProtocol` blocks real network in all unit tests
- **HTTP stubbing**: `HTTPStubURLProtocol` for request/response injection
- **Entry point**: `xcodebuild -project Palace.xcodeproj -scheme Palace test`

### Test Quality Enforcement
- **Linter**: `scripts/lint-test-quality.py` — detects fluff (set-then-assert), shallow (no real logic), missing asserts
- **Mutation testing**: `scripts/palace_mutate.py` — comparison, boolean, boundary, return-value operators; 10 mutants/file default
- **Coverage floors**: `scripts/enforce_coverage_floors.py` + `scripts/coverage-floors.json` — per-module thresholds (46% overall, 30-50% per module)
- **Rule**: Every test must kill at least one mutant. Tautology and coverage-only tests are banned.

### Credibility criterion (applies to ALL tests, including E2E and simdrive replays)

A test counts as a regression test only when it can answer four questions with cited evidence. If any answer is "I didn't check," the result is a smoke test of the *runner*, not a regression test of the *product* — label it accordingly.

1. **Pre-state controlled.** The system was reset to a starting state matching the test's preconditions. For simdrive replays this means the live screen matches the recording's `pre_screenshot` for step 1 (or the journey's documented `preconditions`). A step-1 SSIM <0.85 with `on_drift=warn` means the engine ran the recorded coords against a *different* screen — recorded stable_ids no longer point at the intended elements.
2. **Each step verified.** For every action, observe afterward and confirm the *intended* effect. `executed: true` proves the input event dispatched; it does not prove the right element was hit. Verify with a follow-up observe + invariant check (expected text appeared, screen transitioned, mark count changed in the expected direction).
3. **Post-state asserted.** End with a structural check (`required_text`, `required_chrome` stable_ids, `min_marks`) — not a step count. "Ran 23/23 steps without crashing" is a runner-uptime metric, not a sign-in success. For sign-in: assert "Sign out" button visible. For borrow: assert the book is in My Books. For tab nav: assert the tab indicator moved.
4. **Evidence cited.** Pass-claims must point to the artifact (screenshot path, observed marks list, log line) that supports them. "It worked" without a pointer is a confidence score, not evidence.

For unit/integration tests this criterion is enforced by mutation testing + the test-quality linter. For simdrive E2E tests this criterion is enforced by `structural_checks` blocks in `.simdrive/journeys/*.yaml`; replay-only runs (the MCP `replay` tool against a `recording.yaml`) do not execute those blocks and therefore count as smoke tests until paired with a structural assertion pass.

### E2E sim-driving — simdrive (canonical)
- **Package**: `simdrive` (PyPI, alpha track) — see `~/harness/bin/harness simdrive status`
- **Backend**: real CoreSimulator HID input + vision-first OCR (no XCTest runner, no accessibility-tree dependency)
- **Capabilities**: `observe` (annotated PNG + marks JSON), `tap` / `swipe` / `type_text` / `press_key`, `record_start` / `record_stop` / `replay` (SSIM-gated), `logs` (NSPredicate filter), `session_start` / `session_end`
- **Why this replaces SpecterQA**: Reader2 (Readium 3.x WKWebView), out-of-process auth Safari sheets, OS alerts, and iOS-26 UITextField focus all worked partially or not at all under SpecterQA. simdrive sees pixels, not the AX tree.
- **Tool rules**: see project CLAUDE.md "E2E / UI sim driving — simdrive". Cardinal rules: `observe(annotate=true)` before `tap text=` / `tap mark=`; re-observe after every navigation; pre-grant permissions before `session_start`.
- **Journeys**: new work goes in `.simdrive/journeys/`. Replays in `.simdrive/replays/`.

### SpecterQA E2E Testing — ARCHIVE
- **Status**: Deprecated 2026-04-29. Do not extend. Kept on disk to support reproduction of historical regressions only.
- **Version**: specterqa-ios 7.0.0
- **Corpus**: 26 journey YAMLs + 43 replays in `.simdrive/`
- **Known limitations** (one of the reasons it was retired): `ios_screenshot` exceeds MCP size; `ios_press_key("return")` crashes session; EPUB reader nav controls invisible to XCTest; iOS-26 cliclick path broke text-field focus.

### Contract Testing
- **File**: `PalaceTests/Network/APIContractTests.swift`
- **Fixtures**: 35 JSON/XML files from real Circulation Manager responses
- **Scenarios**: `Fixtures/API/Scenarios/` — happy_path, expired_credentials, server_down, loan_limit, slow_network
- **CM Monitor**: `palace-cm-monitor` MCP checks for API drift weekly

### Security Testing
- `PalaceTests/Security/CredentialPrivacyTests.swift` — credential isolation
- `PalaceTests/Security/DRMAdversarialTests.swift` — DRM edge cases (hermetic)
- `PalaceTests/Security/AuthFlowSecurityTests.swift` — auth flow validation

### Chaos & Fuzz Testing
- `PalaceTests/Chaos/ChaosFaultInjectionTests.swift` + `ChaosHarness.swift`
- `PalaceTests/Fuzz/ParserFuzzTests.swift` + `FuzzRunner.swift` + 9-file corpus (OPDS 1/2, annotations, LCP)

### Performance Testing
- **Device profiling**: `scripts/perf-walker-device.py` — WebDriverAgent on physical iPhone
- **Trace orchestration**: `scripts/run-perf-suite.sh` — Instruments traces
- **Unit benchmarks**: `PalaceTests/Performance/` (2 files)

### Snapshot Testing
- **Framework**: swift-snapshot-testing v1.19.1
- **Files**: 11 snapshot test files in `PalaceTests/Snapshots/`
- **Covers**: BookDetail, AudiobookPlayer, Catalog, MyBooks, Search, Settings, Reservations, Holds, PDF, Facets

### CI Workflows
- `unit-testing.yml` — XCTest + coverage + floor enforcement (blocking)
- `ui-testing.yml` — E2E test runner (manual trigger)
- `ledger.yml` — Ledger + QAAtlas + AccessLint (non-blocking)

## Pre-PR Verification

Anyone can self-check their work before opening a PR:

```bash
scripts/verify-pr.sh --quick    # build + tests + lint + coverage + a11y
scripts/verify-pr.sh            # adds mutation testing on changed files
```

Each check is recorded against the changed files only — pass/fail summary at the end. JSON report optional via `--report /tmp/v.json` for CI consumption.

The mutation pass invokes `python3 scripts/palace_mutate.py` per changed Swift file, looking for ≥50% mutant kill rate (or ≥40% on legacy code with no characterization tests). Critical-path files (sign-in, borrow, download, DRM) require 100% kill rate.

Maintainers additionally run through ForgeOS governance gates that hook into `git commit` / `git push` / `gh pr create` — that pipeline is local-only and outside contributors don't need it.

## Confidence Matrix

| Feature Area | Unit | Integration | E2E | Manual | Confidence |
|-------------|------|-------------|-----|--------|------------|
| Basic auth (barcode/PIN) | High | Medium | Yes (simdrive; SpecterQA-era coverage retained as archive — re-verify under simdrive) | Verified | **High** |
| OAuth/Clever auth | High | Low | Yes (simdrive; SpecterQA-era coverage retained as archive — re-verify under simdrive) | Verified | **Medium** |
| SAML auth | High (29 new tests) | None | Manual only | Pending | **Medium** |
| OIDC auth | High | Low | Yes (simdrive; SpecterQA-era coverage retained as archive — re-verify under simdrive) | Verified | **Medium** |
| Catalog browsing | High | Yes | Yes (simdrive; SpecterQA-era coverage retained as archive — re-verify under simdrive) | Verified | **High** |
| Search | Medium | Yes | Yes (simdrive; SpecterQA-era coverage retained as archive — re-verify under simdrive) | Verified | **High** |
| EPUB reading | Low | None | Partial (reader invisible) | Required | **Low** |
| PDF reading | Low | None | None | Required | **Low** |
| Audiobook playback | Medium | None | Manual only | Required | **Low** |
| Book borrowing | High | Yes | Yes (simdrive; SpecterQA-era coverage retained as archive — re-verify under simdrive) | Verified | **High** |
| Holds/Reservations | Medium | None | Yes (simdrive; SpecterQA-era coverage retained as archive — re-verify under simdrive) | Verified | **Medium** |
| Downloads | Medium | None | Manual only | Required | **Low** |
| DRM (Adobe/LCP) | Low (adversarial only) | None | None | Required | **Very Low** |
| Push notifications | Medium | None | Partial (tooling) | Required | **Low** |
| Account switching | High | Yes | Yes (simdrive; SpecterQA-era coverage retained as archive — re-verify under simdrive) | Verified | **High** |
| Credential isolation | High | Yes | Yes (simdrive; SpecterQA-era coverage retained as archive — re-verify under simdrive) | Verified | **High** |
| CarPlay | Low | None | None | Required | **Very Low** |
| Accessibility (VoiceOver) | Medium | None | simdrive (OCR vs AX-tree diff) — see CLAUDE.md | Required | **Medium** |
| Offline mode | Low | None | Manual only | Required | **Very Low** |

## Known Gaps

### Cannot Automate (Manual Testing Required)
1. **EPUB/PDF rendering** — Readium WKWebView invisible to XCTest accessibility tree
2. **DRM fulfillment** — Adobe RMSDK and LCP require actual license servers
3. **Audiobook playback quality** — Audio output can't be verified programmatically
4. **Background audio** — System interruptions (phone calls, Siri) need device
5. **CarPlay** — Requires CarPlay simulator or physical head unit
6. **Push notification delivery** — APNs requires real device + server

### Can Automate But Not Yet Done
1. **More CI gates beyond `chaos-replay-on-pr.yml`** — `verify-pr.sh --simdrive` is opt-in locally; could extend chaos-replay to also run journey-tier replays from `.simdrive/journeys/`. Legacy SpecterQA's 26 journeys are archived at `.simdrive/_archive/journeys/`, not the path forward.
2. **Snapshot regression gating** — Captures exist but no automated comparison gate
3. **Performance regression gating** — Scripts exist but not CI-integrated
4. **CM contract drift blocking** — Monitor exists but non-blocking

### Partially Covered
1. **SAML E2E** — Unit tested (29 tests) but no E2E through real IdP in CI
2. **Cookie persistence** — Tested in isolation but not across app kill/restart
3. **Multi-library SAML** — Each library has different IdPs; only NYPL fixture tested

## Manual Testing Checklist

Use this for releases and for areas where automation gaps exist:

### Critical Path (every release)
- [ ] Sign in with barcode/PIN (NYPL)
- [ ] Sign in with SAML (A1QA Test Library)
- [ ] Sign in with OAuth (if configured)
- [ ] Borrow EPUB, open, navigate pages, bookmark
- [ ] Borrow audiobook, play, sleep timer, speed control
- [ ] Borrow PDF, open, navigate pages
- [ ] Place hold, verify in Reservations tab
- [ ] Return book from My Books
- [ ] Switch libraries, verify credential isolation
- [ ] Sign out, verify DRM deauthorization

### Reader Experience
- [ ] EPUB: font size, theme switching, night mode
- [ ] EPUB: table of contents navigation
- [ ] PDF: pinch zoom, page scrubber
- [ ] Audiobook: background playback, lock screen controls
- [ ] Audiobook: phone call interruption → resume

### Accessibility
- [ ] VoiceOver: navigate catalog, borrow, read
- [ ] VoiceOver: audiobook controls accessible
- [ ] Dynamic Type: all screens readable at largest size
- [ ] Touch targets: all interactive elements >= 44x44pt

### Edge Cases
- [ ] Airplane mode: offline books accessible, graceful errors for online ops
- [ ] Force quit during download: resumes on next launch
- [ ] Expired loan: removed from My Books, not accessible
- [ ] Expired SAML session: prompted to re-authenticate
- [ ] Multiple accounts: credentials don't leak between libraries

## Process Integration

### Per-change cycle
1. **Plan tests first.** What edge cases, what error paths, what state transitions need to be pinned?
2. **Write the failing test.** TDD — never write production code without a failing test driving it.
3. **Make it pass.** Minimum production code, then refactor both sides.
4. **Verify with `scripts/verify-pr.sh --quick`.** Build, tests, lint, coverage, accessibility — all green before pushing.
5. **For critical-path changes** (sign-in, borrow, download, DRM, payment): also run `scripts/palace_mutate.py` against changed files and confirm 100% kill rate.
6. **Open the PR against `develop`** (never `main`). Hooks enforce additional internal governance for maintainers; outside contributors follow standard GitHub PR flow.

### Every Release
```bash
# Run regression suite (simdrive-driven; legacy SpecterQA paths still wired in scripts/regression-report.sh for archive replay)
scripts/regression-report.sh --baseline <old-tag> --candidate <new-tag>

# Manual testing checklist (above)

# Generate findings report
python3 scripts/generate-regression-report.py --csv findings.csv \
  --screenshots ./screenshots/ --output report/index.html --strict
```

## Related Documents
- [Coverage Roadmap](Coverage_Roadmap.md) — per-module coverage targets
- [Test Patterns](Test_Patterns.md) — mock patterns, stubbing, fixtures
- [Traceability Matrix](Traceability_Matrix.md) — requirements → tests mapping
- [Legacy SpecterQA Regression Plan](../../.simdrive/_archive/REGRESSION_PLAN.md) — archive, kept for reference
- [Active simdrive Gap Analysis](../../.simdrive/journeys/_GAP_ANALYSIS.md) — current coverage gaps + tier breakdown
