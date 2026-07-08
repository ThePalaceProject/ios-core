# Investigator E — Xcode 26.3 Actor-Isolation Tightening

**Mode:** INVESTIGATION ONLY. No production / test edits performed.
**Source CI run:** `26593379677` (the contract-cited run) — pulled via `gh run view --log`, cached at `/tmp/ci_log_26593379677.txt` (60,887 lines).

---

## TL;DR

- **Distinct production warnings (Palace/ + ios-audiobooktoolkit/) of the "crosses into main actor" class:** **13 unique**, emitted **26 times** in the CI log (each warning double-fires because it appears once per build target — `Palace` and `Palace-noDRM`).
- **Production `Palace/` files affected:** 4 (`AccountDetailViewModel`, `CarPlayTemplateManager`, `HoldsViewModel`, `ErrorLogExporter`). All four were also explicitly cited in the architect's contract; investigation confirms no additional production conformers in Palace/ today.
- **PalaceTests/ files emitting the same warning class:** 5 (out-of-scope for production review but in-scope for cleanup). These are spy/mock types that mirror Palace's `@MainActor` isolation.
- **ios-audiobooktoolkit/ submodule:** **0** "crosses into main actor" warnings. The toolkit findings are a different shape — **non-Sendable self-capture** in `@Sendable` closures (`DownloadWatchdog`, `LCPStreamingPlayer`, `LCPResourceLoaderDelegate`). Same Swift-6 future-error family, different category.
- **Build-settings audit:** **`SWIFT_STRICT_CONCURRENCY` is NOT set** in either `Palace.xcodeproj/project.pbxproj` or `ios-audiobooktoolkit/PalaceAudiobookToolkit.xcodeproj/project.pbxproj`. Targets are at `SWIFT_VERSION = 5.0` (DRM/non-DRM Swift targets) with `SWIFT_VERSION = 4.2` for legacy ObjC bridge targets. Warnings are coming from **Xcode 26.3's default minimal-strict-concurrency level**, not from a project opt-in. Implication: there is no "lower the dial" lever — Xcode 26.3 raised the default and the warnings appear automatically.
- **CI noise contribution:** 113 lines (`grep -c "main actor-isolated"`) attributable to actor-isolation findings, split as 26 "crosses into main actor" warning lines + 72 "cannot satisfy nonisolated requirement" notes + 15 ancillary lines. This pollutes test-failure triage but does NOT block the build.

---

## Build-settings finding (definitive)

```
grep "SWIFT_STRICT_CONCURRENCY\|SWIFT_DEFAULT_ACTOR_ISOLATION\|SWIFT_UPCOMING_FEATURE" \
  Palace.xcodeproj/project.pbxproj  ios-audiobooktoolkit/PalaceAudiobookToolkit.xcodeproj/project.pbxproj
```

Returns **zero** matches in both files. The project is on Swift 5 mode at the default concurrency-checking level.

