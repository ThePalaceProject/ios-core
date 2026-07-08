# Investigator B: Async / Combine Teardown Leakage

## Mode
INVESTIGATION ONLY. No production-code or test-file edits.

## Hypothesis
Tests fire `Task { ... }` or subscribe to Combine publishers in `setUp` /
test body without joining/cancelling in `tearDown`. The unfinished work
mutates state (`@Published`, `AccountStateStore.shared`) AFTER the test
completes, racing the next test's `setUp`. Symptom: a test passes in isolation
but the FOLLOWING test fails non-deterministically with state that "appeared
from nowhere."

## Evidence the category exists
- CI run 26593379677:
  - `TokenRefreshOnForegroundTests.test_ConcurrentForegroundRequests_ProduceOneTokenRefresh`
    failed in **30.353 seconds** — that's a join-on-uncompleted-Task, not a logic failure.
- `feedback_ci_safe_tests.md`: "Never use `Task.sleep`, `waitForDebounce`,
  `Thread.sleep`, or fixed-interval delays. Cold-start contention (Firebase init,
  main-actor saturation) makes timing unpredictable."
- `feedback_wiring_suite_test_isolation.md`: 0.4s `wait(for: [backgroundSettled])`
  is "a weak fence" — sleep-based, not expectation-fulfilled.
- Recon counts: 48 PalaceTests files declare `Set<AnyCancellable>`; 63 files
  use sleep-based waiting (`Task.sleep`, `Thread.sleep`, `usleep`).

## What to look for

### Grep set 1 — Task launched without cancellation handle
```
grep -rn "Task {" PalaceTests/
grep -rn "Task.detached" PalaceTests/
```
Find every test that fires a Task but does NOT capture the handle into a tearDown-
cancellable storage. (Reference shape: a tearDown that explicitly cancels every
spawned Task before super.tearDown returns.)

### Grep set 2 — Cancellables without removeAll
```
grep -rln "Set<AnyCancellable>" PalaceTests/
```
For each file: does `tearDown` call `cancellables.removeAll()` BEFORE
super.tearDown? Files that store cancellables but never clear them leak
subscriptions that fire post-test.

### Grep set 3 — Sleep-based waiting
```
grep -rn "Task.sleep\|Thread.sleep\|usleep\|sleep(" PalaceTests/
```
Every sleep is suspect per feedback_ci_safe_tests. Bucket into:
- Sleep in a test body (HIGH — non-deterministic wait)
- Sleep in a mock to simulate latency (LOW — fine if expectation gates the assert)
- Sleep in `drainMainQueue`-style helpers (MED — polling primitives)

### Grep set 4 — @Published mutated post-tearDown
Find test files where a `@Published` property is mutated inside a Task spawned in
`setUp`. If the Task has no cancellation point and the test runs <100ms, the
mutation fires after `tearDown`. Search shape:
```
grep -rn "Task {" PalaceTests/ | xargs -I{} grep -l "@Published\|publisher" {}
```

### Grep set 5 — Long timeouts (signal of fragility)
```
grep -rn "timeout: *[3-9][0-9]" PalaceTests/  # 30s+ timeouts
```
A 30s timeout in unit tests is a "give up and pass" smell.

## Where to look
- `PalaceTests/Contract/` — already drains Tasks deliberately (see `Reader2PositionResumeContractTests.swift:264` comment "Drain the detached Task"). Good reference patterns.
- `PalaceTests/Audiobooks/NowPlayingCoordinatorTests.swift` — known debounce/Task.sleep boundary
- `PalaceTests/MyBooks/TokenRefresh*` — failing test was here
- `PalaceTests/CatalogUI/CatalogSearchViewModelTests.swift` — `TaskGroup.addTask` calls
- `PalaceTests/Security/DRMAdversarialTests.swift`
- `PalaceTests/Integration/*` — biggest async surfaces
- `PalaceTests/CarPlay/CarPlayAuthHelperReadinessTests.swift`

## Evidence to collect
```
file:line | leak_type (TASK/CANCELLABLE/SLEEP/POST-TEARDOWN-MUTATION) | severity | notes
```
- HIGH = Task spawned with no cancel + mutates singleton or @Published
- MED = Cancellables stored but never drained, OR sleep in a test body
- LOW = Sleep in a mock fixture only

## Proposed fix SHAPE
1. `XCTestCase+drainAllTasks` extension — every tearDown calls
   `await drainAllTasks(timeout: 1.0)` which joins a registered set of test-owned
   Tasks. Tasks register themselves via a captured `addTestTask(_:)` API.
2. A base class `AsyncTestCase` that holds the cancellables Set and clears it
   pre-`super.tearDown` automatically.
3. Lint: `scripts/check-test-task-discipline.py` that fails any test file declaring
   `Set<AnyCancellable>` without a `tearDown`/`tearDownWithError` that calls
   `removeAll()`.
4. Lint: ban `Task.sleep`/`Thread.sleep` in `PalaceTests/**/*.swift` outside an
   approved allowlist (Mocks/ + drainMainQueue helpers).

## NOT in scope
- No production-code changes.
- No test rewrites — only enumeration.
- Do NOT propose adopting structured concurrency — that's a separate architectural
  conversation.

## Output contract
Same shape as Investigator A.
```

---
