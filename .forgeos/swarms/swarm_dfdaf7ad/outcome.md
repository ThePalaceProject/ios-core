---
name: swarm_dfdaf7ad-outcome
type: immutable
status: active
created: 2026-05-19T00:00:00Z
last_refresh: 2026-05-19
freshness_window: never
owners: [general]
description: Outcome — swarm_dfdaf7ad (bundled)
---

# Outcome — swarm_dfdaf7ad (bundled)

**Status:** bundled — single PR to `develop` ready for push
**ForgeOS:** initiative `init_3c329b8c`, changeset `cs_9b82decc`
**Cross-repo:** ios-audiobooktoolkit PR #174 merged, tag `2.2.1` cut, submodule pin advanced to `b408d8e`

## Result summary

| HelpSpot | Module | Tests | Mutation | Status |
|---|---|---|---|---|
| 17865 | AudiobookToolkit (cross-repo) | 9 new (3 toolkit + 6 main) + 19 regression | 66.7% on `NowPlayingCoordinator.swift` ✓ | ✓ bundled |
| 17923 | Settings-AccountDetail | 8 new + 19 regression | warn-only (n/a) | ✓ bundled |
| 17870 | SignInLogic-ErrorPropagation | 15 new + 82 regression | OAuth 50.0% / SAML 100% ✓ | ✓ bundled |

**Totals:** 32 new tests, 120 existing regression tests pass across all touched modules.

## Files changed (in this PR)

### Production code
- `ios-audiobooktoolkit` (submodule pointer → 2.2.1)
- `Palace/Audiobooks/NowPlayingCoordinator.swift` (BG-path debounce bypass + dry-stream guard)
- `Palace/Logging/TPPErrorLogger.swift` (adds `TPPErrorCode.audiobookNowPlayingDry = 403`)
- `Palace/Settings/AccountDetailView.swift` (placeholder UX)
- `Palace/Utilities/Localization/Strings.swift` (`tapToEnter` template)
- `Palace/SignInLogic/TPPSignInBusinessLogic+OAuth.swift` (4 error-synthesis sites + field-swap fix)
- `Palace/SignInLogic/LegacySAMLAuthAdapter.swift` (problemFoundHandler wiring)
- `Palace/SignInLogic/TPPSignInBusinessLogic.swift` (1-line presenter weak-ref wiring; frozen line set verified untouched)

### Tests
- `PalaceTests/Audiobooks/NowPlayingCoordinatorBackgroundTests.swift` (NEW)
- `PalaceTests/Settings/AccountDetailViewAccessibilityTests.swift` (NEW)
- `PalaceTests/Settings/AccountDetailViewPlaceholderSnapshotTests.swift` (NEW)
- `PalaceTests/SignInLogic/LegacySAMLProblemDocumentPropagationTests.swift` (NEW)
- `PalaceTests/SignInLogic/SignInOAuthErrorPropagationTests.swift` (NEW)

### Plumbing
- `Palace.xcodeproj/project.pbxproj` (5 new test files added to PalaceTests target)

### Audit trail
- `.forgeos/swarms/swarm_dfdaf7ad/manifest.yaml`
- `.forgeos/swarms/swarm_dfdaf7ad/outcome.md`
- `.forgeos/swarms/swarm_dfdaf7ad/transcripts/AudiobookToolkit.md`
- `.forgeos/swarms/swarm_dfdaf7ad/transcripts/Settings-AccountDetail.md`
- `.forgeos/swarms/swarm_dfdaf7ad/transcripts/SignInLogic-ErrorPropagation.md`

## Deviations (verified safe)

**SignInLogic-ErrorPropagation:** agent added 1 line to `Palace/SignInLogic/TPPSignInBusinessLogic.swift:101` (`samlPresenter.businessLogic = self`) to wire the Option B weak-ref pattern for the presenter. Integrator verified the diff is a single hunk at `@@ -93,11 +93,15 @@`; frozen line set of `swarm_81b5099e` (281, 309, 732, 736, 753, 781) untouched by content. Line-number shift handled by git 3-way merge when the concurrent swarm lands. Accepted.

## Findings beyond swarm scope (separate tickets recommended)

1. **Palace-noDRM build broken on unmodified `develop`** — missing `AudioEngine` / `TransifexObjCRuntime` modules. Confirmed independently by 2 of 3 implementer agents during build verification. Pre-existing; not caused by this swarm. Worth a separate fix before next release tag cut.
2. **`scripts/palace_mutate.py` doesn't work from worktrees** — hardcoded `REPO_ROOT` assumes main checkout. Module 1 agent patched a workaround at `/tmp/palace_mutate_worktree.py`. Recommend a small tooling PR to thread `--repo-root` (or auto-detect via `git rev-parse --show-toplevel`).
3. **HelpSpot 17498 (Reader2 crash)** — already fixed in 3.1.0 PR #929 (`TPPObjCExceptionCatcher` around `R2LCPClient.createContext`). Crashlytics issue `0ca62d8244e96706c4649b97e20851ff`, 474 events / 47 users. Patron is on 2.2.4/3.0.0 — recommend HelpSpot reply: upgrade to 3.1.0 when available in App Store.

## Cross-repo handoff (DONE)

- Toolkit branch `fix/nowplaying-bg-keepalive-and-bgtask` pushed
- PR #174 opened + merged via `gh pr merge --merge`
- Release `2.2.1` cut against merge commit `b408d8e234836f8c1571f35a06b9475224509ade`
- ios-core submodule pin updated to `b408d8e`
