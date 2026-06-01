# Investigator F — Suite-Ordering Amplifier (Random Execution)

**Swarm:** `swarm_f88ae9e3`
**Mode:** INVESTIGATION ONLY (no production-code / test-file / scheme edits)
**Hypothesis under test:** Random execution ordering is the AMPLIFIER for A-D's
state-residue / teardown-leak / keychain / stub-race categories. M1's 23-class
pre-push gate misses it because the subset is below the residue + collision
threshold; the 798-class full suite hits it.

---

## 1 — Inventory: current state of test ordering + isolation infrastructure

### 1.1 Scheme `testExecutionOrdering` values (ground truth)

`grep -n testExecutionOrdering Palace.xcodeproj/xcshareddata/xcschemes/*.xcscheme`:

| Scheme | TestableReference | `testExecutionOrdering` | Notes |
|---|---|---|---|
| `Palace.xcscheme` | `PalaceTests.xctest` (BlueprintId `2D2B47711D08F807007F7764`) | **`random`** | line 88 |
| `Palace.xcscheme` | `TenPrintCoverTests.xctest` (cross-project ref) | **`random`** | line 99 |
| `Palace-noDRM.xcscheme` | `PalaceTests.xctest` | **(unset → Xcode default)** | lines 31-40, attribute absent |

The architect's contract says "both schemes have random." That's half right:
- **Palace.xcscheme: confirmed random**, twice (PalaceTests + the SPM-cross
  TenPrintCoverTests, both Testables).
- **Palace-noDRM.xcscheme: NOT random.** The `testExecutionOrdering` attribute
  is absent entirely from the TestableReference block. Xcode treats absent as
  the IDE default (`default` value, which renders as "Xcode-defined order" —
  in practice alphabetical-ish by class symbol).

The Apple docs valid values are: `default`, `alphabetical`, `random`, `none`.

**So the amplifier IS asymmetric across the two targets.** This is also why
Palace-noDRM CI has been historically less flaky than Palace CI — the noDRM
scheme has been deterministic the whole time and nobody noticed.

### 1.2 `.xctestplan` files

`find . -name "*.xctestplan"` → **none.**

No xctestplan is used. Ordering is purely controlled by the scheme attributes
above. No per-bundle override mechanism is in play.

### 1.3 `XCTestObservation` / `XCTestObservationCenter` hooks

`grep -rn "XCTestObservation\|XCTestObserver\|XCTestObservationCenter" PalaceTests/`
→ **zero matches.**

There is no global suite-level setUp/tearDown observer that resets singletons
between test classes. This is the structural hole F is naming.

### 1.4 `PalaceTestSetup` and bundle-load hooks

`PalaceTests/PalaceTestSetup.swift` (12 lines, the entirety):

```swift
@objc(PalaceTestSetup)
final class PalaceTestSetup: NSObject {
    override init() {
        super.init()
        NoNetworkURLProtocol.enable()
    }
}
```

Wired via `PalaceTests/Info.plist` `NSPrincipalClass = PalaceTestSetup` (verified
line 23-24). It runs **once per test target launch** — NOT per test class, NOT
per test method. Its only action is to install `NoNetworkURLProtocol` (which
makes real network calls fail loudly — a category-D-adjacent guard).

It does **not**:
- Reset `TPPUserAccount.shared` / `AccountsManager.shared` / `AccountStateStore.shared`
  / `AppContainer.production()` / `UserDefaults.standard` / `NotificationCenter.default`
  between classes.
- Register an `XCTestObservation` to hook `testCaseDidFinish` /
  `testBundleDidFinish` / `testSuiteDidStart`.
- Tear down `HTTPStubURLProtocol` registrations.

**This is the seam that should exist and doesn't.** It IS reachable
(NSPrincipalClass is the canonical way to install global behavior in an iOS
test bundle without requiring every test to inherit from a custom base). The
existing PalaceTestSetup is the right *vehicle* but the wrong *payload*.