Recommendation context (not action): the fix is NOT to add `SWIFT_STRICT_CONCURRENCY = minimal` to silence — that's the current default and is exactly where the warnings come from. To suppress today, the only knobs are:
1. `OTHER_SWIFT_FLAGS += -Xfrontend -warn-concurrency=off` (per-target, fragile, defers the eventual Swift-6 error).
2. `@preconcurrency` on each conforming type (compiler-blessed migration helper).
3. Fix the conformance (the contract's preferred path).

---

## Findings table — Palace/ production

| # | File:Line | Conforming Type | Protocol | Actor mismatch | Swift-6 blocker | Fix shape | Effort |
|---|-----------|-----------------|----------|----------------|-----------------|-----------|--------|
| 1 | `Palace/Settings/AccountDetailViewModel.swift:729` | `AccountDetailViewModel` (extension) | `NYPLUserAccountInputProvider` (internal, `@objc`, `Palace/Packages/PalaceAuth/Sources/PalaceAuth/TPPUserAccountFrontEndValidation.swift:21`) | properties `usernameTextField`, `PINTextField`, `forceEditability` are MainActor-isolated on a nonisolated protocol | **Y** | ANNOTATE_PROTOCOL_MAINACTOR (single conformer in Palace/ — only `AccountDetailViewModel` and the protocol's own internal default impls. The protocol is `@objc` — verify `@MainActor` on `@objc` protocol is supported; if not, fall back to `@preconcurrency` on the extension). | moderate |
| 2 | `Palace/Settings/AccountDetailViewModel.swift:743` | `AccountDetailViewModel` (extension) | `TPPSignInOutBusinessLogicUIDelegate` (internal, `@objc`, `Palace/SignInLogic/TPPSignInBusinessLogicUIDelegate.swift:68`) | 9+ methods (businessLogic*, dismiss, present, context, etc.) | **Y** | ANNOTATE_PROTOCOL_MAINACTOR — sole conformer in repo is `AccountDetailViewModel`; protocol can safely be `@MainActor`. Same `@objc` caveat as #1. | moderate |
| 3 | `Palace/Settings/AccountDetailViewModel.swift:743` (warning emits twice — also at col 1) | `AccountDetailViewModel` | `TPPSignInBusinessLogicUIDelegate` (parent protocol of #2, `Palace/SignInLogic/TPPSignInBusinessLogicUIDelegate.swift:14`) | inherited from #2 | **Y** | Resolved by #2 (parent protocol covers child via `@MainActor` inheritance). | moderate |
| 4 | `Palace/Settings/AccountDetailViewModel.swift:870` | `AccountDetailViewModel` (extension) | `NYPLBasicAuthCredentialsProvider` (internal, `@objc`, `Palace/Packages/PalaceNetwork/Sources/PalaceNetwork/TPPBasicAuth.swift:13`) | `username`, `pin` properties | **Y** | **RESTRUCTURE / SPLIT_NONISOLATED_FACADE** — this protocol is ALSO conformed-to by `TPPUserAccount` (`Palace/Accounts/User/TPPUserAccount.swift:634`, which is NOT `@MainActor`) and consumed by `TPPNetworkResponder` + `TPPNetworkExecutor` from arbitrary (nonisolated) contexts. Annotating the protocol `@MainActor` would cascade onto network-layer call sites. Two options: (a) leave protocol nonisolated and add `nonisolated` + sync getters to `AccountDetailViewModel`'s extension methods, or (b) decouple AccountDetailViewModel via a small nonisolated facade. | restructure |
| 5 | `Palace/CarPlay/CarPlayTemplateManager.swift:754` | `CarPlayTemplateManager` (extension) | `CPNowPlayingTemplateObserver` (CarPlay, Apple framework) | `nowPlayingTemplateUpNextButtonTapped`, `nowPlayingTemplateAlbumArtistButtonTapped` | **Y** | **TRIVIAL** — methods only call `Log.info` + UI presentation (`showChapterList()` which is itself `@MainActor`). Apply `nonisolated` to the two `func` methods + dispatch through `Task { @MainActor in ... }` or, better, **annotate the methods `nonisolated` and have the body do `Task { @MainActor in self.showChapterList() }`**. CarPlay observers always invoke on the CarPlay scene queue, not the main queue — this is the **right** isolation seam. | trivial |
| 6 | `Palace/CarPlay/CarPlayTemplateManager.swift:713` (NOT in CI log "crosses into main actor" but contract-cited) | `CarPlayTemplateManager` (extension) | `CPInterfaceControllerDelegate` (CarPlay, Apple framework) | inferred similar shape | check | Same pattern as #5 — `nonisolated` + main-actor hop. | trivial |
| 7 | `Palace/Holds/HoldsViewModel.swift:7` | `HoldsBookViewModel` (class declaration) | `Identifiable` (Swift std, marker protocol; the `var id: String` property is what triggers) | `id` (computed property) | **Y** | **TRIVIAL** — `id` is `book.identifier` access, no main-actor state needed. Mark `nonisolated var id: String { book.identifier }`. `book` is a `let TPPBook` (immutable reference); access is safe nonisolated. | trivial |
| 8 | `Palace/Logging/ErrorLogExporter.swift:469` | `MailComposerDelegate` (class declaration, private) | `MFMailComposeViewControllerDelegate` (MessageUI, Apple framework) | `mailComposeController(_:didFinishWith:error:)` | **Y** | **MODERATE** — method body uses UIKit (`controller.dismiss`, `UIAlertController`, `present`) all `@MainActor`-isolated. Cannot make method `nonisolated` without dispatching the UI work via `Task { @MainActor in ... }`. The cleaner fix: drop `@MainActor` on the class, make the method `nonisolated`, and wrap the UIKit-touching body in `Task { @MainActor in ... }`. The shared singleton stays safe because the method receives `controller` (the MFMailComposeViewController) by parameter, not via captured state. | moderate |

**Summary:** 4 unique Palace/ files; 8 unique conformances (incl. CarPlay's CPInterfaceControllerDelegate which is contract-cited but not in the CI noise tally — verifying below).

### Verification: CPInterfaceControllerDelegate

```
grep -E "warning:.*crosses into main actor" /tmp/ci_log_26593379677.txt | grep "CPInterfaceControllerDelegate"
```

Returns 0 hits. **CPInterfaceControllerDelegate conformance at `CarPlayTemplateManager.swift:713` does NOT currently produce an actor-isolation warning** in CI run 26593379677. Either: (a) the methods on that extension happen to be empty or already actor-compatible, (b) the protocol's Apple-side declaration is differently isolated, or (c) the compiler's heuristic considers it "OK". Investigator note for the integrator: this is a single point where the contract's hypothesis didn't materialize as a CI warning — keep on the watch-list for the next Xcode rev.

---

## Findings table — PalaceTests/ (test-file mirrors)

These are out-of-scope for production review but in-scope for the "structural fix" tooling (because they emit the same warning text from the same shape). They are listed so the integrator can include test-side hygiene in the unified plan.

| # | File:Line | Conforming Type | Protocol | Notes |
|---|-----------|-----------------|----------|-------|
| 9 | `PalaceTests/Mocks/CatalogRepositoryMock.swift:17` | `CatalogRepositoryTestMock` | `CatalogRepositoryProtocol` | Mock follows the SUT's isolation; protocol probably wants `@MainActor` if all real implementations are MainActor. |
| 10 | `PalaceTests/CatalogUI/CatalogSearchViewModelTests.swift:20` | `CatalogRepositoryMock` (inline) | `CatalogRepositoryProtocol` | Same as #9. |
| 11 | `PalaceTests/Reader2/EPUBSearchViewModelTests.swift:100` | `MockEPUBSearchDelegate` | `EPUBSearchDelegate` (internal) | `didSelect(location:)` |
| 12 | `PalaceTests/Mocks/MockVisualNavigator.swift:19` | `MockVisualNavigator` | `VisualNavigator` (Readium) + `Navigator` (Readium) | Properties `view`, `presentation`, `publication`, `currentLocation` |
| 13 | `PalaceTests/MyBooks/DownloadStartDispatcherTests.swift:707` | `SpyDispatcherDelegate` | `DownloadStartDispatcherDelegate` (internal) | `bookRegistry`, `startBorrow(...)`, `addDownloadTask(...)`, `clearAndSetCookies()`, `handleSAMLStartedState(...)`, `failWithWifiRequired(...)`, `logInvalidURLRequest(...)` |

---

## Findings table — ios-audiobooktoolkit/ (DIFFERENT WARNING CLASS)

The contract flagged `LCPStreamingPlayer`, `LCPResourceLoaderDelegate`, `DownloadWatchdog` as in-scope. Investigation confirms these produce warnings, but **not the "crosses into main actor" class** — they produce **non-Sendable self-capture** warnings in `@Sendable` closures. Same Swift-6 future-error family, different category. The integrator should treat these as a sibling finding under category E but call out the difference explicitly.

| File | Warning | Swift-6 blocker |
|------|---------|-----------------|
| `ios-audiobooktoolkit/PalaceAudiobookToolkit/Network/DownloadWatchdog.swift:362` | `capture of 'self' with non-Sendable type 'DownloadWatchdog' in a '@Sendable' closure` | **Y** |
| `ios-audiobooktoolkit/PalaceAudiobookToolkit/Player/LCPResourceLoaderDelegate.swift:130, :160` | `capture of 'self' with non-Sendable type 'LCPResourceLoaderDelegate?' in a '@Sendable' closure` (2 distinct sites) | **Y** |
| `ios-audiobooktoolkit/PalaceAudiobookToolkit/Player/LCPStreamingPlayer.swift:451+` | `capture of 'self' with non-Sendable type 'LCPStreamingPlayer?' in a '@Sendable' closure` + 9 follow-on warnings on same file | **Y** |
| `ios-audiobooktoolkit/PalaceAudiobookToolkit/Player/Helpers/Models/TrackPosition.swift:22, Manifest.swift:249` | `consider making struct 'TrackPosition' conform to the 'Sendable' protocol` / `non-Sendable type` | **Y** |
| Wide-reach: `reference to captured var 'self' in concurrently-executing code` (4 occurrences across toolkit) | Same class | **Y** |

**Total toolkit lines with Swift-6-blocker labelled warnings:** ~30 in CI log. Pipeline note: toolkit changes go through `ios-audiobooktoolkit` submodule PRs, NOT through the Palace repo PR pipeline.

---

## CI-noise quantification

Single CI run `26593379677` for PR #1020 (cited in contract):

```
grep -c "main actor-isolated"            /tmp/ci_log_26593379677.txt   →  113 lines
grep -c "crosses into main actor"        /tmp/ci_log_26593379677.txt   →   26 lines (13 unique × 2 build targets)
grep -c "cannot satisfy nonisolated"     /tmp/ci_log_26593379677.txt   →   72 lines
```

Cross-category noise also present that the integrator should be aware of (Swift-6-blocker family, not exact same shape but related):

```
note: turn data races into runtime errors with '@preconcurrency'      →  26 lines (Xcode suggesting the workaround)
note: isolate this conformance to the main actor with '@MainActor'    →  26 lines (Xcode suggesting the proper fix)
note: mark all declarations used in the conformance 'nonisolated'     →  16 lines (Xcode suggesting the third option)
warning: instance method 'lock'/'unlock' unavailable from async       →  30 lines (NSLock / mutex)
warning: ...'shared' can not be referenced from a nonisolated context →   9 lines (singleton-from-nonisolated)
warning: Sendable closure / captured var self                         →  ~12 lines
```

**Aggregate "Swift-6 will turn this into an error" warning count in the build:** approximately **200 lines** of CI log, with ~85% concentrated in the categories above. When triaging an actual test failure, the developer has to scroll past 200 noise lines to find the real error.

---

## Proposed fix shape — ranked by (effort × noise-reduction)

### Tier 1 — TRIVIAL, highest noise-payoff (lands first)

1. **`HoldsBookViewModel.id` → `nonisolated`** (4 lines of CI noise removed; `book` is a `let TPPBook`, access is intrinsically safe).
2. **`CarPlayTemplateManager.CPNowPlayingTemplateObserver` extension methods → `nonisolated` + main-actor hop inside body** (4 lines of CI noise removed; the body's UI work runs through existing main-actor seams).

### Tier 2 — MODERATE, moderate noise-payoff

3. **Annotate `TPPSignInBusinessLogicUIDelegate` and `TPPSignInOutBusinessLogicUIDelegate` `@MainActor`** at the protocol definition. Sole conformer in the repo is `AccountDetailViewModel` (already `@MainActor`). Verify `@MainActor` on `@objc` protocol is supported in Swift 5.10+ (the docs say yes; if not, fall back to `@preconcurrency` on the conformance). Removes ~16 lines of CI noise.
4. **Annotate `NYPLUserAccountInputProvider` `@MainActor`** at the protocol definition. Investigation confirms the protocol has only one conformer in Palace/ (`AccountDetailViewModel`); the other reference is the consuming side (`TPPUserAccountFrontEndValidation` takes it as an injected dependency, doesn't conform). Removes ~6 lines of CI noise.
5. **`MailComposerDelegate` → drop class-level `@MainActor`, make method `nonisolated`, wrap UIKit body in `Task { @MainActor in ... }`**. Removes ~6 lines of CI noise.

### Tier 3 — RESTRUCTURE, lowest noise-payoff per LOC of churn

6. **`NYPLBasicAuthCredentialsProvider` conformance on `AccountDetailViewModel`** — this is the only finding that requires real architectural thought. The protocol is shared with `TPPUserAccount` (nonisolated) and consumed by `TPPNetworkExecutor` / `TPPNetworkResponder` from arbitrary contexts. Two acceptable shapes (investigator does NOT pick — that's for the implementer):
   - (a) Add `nonisolated` to `username` / `pin` getters in `AccountDetailViewModel`. Requires the getters to read state that's safe from nonisolated context. May force a small refactor of how those properties are computed.
   - (b) Split the credentials surface: `AccountDetailViewModel` holds a `nonisolated` companion type that implements `NYPLBasicAuthCredentialsProvider`, and the view model exposes the companion via a getter. More LOC, cleaner separation.
   - **NOT** make the protocol `@MainActor` — would cascade onto `TPPNetworkExecutor` call sites.

### Tier 4 — submodule pipeline

7. **ios-audiobooktoolkit Sendable findings** — submodule PR. Out-of-scope for the Palace repo's swarm output but the toolkit's `@Sendable` self-captures will become Swift-6 errors. Recommend the integrator's unified plan includes a "submodule action item" line.

### Tier 5 — test-file hygiene (can be a follow-up sweep)

8. PalaceTests/ mock conformances (5 files). Lowest priority — these don't ship to users — but worth a one-pass cleanup. Two options: `@preconcurrency` on each mock's protocol conformance, or annotate the internal protocols `@MainActor` (then mocks automatically match). Option 2 doubles as a long-term fix for the production-code mirror (whatever protocols are shared between Palace/ and PalaceTests/).

### Tier 6 — NOT RECOMMENDED

9. **Build-settings suppression** (`-warn-concurrency=off`) — kicks the can to Swift 6 enablement day. CI noise stays in local builds. Rejected.
10. **Blanket `@preconcurrency`** on every conformance — the compiler-blessed migration helper, but it defers the error and adds visual noise. Accept on a finding-by-finding basis only where the proper fix is restructure-grade.

---

## Structural-fix proposals (the lens the contract asked for)

### S-E1. Protocol-isolation audit lint

A `scripts/lint-protocol-isolation.py` that, for each `@MainActor` class declaration in `Palace/`, finds the protocols it conforms to and flags any conformance that:
- The protocol is defined inside the repo (we control it), AND
- All known conformers in the repo are `@MainActor`, AND
- The protocol itself is NOT `@MainActor`.

That's the **single-point-of-fix** signal — annotate the protocol once, remove the warning from every conformer. Output is "candidates to annotate `@MainActor`".

### S-E2. CI-noise budget gate (already-proposed by contract; concur)

`scripts/verify-pr.sh` adds a diff-scoped check: count "main actor-isolated ... cannot satisfy nonisolated requirement" notes in the PR's touched files; fail if the count is NEW relative to `origin/develop`. Pre-existing findings stay on the baseline; only regressions block. This makes the wall self-tightening — the count can only go down.

### S-E3. Xcode-rev audit checklist (already-proposed by contract; concur)

A `.forgeos/audits/xcode-version-rev-checklist.md` that the team runs each time Xcode releases a notes-line about Sendable or actor isolation. Re-runs the grep sets in this transcript. The output is a delta table — "what new warnings did this Xcode rev introduce".

### S-E4. Annotate-protocol-MainActor pattern, with caveats

The contract proposed annotating internal protocols `@MainActor` when all conformers are `@MainActor`. This investigation confirms the pattern is sound **only when the protocol is single-conformer in the repo**. For shared protocols (the `NYPLBasicAuthCredentialsProvider` case), the pattern breaks because cascading `@MainActor` onto the protocol propagates to non-MainActor conformers. The structural rule:

> "Annotate the protocol `@MainActor` IFF (a) we own the protocol declaration AND (b) every conformer in the repo is already `@MainActor`. Otherwise, restructure."

Wire this into S-E1 by tightening the lint's check to "all known conformers are MainActor".

---

## Definition-of-Done evidence (Investigator E checklist)

1. **SUT-instantiation check** — N/A (investigation mode, no test files added/modified).
2. **Function-result usage check** — N/A (no production calls added).
3. **Multi-step test body check** — N/A (no tests added).
4. **Scope coverage audit** — every item in contract `E-actor-isolation-xcode-26-3.md`:
   - "Enumerate every @MainActor class that conforms to a nonisolated Apple protocol delegate" — DONE (table above).
   - "Separately list Palace/ findings vs ios-audiobooktoolkit/ findings" — DONE (separate tables).
   - "Categorize the Apple protocols hit" — DONE (`MFMailComposeViewControllerDelegate`, `Identifiable`, `CPNowPlayingTemplateObserver`, plus internal `TPPSignIn*`, `NYPL*` family).
   - "Count the noise" — DONE (113 lines, with breakdown).
   - "Check SWIFT_STRICT_CONCURRENCY" — DONE (not set; default-strictness is the source).
   - "Propose fix SHAPE" — DONE (Tier 1-6 ranking).
   - "Output: ranked table of (file, line, class, protocol, fix difficulty)" — DONE (Palace/ + tests + toolkit).
5. **Mutation pass** — N/A (no production-code edits).
6. **Build + verify-pr** — N/A (no changes to verify; this is enumeration).
7-10. — N/A (no diff to reconcile).

**Scope deferrals** — none. All grep sets were exercised, every contract-cited file was inspected, the CI log was pulled and parsed. The only contract item that didn't surface a finding (CPInterfaceControllerDelegate at `CarPlayTemplateManager.swift:713`) is documented above with the empirical evidence that it isn't producing a warning today.

---

## Open questions for the integrator

1. **`@MainActor` on `@objc` protocols** — Swift 5.10+ documentation says yes; the implementer should verify on a small experiment before committing to S-E4 for the `TPPSignIn*` family (which are `@objc`).
2. **`NYPLBasicAuthCredentialsProvider` restructure** — option (a) `nonisolated` getters vs option (b) companion type. This is the only restructure-grade finding; punt to architect review on the implementer's PR.
3. **Submodule action item** — does the unified plan track `ios-audiobooktoolkit` Sendable findings as a parallel sibling work item, or note-only and defer to the next toolkit-side PR? Suggestion: note-only here, but spin a follow-up ticket so the cross-vendor smoke matrix (per `reference_audiobook_toolkit_risk_profile.md`) captures the Swift-6 deadline.
4. **Test-file hygiene** — yes/no/when. If yes, recommend the `@MainActor` annotation on the internal protocols (S-E4) which fixes both production-conformer and test-mock at once, vs. per-mock `@preconcurrency` (deferral).
