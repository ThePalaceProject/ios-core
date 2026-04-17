# Palace iOS — Testing Posture

Last updated: 2026-04-16

## Testing Pyramid

```
                    ┌─────────┐
                    │ Manual  │  Device testing, SAML IdP flows,
                    │ Device  │  audiobook playback, DRM fulfillment
                    ├─────────┤
                 ┌──┤ E2E     │  SpecterQA journeys (26 flows),
                 │  │ (Specter│  replays (43), accessibility audit
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
| E2E (SpecterQA) | 26 journeys / 43 replays | MCP-driven replay | Manual trigger |
| Security | 3 test files | Fully automated | Yes (in unit suite) |
| Chaos | 2 test files | Fully automated | Yes (in unit suite) |
| Fuzz | 3 test files + 9 corpus | Fully automated | Yes (in unit suite) |
| Performance | 2 test files + scripts | Manual + scripted | No |
| Accessibility | Static analysis + audit | Ledger (non-blocking) | Partial |
| Manual device | Checklist-driven | Not automatable | No |

## Tool Inventory

### Unit Testing
- **Framework**: XCTest (Xcode 16.1+, iOS 16.0+ deployment target)
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

### SpecterQA E2E Testing
- **Version**: specterqa-ios 7.0.0
- **Simulator**: iPhone 12 (iOS 26, id: 31CF5C43-DD55-4889-B3B2-9A6810B4E98F)
- **Journeys**: 26 YAML scenarios in `.specterqa/journeys/`
- **Replays**: 43 recorded sessions in `.specterqa/replays/`
- **Capabilities**: Screenshot (via elements), tap, swipe, type, wait, accessibility audit, dark/light mode, console logs, crash detection, network monitoring, performance baselines
- **Limitations**: `ios_screenshot` exceeds MCP size (use `ios_elements`); `ios_press_key("return")` crashes session; EPUB reader nav controls invisible to XCTest

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

## Governance Pipeline

Every code change follows this pipeline (enforced by hooks):

```
forge_init ─→ forge_propose_changeset ─→ evidence collection ─→ gate promotion ─→ PR
                                              │
                    ┌─────────────────────────┴───────────────────────────┐
                    │ unit_test: XCTest pass/fail counts                  │
                    │ lint: build errors + test-quality violations         │
                    │ coverage: line coverage % vs floors                  │
                    │ mutation: kill rate on changed files (threshold 50%) │
                    │ a11y_audit: accessibility annotations on UI files    │
                    └─────────────────────────────────────────────────────┘
```

**Enforcement hooks** (`.claude/settings.json`):
- `git commit` blocked without ForgeOS changeset
- `git push` blocked without passing gates
- `gh pr create` blocked without passing gates

**Evidence collection**: `scripts/forgeos-session.sh evidence <cs_id>` runs the full battery automatically.

**Pre-PR verification**: `scripts/verify-pr.sh` runs build + tests + lint + coverage + mutation + a11y and produces a JSON report.

## Confidence Matrix

| Feature Area | Unit | Integration | E2E | Manual | Confidence |
|-------------|------|-------------|-----|--------|------------|
| Basic auth (barcode/PIN) | High | Medium | Yes (SpecterQA) | Verified | **High** |
| OAuth/Clever auth | High | Low | Yes (SpecterQA) | Verified | **Medium** |
| SAML auth | High (29 new tests) | None | Manual only | Pending | **Medium** |
| OIDC auth | High | Low | Yes (SpecterQA) | Verified | **Medium** |
| Catalog browsing | High | Yes | Yes (SpecterQA) | Verified | **High** |
| Search | Medium | Yes | Yes (SpecterQA) | Verified | **High** |
| EPUB reading | Low | None | Partial (reader invisible) | Required | **Low** |
| PDF reading | Low | None | None | Required | **Low** |
| Audiobook playback | Medium | None | Manual only | Required | **Low** |
| Book borrowing | High | Yes | Yes (SpecterQA) | Verified | **High** |
| Holds/Reservations | Medium | None | Yes (SpecterQA) | Verified | **Medium** |
| Downloads | Medium | None | Manual only | Required | **Low** |
| DRM (Adobe/LCP) | Low (adversarial only) | None | None | Required | **Very Low** |
| Push notifications | Medium | None | Partial (tooling) | Required | **Low** |
| Account switching | High | Yes | Yes (SpecterQA) | Verified | **High** |
| Credential isolation | High | Yes | Yes (SpecterQA) | Verified | **High** |
| CarPlay | Low | None | None | Required | **Very Low** |
| Accessibility (VoiceOver) | Medium | None | SpecterQA audit | Required | **Medium** |
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
1. **SpecterQA in CI** — 26 journeys exist but not wired into GitHub Actions
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

### Every Session
```bash
# 1. Init governance
forge_init  # project: proj_87884c17

# 2. Propose changeset BEFORE coding (read required evidence)
forge_propose_changeset  # with planned files + modules

# 3. Implement with TDD (tests first, then production code)

# 4. Collect evidence
scripts/forgeos-session.sh evidence <changeset_id>
# Collects: unit_test, lint, coverage, mutation, a11y

# 5. Promote gates
scripts/forgeos-session.sh promote <changeset_id>

# 6. Verify
scripts/verify-pr.sh --report /tmp/verify.json

# 7. Release check
forge_release_check  # must return can_release: true

# 8. Create PR (hooks enforce governance)
gh pr create --base develop
```

### Every Release
```bash
# Run SpecterQA regression suite
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
- [SpecterQA Regression Plan](../../.specterqa/REGRESSION_PLAN.md) — E2E journey execution order
- [SpecterQA Gap Analysis](../../.specterqa/journeys/_GAP_ANALYSIS.md) — what's automatable vs manual