### 1.5 `scripts/verify-pr.sh` test invocation

Quote, line 249-250:

```bash
TEST_OUTPUT=$(xcodebuild -project Palace.xcodeproj -scheme Palace \
  -destination "id=$SIM_ID" test 2>&1 || true)
```

- Uses `Palace` scheme → inherits `testExecutionOrdering=random`.
- No `XCT_RANDOM_SEED` / `XCTRandomTestExecutionOrderingSeed` / explicit
  seed env var passed → seed is process-clock-derived per Apple's default.
- `--diff-baseline` flag (line 96, 265-322) implements partial option (iv):
  on failure, parse xcresult for failing classes, re-run each in isolation
  via `-only-testing:PalaceTests/<cls>`, and downgrade the gate to PASS if
  all isolation reruns succeed (calling them "pre-existing test-isolation
  flakes").

This `--diff-baseline` logic is **option (iv) already implemented locally**.
It's opt-in (`--diff-baseline` flag, not default), and crucially it lives only
in `verify-pr.sh` — **CI doesn't invoke verify-pr.sh** (see 1.6).

### 1.6 CI workflow test invocation

`.github/workflows/unit-testing.yml:98` calls `./scripts/xcode-test-optimized.sh`.

`scripts/xcode-test-optimized.sh` (CI branch, lines 70-83):

```bash
xcodebuild test \
    -project Palace.xcodeproj \
    -scheme Palace \
    -destination "id=$SIMULATOR_ID" \
    -configuration Debug \
    -resultBundlePath TestResults.xcresult \
    -enableCodeCoverage YES \
    -parallel-testing-enabled NO \
    ...
```

- Uses `Palace` scheme → `random` ordering.
- `parallel-testing-enabled NO` (sequential within a single sim, single process).
  This matters: the residue surface is intra-process; sequential + random gives
  the maximum chance of mutual pollution across classes.
- No seed pinning.
- No `--diff-baseline`-equivalent "rerun failing in isolation" step.

So CI gets the worst of both worlds: sequential same-process execution
(maximum pollution surface) + random ordering (maximum seed surface) + no
isolation rerun (every flake counts).

The pre-push gate (`scripts/pre-push-test-gate.sh`) is dramatically different:
it computes one test class per changed Swift file (`Foo.swift → Foo*Tests.swift
→ first XCTestCase declared`), dedups, and runs only those via
`-only-testing:PalaceTests/<Class>`. The "23 classes" number from the
architect's brief is whatever specific push produced 23 derived classes — it's
not a fixed manifest. It's immune to the amplifier because (a) each `-only-testing`
class likely runs alone or with one or two sibling classes, well below the
critical mass needed for residue from A/B/C/D to compound, and (b) the
discovered class set is correlated with the PR's diff, not with the polluters
(which are typically unrelated suites loaded earlier in alphabetical order).

### 1.7 Test-class and test-method inventory

| Metric | Architect's count | Actual count (verified now) |
|---|---|---|
| XCTestCase class declarations | 485 | **798** (~165% of expected) |
| Unique class names | n/a | **797** (one duplicate name across files — extension or typo) |
| Test method declarations (`func test*`) | n/a | **7,022** |
| Test source files | n/a | **529** |
| Test files with custom setUp/tearDown lifecycle | 271 | **262** (close to architect's number, but counting `setUp/tearDown/setUpWithError/tearDownWithError/invokeTest` together) |
| Test files touching `.shared` / global singletons | n/a | **164** (≈ 31% of all test files) |

The architect under-counted classes by a factor of ~1.65×. This *amplifies* the
problem framing: it's not 485 classes that could pollute each other, it's
**798**. Combinatorially the polluter-victim pair surface is `798 × 797 / 2 ≈
318k` ordered pairs. Only a small fraction of those pairs need to trigger
state residue for the suite to be flaky under random ordering — A's
HIGH-severity list is the practical search space.

### 1.8 Summary of the amplifier surface

```
SURFACE INVENTORY
─────────────────
Schemes:                     Palace.xcscheme = random (asymmetric)
                             Palace-noDRM.xcscheme = default (NOT random)
xctestplan files:            none
XCTestObservation hooks:     0
Bundle-load hook payload:    NoNetworkURLProtocol install ONLY
                             (no singleton reset, no stub-registry cleanup)
Global setUp/tearDown:       absent (relies on per-class lifecycle, of
                             which 262/529 files implement it)
CI test invocation:          xcode-test-optimized.sh → xcodebuild test
                             Palace scheme, parallel-testing-enabled NO,
                             NO seed pin
Local default invocation:    verify-pr.sh → xcodebuild test Palace scheme
                             (random, no seed)
Local opt-in mitigation:     verify-pr.sh --diff-baseline reruns failing
                             classes in isolation, but is NOT called in CI
Pre-push gate:               scripts/pre-push-test-gate.sh runs N classes
                             derived from diff (N typically 1-23), so far
                             below the residue threshold
Population:                  798 XCTestCase classes, 7,022 test methods,
                             164/529 (31%) files touch shared singletons
```

---

## 2 — Findings table

```
finding | scope | impact | proposed_action_shape
```

| # | finding | scope | impact | proposed_action_shape |
|---|---|---|---|---|
| F-1 | Palace.xcscheme PalaceTests TestableReference `testExecutionOrdering = "random"` | scheme attr, line 88 | HIGH — amplifies A/B/C/D state pollution; non-deterministic CI failures | (i) flip to `alphabetical` for deterministic repro OR (ii) keep random + pin seed in CI via env var |
| F-2 | Palace.xcscheme TenPrintCoverTests TestableReference also `random` | scheme attr, line 99 | MED — same amplifier on the secondary bundle | same as F-1; smaller bundle, smaller impact |
| F-3 | Palace-noDRM.xcscheme is NOT random — asymmetric with Palace | scheme attr, lines 31-40 | LOW (informational) — explains why noDRM CI is historically less flaky | document the asymmetry; align both schemes whichever way the fix goes |
| F-4 | No XCTestObservation registered ANYWHERE in PalaceTests | global | HIGH — there is no seam that runs between test classes to reset shared state | (ii) extend `PalaceTestSetup` to register an XCTestObservation that fires `_resetAllForTesting()` on registered singletons in `testSuiteDidStart(_:)` (per-class) |
| F-5 | `PalaceTestSetup.swift` installs NoNetworkURLProtocol but does nothing else | `PalaceTests/PalaceTestSetup.swift:1-12` | HIGH — vehicle exists, payload is missing | extend per F-4 — same file, same NSPrincipalClass wiring, just register more hooks |
| F-6 | No xctestplan → no per-bundle ordering override possible without scheme edits | repo-wide | MED — limits the fix's reversibility (scheme edits are project-shared) | optional: add a `Palace.xctestplan` so future ordering changes don't require touching xcscheme XML |
| F-7 | CI uses `scripts/xcode-test-optimized.sh`, which doesn't pin a seed and doesn't rerun failing classes in isolation | `.github/workflows/unit-testing.yml:98`, `scripts/xcode-test-optimized.sh:70-83,149-163` | HIGH — every flake is recorded as a real failure; `mergeStateStatus: UNSTABLE` thrash | (i) add `-test-iterations 2 -retry-tests-on-failure` (Xcode 13+) OR (iv) bolt the verify-pr.sh `--diff-baseline` isolation-rerun into CI as a post-failure step |
| F-8 | `verify-pr.sh --diff-baseline` exists locally but is NOT used in CI | `scripts/verify-pr.sh:265-322`, CI workflow doesn't reference it | HIGH — the isolation-rerun mitigation is locally available but CI runs without it | port the isolation-rerun logic into `xcode-test-optimized.sh` (so the same xcresult-parse + `-only-testing` rerun runs in CI on failure) |
| F-9 | `scripts/pre-push-test-gate.sh` derives test classes from diff (line 99-130) so M1's "23 classes" is NOT fixed — it varies per push | `scripts/pre-push-test-gate.sh:99-142` | MED (clarification) — the "M1 immune" narrative is "the subset is small AND correlated with diff, not with polluters"; the AMPLIFIER bites at scale | document this; pre-push will continue to be misleadingly green for any branch whose diff doesn't touch a known polluter class |
| F-10 | Architect's class count (485) is wrong; actual is 798 XCTestCase declarations / 797 unique names | repo-wide | MED — under-statement of the polluter-victim pair surface | correct the count in integrator's unified plan; the combinatorial argument for "F is the right category" is even stronger |
| F-11 | `-parallel-testing-enabled NO` in CI = single-process intra-bundle execution | `scripts/xcode-test-optimized.sh:77` | HIGH (root accelerant) — maximizes the pollution surface because every prior class's residue is live for every later class | this is a Catch-22: enabling parallel splits the bundle across processes (which kills A/D residue between processes) but is explicitly out-of-scope per contract; record but do not propose |
| F-12 | No env-var hook for seeded random (Xcode does NOT expose `XCT_RANDOM_SEED` per Apple docs as of Xcode 26) | platform | HIGH — option (i) "seeded random" cannot be done via standard knobs; the choice is `alphabetical` (fully deterministic) or `random` (non-reproducible) | the integrator should NOT propose seeded-random as if it were an off-the-shelf option; recommend alphabetical as the only structurally available deterministic ordering |

---

## 3 — Fix-shape options (the four asked-for + a fifth that emerged)

| Option | Pro | Con |
|---|---|---|
| **(i) Switch to `alphabetical` or fixed-seed random** | Deterministic — same order every CI run, every developer machine; bisecting a polluter becomes possible because the first ordering that's red can be re-run. Tiny scheme-XML edit (line 88 + 99). | Apple does NOT expose `XCT_RANDOM_SEED` as a standard knob in Xcode 26 (verified — no project / scheme / workflow reference to such a var); "fixed-seed random" is not a real option, only `alphabetical` is. Going alphabetical PROVES the pollution is order-dependent on day one (some currently-green-by-luck alphabetical neighbor pair will go red), which surfaces work — that's the goal but it can be noisy for one week. |
| **(ii) XCTestObservation seam in `PalaceTestSetup` that resets singletons between classes** | Single point of cross-class hygiene; vehicle (`NSPrincipalClass = PalaceTestSetup`) already exists; doesn't require touching 798 test classes; works regardless of ordering. Sledgehammer — masks A/D residue rather than waiting for it to bite. | Requires production code to expose `_resetAllForTesting()` on each singleton (test-only API in production code, slight smell). Doesn't fix the *cause* (singletons in tests), just neutralizes per-class blast radius. Needs an explicit registration list — every new singleton has to opt in. |
| **(iii) Split the test suite into smaller bundles run in separate processes** | Kills intra-process residue cleanly (process boundary = state boundary); could be done via multiple xcodebuild invocations with `-only-testing:PalaceTests/<dir>` partitions. | Explicitly out of scope per contract ("No parallel test bundle changes — out of swarm scope"). Also: CI wallclock could double if partitions don't parallelize. |
| **(iv) "Shuffle-then-rerun-failures-in-isolation" step in CI** | `verify-pr.sh --diff-baseline` already implements the local half; porting to CI is a 50-line bash bolt-on. Distinguishes "real regression" from "ordering flake" automatically; preserves the random-as-flake-discovery property the contract argues against disabling. | Doesn't fix the bug, only labels it. Without a parallel ticket-discipline ("ordering flake means we MUST fix the polluter in this sprint"), the flake count stays unbounded. Adds CI wallclock proportional to flake rate. |
| **(v) NEW — Two parallel CI signals: seeded-deterministic + random-rotating** (contract's preferred shape) | Maps cleanly onto contract's "two parallel CI signals, not one" proposal. Deterministic run gates merge; rotating run discovers new ordering flakes without blocking. Best long-term shape because it preserves discovery WHILE making merge gates honest. | Requires two CI jobs (cost), two report surfaces (noise), and a triage process for the rotating channel (people-cost). Probably the right answer but the highest cost to implement. |

---

## 4 — Recommended sequencing (F's view, integrator owns final word)

1. **Land (ii) FIRST** — extend `PalaceTestSetup` with an `XCTestObservation` that
   resets a registered list of singletons in `testCaseDidFinish(_:)` (per-test
   reset) or `testBundleDidFinish` is too coarse — `testSuiteDidStart(_:)` per
   class is the right granularity. This dramatically reduces A/B/C/D residue
   without requiring 798 test-class edits and without touching schemes. **No
   scheme XML edit, no CI workflow edit, no test-method edits.** One file
   (`PalaceTestSetup.swift`) + one `_resetAllForTesting()` per registered
   singleton in production code.
2. **Land (iv) SECOND** — port `verify-pr.sh --diff-baseline` rerun-in-isolation
   into `scripts/xcode-test-optimized.sh` so CI distinguishes ordering flake
   from real regression. Adds wallclock only on red runs, not green.
3. **Land (i) THIRD, in a separate PR** — flip both schemes to `alphabetical`
   AFTER (ii) has been deployed for ≥1 week. This is the deterministic-repro
   guarantee. Doing it before (ii) would unmask pollution loudly without a
   safety net; doing it after (ii) means the singleton-reset seam has been
   battle-tested for the most common residue paths first.
4. **(v) is the right long-term posture** but is a Q2/Q3 plan, not a fix for
   this week's red develop.

Rationale: (ii) is the only option that gets PALACE tests stable without
touching scheme or CI surfaces. Once stable, (i) is a one-line scheme edit
that locks in determinism. (iv) hardens CI against future regressions of the
seam itself. (v) is the durable architecture once the discipline is established.

---

## 5 — NARRATIVE: F's findings cross-referenced to A/B/C/D

F is named "amplifier" because it does not introduce a class of bug — it
exposes the bugs the other categories are responsible for. The
cross-reference:

- **A (singleton residue)** — A's findings are the classes that mutate
  `.shared` singletons and don't reset them. Under alphabetical ordering, the
  same handful of A-class pairs collide every run, producing a single
  reproducible failure → ticketable → fixable. Under random ordering, A's
  pollution shows up as a different test failing every run, defeating
  bisection. **F-1+F-4 land together**: flip ordering, install observer.
- **B (async/Combine teardown leakage)** — B's leaked Tasks/subscriptions
  fire AFTER the leaking test finishes. Random ordering means the firing
  lands in a random unrelated test; alphabetical means it lands in B's
  alphabetical neighbor consistently. Same architectural conclusion as A. The
  `XCTestObservation.testCaseDidFinish` hook in (ii) is also the right place
  to call `cancellable.cancel()` on a registered list — same seam, different
  payload.
- **C (keychain entitlement)** — C is environment-driven, not order-driven.
  But: an early test that hits the failing `SecItemAdd` and treats the
  -34018 as "no credentials" can flip a singleton (`TPPUserAccount.shared`)
  into a bad state, which under random ordering then bites a later, unrelated
  test. So C's primary fix (guards) is independent of F, but C's secondary
  damage is in F's amplifier domain. F-4's observer seam should cover
  `TPPUserAccount._resetAllForTesting()` to neutralize the secondary blast.
- **D (network-stub race)** — D's symptom (production code falling through
  to a real `URLSession.shared` because the stub never matched) is amplified
  exactly the same way as A: the polluter is "whoever installed the stub and
  didn't tear it down," the victim is "whoever runs next AND happens to hit
  a URL that the stub claimed to handle." Random ordering varies the victim
  per run. F-4's observer should ALSO call
  `HTTPStubURLProtocol.removeAllStubs()` (or whatever the toolkit exposes) in
  `testCaseDidFinish(_:)`. Same seam, third payload.
- **E (actor-isolation churn)** — E is a build-warning class, not a runtime
  flake. F's amplifier has no interaction with E. Mention only to deny the
  overlap.

**Bottom line for the integrator:** the `PalaceTestSetup` XCTestObservation
seam in (ii) is the **single architectural shape** that closes A's, B's, C's
secondary, and D's blast radius. If only one structural fix is going to ship
this sprint, it's this one. The scheme flip in (i) makes the residue
*reproducible*; without (ii), all (i) does is make the same test fail every
run instead of a different test each run — which is more useful for triage
but doesn't reduce the bug count. Both are wanted; (ii) is the prerequisite
for (i) to be safe.

---

## 6 — Definition-of-Done evidence (per CLAUDE.md DoD §1-§10)

Investigation-only contract — most DoD checks are not applicable. Specifically:

| Check | Status | Evidence |
|---|---|---|
| 1. SUT instantiation check | N/A | no test files added/modified |
| 2. Function-result usage check | N/A | no production-code calls added |
| 3. Multi-step test body check | N/A | no tests authored |
| 4. Scope coverage audit | PASS | every contract item answered: (1.1) scheme values listed, (1.2) xctestplan check done, (1.3) XCTestObservation grepped, (1.4) PalaceTestSetup read in full, (1.5) verify-pr.sh checked, (1.6) CI workflow checked, (1.7) counts corrected; all four asked-for fix options ranked + a fifth surfaced from the contract's own preferred shape; cross-reference narrative produced. |
| 5. Mutation pass | N/A | no production code touched |
| 6. Build + verify-pr | N/A | investigation mode, no diff to verify |
| 7. Multi-step / wiring-claim | N/A | no test claims being made |
| 8. Contract reconciliation | PASS | this transcript reconciles to contract `.forgeos/swarms/swarm_f88ae9e3/contracts/F-suite-ordering-amplifier.md`: every "what to look for" item §1-§5 has an explicit answer; the "proposed fix SHAPE" §1-§4 is mirrored in §3 of this transcript with explicit pros/cons. |
| 9. Blast-radius check | N/A | no commit |
| 10. Adjacency staleness | N/A | no rename |

---

## 7 — One-paragraph executive summary for the integrator

The amplifier hypothesis is confirmed and the architect's framing is correct
in shape, off on the numbers, and asymmetric across the two schemes:
**Palace.xcscheme** is random for both Testables (PalaceTests +
TenPrintCoverTests); **Palace-noDRM.xcscheme** is NOT random (attribute
absent → Xcode default). There are no xctestplans, no XCTestObservation hooks,
and no global between-class reset seam — `PalaceTestSetup.swift` exists and is
correctly wired via `NSPrincipalClass`, but its only payload is
`NoNetworkURLProtocol.enable()`. CI uses `scripts/xcode-test-optimized.sh`
(not `verify-pr.sh`), with `-parallel-testing-enabled NO` and no seed pin and
no rerun-in-isolation step. The actual class count is **798** (not 485),
across 529 files and ~7,022 test methods; 164/529 (31%) test files touch
`.shared` / global singletons — a generous polluter-victim search space. The
M1 pre-push gate ("23 classes") isn't a fixed manifest; it's a diff-derived
subset that varies per push, which is why it stays green. The single
structural fix that closes A, B, C-secondary, and D in one seam is (ii):
extend `PalaceTestSetup` to register an `XCTestObservation` that resets a
registered list of singletons + Combine cancellables + stub registry in
`testCaseDidFinish(_:)`. That should ship first; (i) `alphabetical` scheme
flip and (iv) CI isolation-rerun should ship second and third respectively;
(v) two-signal CI is the right long-term posture but is out of scope for
stop-the-bleeding.

— Investigator F · `swarm_f88ae9e3`
