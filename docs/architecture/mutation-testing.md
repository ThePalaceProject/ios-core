---
name: mutation-testing
type: evolving
status: active
created: 2026-06-08
last_refresh: 2026-06-08
freshness_window: 365d
owners: [general]
description: First-principles rationale for the Palace iOS mutation-testing system (palace_mutate.py and friends)
---

<!-- audit-verified -->
<!--
  Factual claims in this doc were verified against ground truth before landing:
  - Cost figures ($0.08/min, 90-120 min, $7-10/push) and the AudiobookLoader
    9->6 mutant / 0%->100% example are quoted verbatim from CLAUDE.md.
  - Every code-behavior claim (operators, DEFAULT_FAST_FLAGS, -quiet rejection,
    CRITICAL_PATH_REGEX, CONSEQUENTIAL_OPS, compute_exit_code ordering, the two
    caches, tests_for_lines->None, covered_lines->None degradation, the
    file-level-not-mutant-level masking constraint, the cost gate) was read
    directly out of scripts/palace_mutate.py, scripts/mutate_coverage.py, and
    scripts/palace_mutate_parallel.py in this session.
  - The "introduced by"/"introduced ... (1978/1993)" phrasings are academic
    attributions (DeMillo-Lipton-Sayward; Untch-Offutt-Harrold), not causality
    claims about a code regression.
  - "100% coverage / 0% protection" is an illustrative argument about tautology
    tests, not a measured percentage-delta on this codebase.
-->

# Mutation testing — first-principles rationale

This document explains *why* the Palace iOS mutation-testing system is built the
way it is. It is the design rationale behind `scripts/palace_mutate.py`,
`scripts/mutate_coverage.py`, `scripts/palace_mutate_parallel.py`, and their
integration into `scripts/verify-pr.sh`.

The short version: mutation testing is the only test-quality metric we have that
**cannot be gamed by assertion-free tests** — but a naive implementation is so
slow it never runs, and a tool that never runs has zero value. Every lever in
this system exists to drive *cost down* (or *signal up*) without changing the
core guarantee. The rest of this doc is the chain of reasoning from the theory
to each lever.

---

## 1. Why mutation testing at all

Line coverage answers "did a test *execute* this line?" It does not answer the
question we actually care about: "would a test *fail* if this line were wrong?"
A test that runs a line but asserts nothing about its effect contributes full
coverage and zero protection. The Palace `CLAUDE.md` test-quality rules exist
precisely because coverage-chasing produced tautology tests
(`XCTAssertNotNil(Singleton.shared)`, `vm.x = 5; XCTAssertEqual(vm.x, 5)`) that
inflate the number while catching nothing.

Mutation testing closes that gap directly. The procedure:

1. Take a production file that has passing tests.
2. Introduce a small, behavior-changing defect (a **mutant**) — flip `>` to
   `>=`, `&&` to `||`, `return true` to `return false`, negate an `if`.
3. Re-run the tests.
4. If a test now **fails**, the mutant is **killed** — the test suite detects
   that class of bug. If all tests still **pass**, the mutant **survived** — a
   real defect of that shape would ship undetected.

The **kill rate** (killed / mutants-actually-run) is a direct measure of test
*effectiveness*, not test *presence*. A tautology test cannot kill mutants,
because nothing it asserts depends on the mutated behavior. This is why
`CLAUDE.md` makes "every test must survive the mutation question" the bar for
critical paths, and why this tool is wired into `/regression` and the pre-release
self-check.

### The theory

Mutation testing was introduced by **DeMillo, Lipton & Sayward (1978)** ("Hints
on Test Data Selection: Help for the Practicing Programmer", *IEEE Computer*).
Two hypotheses justify why testing against *tiny* injected faults generalizes to
real bugs:

- **The Competent Programmer Hypothesis.** Programmers write code that is
  *nearly* correct — real bugs are small deviations from a correct program, not
  arbitrary wrong programs. So the space of mutants (small syntactic deltas)
  models the space of real defects well.
- **The Coupling Effect.** Test data that distinguishes a program from all its
  *simple* (single-token) mutants will also, with high probability, distinguish
  it from *complex* (multi-fault) errors. Empirically validated since (Offutt
  et al.): a suite that kills simple mutants tends to catch compound bugs too.

Together: a small, cheap-to-generate set of single-operator mutants is a
*sufficient* proxy for "would this suite catch a real bug here?" That is the
whole foundation. Everything below is engineering to make the proxy affordable.

### The mutation operators we use

`palace_mutate.py` discovers mutation points by regex (see `_MUTATORS`), in six
operator categories:

| Op       | Mutation                                              |
|----------|------------------------------------------------------|
| `cmp`    | `==`↔`!=`, `>=`→`<=`/`>`, `<=`→`>=`/`<`              |
| `bool`   | `&&`↔`\|\|`                                          |
| `bound`  | `<`→`<=`, `>`→`>=`, `<=`→`<`, `>=`→`>` (off-by-one)  |
| `retval` | `return true`↔`return false` (inside Bool funcs)     |
| `cond`   | `if x` → `if !x` (top-level conditional negation)    |
| `assign` | `+= 1`↔`-= 1`                                         |

These target the decision logic where bugs hide and tests most often go shallow.
`palace_mutate.py` deliberately **skips** mutation points inside logging calls
(`Log.{trace,debug,info,warn,error}`, `print`, `NSLog`, `os_log`, `Logger`) —
flipping a string interpolation inside a log line changes no observable behavior,
so such a "survivor" deflates the kill rate while saying nothing about test
quality. (Per `CLAUDE.md`: AudiobookLoader.swift went from 9 discovered mutants /
0% kill rate to 6 real mutants / 100% after this skip rule landed.)

---

## 2. The cost model — why naive mutation testing never runs

The total cost of a mutation run is, to first order:

```
cost  ≈  (number of mutants)  ×  (cost per mutant run)
```

For an iOS app, **cost per mutant run is brutal**: each mutant requires an
`xcodebuild test` invocation — a compile + link + boot-sim + run cycle measured
in minutes, not milliseconds. The reference Swift mutation tester (Muter) makes
this worse two ways: it copies the *entire* project to a sibling directory (which
breaks on Palace's submodules and signing certs) and it runs the **full** test
suite per mutant. On a real PR that is hours of walltime. `CLAUDE.md` records the
empirical number: a cold first-touch PR with 16+ changed files is **90–120 min /
$7–10 per push** on macOS GitHub-hosted runners ($0.08/min). That is why
mutation testing was **removed from CI** (the `mutation-on-pr.yml` /
`mutation-gate.yml` workflows) and made a **local-only, pre-release** gate.

A tool that costs that much per push gets disabled, and a disabled tool provides
no signal — the same failure mode `CLAUDE.md`'s green-board contract warns about.

So the entire system is organized around the two factors of the cost product.
There are exactly two ways to make it cheaper:

- **Shrink the numerator** — run *fewer* mutants (coverage-gating, diff-default,
  equivalent-mutant suppression).
- **Shrink the per-run cost** — make each `xcodebuild` cycle cheaper or skip it
  entirely (Tier-1 flags, per-mutant cache, test-selection), or do several
  *files* at once (the parallel pool).

And one way to make the same cost buy *more signal*:

- **Spend the budget where a bug hurts most** (the critical-path metric).

Each lever maps to one of those. The guiding invariant: **no lever may change
the killed/survived verdict of a mutant that actually runs.** Cost levers may
only decide *whether* a mutant runs or *how fast*; they may never flip a
SURVIVED to a KILLED.

---

## 3. The levers

### 3.1 Coverage-gating — don't mutate dead lines

*(`mutate_coverage.covered_lines`, integrated in `palace_mutate.main`)*

A mutant on a line **no test executes** is a *guaranteed* survivor: if no test
runs the code, nothing can fail, so the mutant always survives. Running it costs
a full `xcodebuild` cycle to learn nothing, **and** it deflates the kill rate
with a "survivor" that reflects missing coverage, not a weak assertion.

So the baseline test run is done **with coverage on** (into a temp `.xcresult`
bundle), and `covered_lines()` parses which lines were actually executed. Any
mutation point on an unexecuted line is recorded `uncovered` and **never run**.
`uncovered` mutants are tracked in their own counter and surfaced as a
`coverage_gap` in the report — they are an honest "you have no test here" signal,
not a kill-rate penalty. Kill rate is computed over **run** mutants only, so
coverage gaps neither inflate nor deflate it.

This is pure win: fewer `xcodebuild` cycles **and** a more honest metric.

### 3.2 Per-line test selection — run only the tests that touch the line

*(`mutate_coverage.tests_for_lines`, integrated in `palace_mutate.main`)*

In principle, a mutant only needs to be graded against tests that actually
execute its line; running the whole class is wasted compile/run time. The
interface for this exists (`tests_for_lines` returns `line -> [selectors]`, and
`main` narrows `selected_tests` per mutant when a mapping is present).

**Honest limitation, deliberately shipped as a no-op.** `tests_for_lines`
currently returns `None`. Xcode 26's coverage archive aggregates execution counts
across the *entire* test run; it does not segment counts per individual test, and
there is no stable, documented `xcresulttool` form that yields per-test *line*
coverage. The only way to get true per-test attribution would be to run each test
in isolation with coverage on and diff the archives — which is exactly the
expensive thing this tool exists to avoid.

Returning a *wrong* map would be actively harmful: the caller would narrow to a
subset that does **not** exercise the mutated line, grade the mutant SURVIVED
against tests that could never kill it, and silently lie about coverage.
Returning `None` is the honest, safe signal — "attribution unavailable, run the
full class" — which is exactly today's behavior. The signature is kept stable so
a future Xcode (or an isolation-based implementation behind a flag) can fill it
in without touching the caller. This is the one lever that is wired but
intentionally dormant, because shipping it wrong would violate the
core invariant (it could flip a real SURVIVED to a false KILLED).

### 3.3 Tier-1 flags — shave per-build waste off every `xcodebuild`

*(`DEFAULT_FAST_FLAGS` in `palace_mutate.py`)*

Each mutant run is a targeted `xcodebuild test`. Several per-invocation steps are
pure waste *inside a mutation loop*, because the tree's package state is already
resolved and pinned and the run is inherently serial (one narrow class):

| Flag                                          | Why it's safe here                        |
|-----------------------------------------------|-------------------------------------------|
| `-disableAutomaticPackageResolution`          | SPM graph is already resolved; don't re-resolve every run |
| `-onlyUsePackageVersionsFromResolvedFile`     | trust `Package.resolved` verbatim         |
| `-skipPackagePluginValidation`                | skip plugin fingerprint prompts           |
| `-parallel-testing-enabled NO`                | we run ONE narrow class — parallelism overhead, not gain |
| `COMPILER_INDEX_STORE_ENABLE=NO`              | mutation loop needs no index store writes |

**Deliberately NOT added: `-quiet`.** `any_tests_ran()` greps the
`Executed N tests` summary lines to distinguish "0 tests ran" (a
misconfiguration → ERROR) from a real pass/fail. `-quiet` suppresses those lines,
which would make every mutant grade as a 0-tests-ran ERROR. This is a concrete
example of the core invariant: a speed flag that would corrupt the verdict is
rejected even though it would be faster.

### 3.4 Diff-default — mutate only what this PR changed

*(`changed_lines` + `--diff-only`, default for the PR gate in `verify-pr.sh`)*

A file with pre-existing low-coverage areas shouldn't punish a PR that didn't
touch them, and re-mutating unchanged code on every push is pure cost. So
`palace_mutate.py` supports `--diff-only` (with `--diff-base`, default
`origin/develop`): restrict mutation points to lines this branch changed,
discovered via `git diff --unified=0`. The PR gate in `verify-pr.sh` runs
**diff-scoped by default**; `--mutation-whole-file` flips it for release runs
that want full-file coverage.

Result: the reported kill rate reflects **your diff's** test quality, not the
file's historical coverage — fewer mutants per push, and a fairer metric.
Graceful degradation applies here too: if `git diff` fails (unknown base ref), it
falls back to a whole-file scan rather than crashing.

### 3.5 Critical-path metric — spend the budget where bugs hurt

*(`CRITICAL_PATH_REGEX` + `CONSEQUENTIAL_OPS` + `compute_exit_code`)*

`CLAUDE.md`'s risk-driven rigor bar says a 30-LOC change to a return flow gets
the same rigor as a 500-LOC refactor, because the *consequences* of a bug are the
same. Mutation gating mirrors that: a **surviving consequential mutant on a
critical-path file fails the gate regardless of kill rate.** A kill rate that
looks perfect on paper cannot mask a single surviving auth/borrow/return/
download/DRM/audiobook/migration mutant.

- `CRITICAL_PATH_REGEX` matches the same roots as the `CLAUDE.md` critical-path
  list (`Palace/Audiobooks/`, `SignInLogic/`, `MyBooks/Download|Borrow|
  BookReturn`, `Migrations/`, `Network/TPPNetworkResponder|Executor`,
  `Packages/PalaceAuth/`).
- `CONSEQUENTIAL_OPS` = `{cmp, bool, bound, retval, cond}`. An `assign` flip
  (`+= 1`→`-= 1`) surviving is far less alarming than a flipped auth comparison,
  so `assign` is intentionally excluded from the override.
- `compute_exit_code` returns `1` if `is_critical_path` and
  `critical_path_survivors > 0`, **before** the `<50%` kill-rate check — so the
  critical-path override is independent of the kill-rate floor.

`verify-pr.sh` reinforces this: critical paths are **strict by default** (kill
rate below `--mutation-min-kill-rate`, default 50, fails the gate), non-critical
changed files are advisory (low rates surface as warnings). `--enforce-mutations`
promotes every changed file to strict.

### 3.6 Per-mutant cache — never re-run an unchanged mutant

*(`compute_mutant_key` + `mutant_cache_*`, alongside the whole-file cache)*

There are two caches, by design:

- **Whole-file cache** (`.forgeos/mutation-cache/<leaf>.<key>.json`): keyed by
  file SHA + test selection + seed + max-mutations + diff flags. If the exact
  file content + selection was already run, the whole report is reused
  instantly (the verbatim summary line `verify-pr.sh` greps for is preserved in
  the cached branch). All-or-nothing: any edit invalidates the whole report.

- **Per-mutant incremental cache**
  (`.forgeos/mutation-cache/mutants/<leaf>.json`): finer-grained. The mutant key
  (`compute_mutant_key`) is *content-addressed by local context* — the stripped
  line text, its immediate neighbours (`context_before`/`context_after`), and the
  operator delta — **not** by line number. So editing one function does not
  invalidate untouched mutants elsewhere in the file (only moved/changed mutants
  re-run), and two byte-identical lines in different surroundings are
  disambiguated. The map is persisted **atomically** (tmp + rename) after every
  mutant, so a CI-timeout-killed run leaves a consistent cache for the next run.

Both caches honor `--no-cache`. The report itself is also written atomically
after every mutation (`_write_report_atomic`) with a `partial` flag, so an
externally-killed run never leaves a half-written report — the symptom that once
made a CI comment say "no data."

### 3.7 Parallel pool — fan out by FILE, never by mutant

*(`palace_mutate_parallel.py`)*

`palace_mutate.py` mutates one file serially. On a multi-file PR the per-file
cold-build cost dominates, so `palace_mutate_parallel.py` fans **files** out
across a small worker pool — each worker owns one git worktree + one pool
simulator + one private `DerivedData` path — so several files mutate concurrently
while `DerivedData` stays warm *within* each file.

**The masking problem — why file-level, never mutant-level.** It is tempting to
batch several mutants into one build to amortize compile cost. *This is forbidden,
and the constraint is the single most important design decision in the parallel
layer.* If you apply mutant A and mutant B to the tree and run the tests once, a
single failure cannot tell you *which* mutant caused it. If A is killed (its
mutation breaks a test) but B survives, the batch's tests fail, the whole batch
grades as KILLED, and **B's survival is invisible** — a killed mutant masks a
surviving one, and the survivor is exactly the test hole you were hunting. So
each `palace_mutate.py` invocation owns exactly **one file** and reverts between
mutants as it does today. Parallelism comes from **isolation** (running several
single-file mutation processes side by side in separate worktrees), never from
**batching** (combining mutants into one build).

**Isolation per worker** is what makes concurrency safe:
- a dedicated **git worktree** so concurrent in-place mutate+revert edits never
  collide (the worktree setup replicates the swarm Phase 0 Palace recipe —
  Carthage/Build *copied* not symlinked, `ios-audiobooktoolkit` a real submodule
  clone, the other submodules + adobe-rmsdk symlinked, gitignored secrets
  copied);
- a dedicated **pool sim UDID** (round-robin via `assign_sims`) so two
  `xcodebuild` runs don't fight over one booted device;
- a dedicated **`PALACE_MUTATE_DERIVED_DATA_PATH`** so build databases don't
  corrupt each other.

**The cost gate** (`should_run_parallel`): parallel only pays off with **≥2
files AND ≥2 workers**. Otherwise the worktree + cold-build setup is pure
overhead, so a small PR runs **serially in the main tree** — no worktree, no cold
build. The decision is always logged, never silent. Worker count
(`compute_worker_count`) is `min(#sims, max(1, ncpu//4), #files)` by default:
each `xcodebuild` is itself massively parallel, so ~1 worker per 4 logical cores
is the empirical sweet spot, and we never spawn more workers than files (idle
sim claims) or sims (workers would serialize on a shared device).

Aggregation (`aggregate_reports`) sums per-file outcomes, computes the overall
kill rate over **run** mutants only (mirroring the single-file rule), and fails
overall if **any** file failed its own gate — which already encodes both the
`<50%` rule and the critical-path override.

### 3.8 Equivalent-mutant suppression — silence a once-reviewed non-bug

*(`mutate_coverage.load_suppressions` / `is_suppressed`)*

Some surviving mutants are **provably equivalent** to the original program — e.g.
a `>` vs `>=` on a loop bound that can never hit the boundary value. No test can
ever kill them because they change no observable behavior. Re-flagging them every
run is noise. A human can review one once and add it to a per-file suppression
list at
`.forgeos/mutation-suppressions/<file-leaf>.json`, a JSON list of
`{"line_text", "original", "mutated", "reason"}` entries. A suppressed mutant is
recorded `suppressed`, never run, and never counted as survived/killed.

Matching is whitespace-insensitive on the line text (so a re-indent doesn't
silently un-suppress a reviewed equivalent), but exact on the operator tokens. A
missing or malformed suppressions file suppresses **nothing** and never crashes a
run — same graceful-degradation discipline as everywhere else. This lever is
human-gated by construction: it can only ever *remove* noise a person has
explicitly signed off on.

---

## 4. The graceful-degradation safety property

The thread running through every lever is one safety property:

> **If a cost optimization cannot do its job, the tool falls back to the
> previous (correct, if slower) behavior — it never crashes and never corrupts a
> verdict.**

Concretely:

- `mutate_coverage.py` is an **optional import**. If it's absent (fresh checkout
  before it lands, partial sync), `_COVERAGE_AVAILABLE` is `False` and every
  call site is skipped — `palace_mutate.py` mutates every line exactly as it did
  before coverage-gating existed.
- `covered_lines()` returns `None` on **any** failure (bundle missing, parse
  error, unsupported Xcode, xccov timeout, file not in archive). `None` means
  "coverage unknown" → the caller **does not gate** → mutate every line. The
  coverage-parse functions are pure (operate on captured text) and return `None`
  on malformed/empty/unexpected JSON.
- `tests_for_lines()` returns `None` → run the full class (today's behavior).
- `changed_lines()` (`--diff-only`) falls back to a whole-file scan if `git diff`
  fails.
- `load_suppressions()` returns `[]` on a missing/broken file → suppress nothing.
- The whole-file and per-mutant caches honor `--no-cache` and write atomically;
  a killed run leaves consistent state.
- The Tier-1 flags are chosen so none of them can corrupt the
  "Executed N tests" detection (`-quiet` is rejected for exactly this reason).

This is what makes the whole system **low-risk to adopt**: the worst case of any
optimization failing is that the tool gets *slower*, never *wrong*. A coverage
extraction that breaks under a future Xcode does not silently pass a PR with no
mutation data — it falls back to mutating everything, which is the conservative
direction.

---

## 5. Future work: mutant schemata

The cost product is `#mutants × cost-per-run`, and the levers above attack
`#mutants` (coverage-gating, diff-default, suppression) and per-run overhead
(Tier-1 flags, caches, file-level parallelism). The one factor we have **not**
fundamentally attacked is the dominant term: **a full Swift compile per mutant.**

The known research answer is **mutant schemata** (Untch, Offutt & Harrold, 1993):
instead of compiling N separate mutated programs, compile **one** metaprogram
that contains *all* mutation points behind runtime switches, then select which
mutant is "live" per test run via a variable — turning N compiles into one
compile + N cheap runs. This is the real fix for "the build is the bottleneck."

It is **hard in Swift** because the conditions that make schemata easy in
dynamically-typed or JIT-compiled languages are absent: Swift is statically typed
and whole-module-optimized, mutation points span types (a `Bool` retval flip vs an
`Int` comparison flip) so a single uniform switch type doesn't fit, and injecting
a runtime selector without changing type-checking or triggering different
optimizer behavior is delicate. A faithful schema would likely need to operate at
the SIL level or via a source-level transform that is provably
type-and-behavior-neutral except at the selected point. Until that exists, the
per-mutant compile stays the bottleneck and the levers above are how we keep the
tool affordable enough to actually run.

---

## 6. Decision log

| Decision | Rationale |
|---|---|
| Mutation testing is **local-only / pre-release**, removed from CI | 90–120 min / $7–10 per push on macOS runners; a per-push gate trains everyone to ignore CI. Pay it once locally before tag-cut (`/regression`, `verify-pr.sh --enforce-mutations`). |
| **Fewer mutants** before **cheaper runs** | Cost is a product; killing a mutant entirely (coverage-gate, diff-default, suppress) beats running it faster. |
| Coverage-gating **on by default**, opt-out via `--no-coverage-gate` | Uncovered lines are guaranteed survivors; running them wastes builds and deflates the metric. Default to the honest, cheap behavior. |
| Per-line test selection **wired but dormant** (`tests_for_lines` → `None`) | Xcode 26 has no stable per-test line coverage. A wrong map would flip real SURVIVED to false KILLED — worse than not having it. Return `None` (run full class) until Xcode exposes it. |
| Reject `-quiet` from the Tier-1 flag set | It suppresses the "Executed N tests" lines `any_tests_ran()` greps, turning every mutant into a 0-tests ERROR. A speed flag that corrupts the verdict is not worth it. |
| Diff-scoped **by default** for the PR gate; whole-file for release | Kill rate should reflect *this PR's* coverage, not the file's history; full-file is the release-time check. |
| Critical-path survivor **fails the gate regardless of kill rate** | Risk-driven rigor: a surviving consequential auth/borrow/DRM/audiobook mutant is a real hole even at a perfect on-paper kill rate. |
| `assign` excluded from `CONSEQUENTIAL_OPS` | A `+= 1`→`-= 1` survivor is far less alarming than a flipped auth comparison; the critical-path override is for decision logic. |
| **Two** caches: whole-file (all-or-nothing, fast path) + per-mutant (context-addressed, fine-grained) | Whole-file gives instant reuse on unchanged content; per-mutant means editing one function doesn't re-run untouched mutants elsewhere. |
| Per-mutant key is **content/context-addressed**, not line-numbered | A reformat or unrelated edit shifts line numbers but not behavior; keying on stripped line + neighbours + operator delta keeps cache hits valid and disambiguates identical lines. |
| Parallel fan-out is **file-level, never mutant-level** | Batching mutants into one build lets a killed mutant mask a surviving one — the survivor is exactly the hole we're hunting. Concurrency comes from isolation, not batching. |
| Parallel **cost gate**: serial unless ≥2 files AND ≥2 workers | Worktree + cold-build setup is pure overhead for a small PR; never make a small PR slower. Decision is logged, never silent. |
| Every optimization **degrades gracefully** to the prior behavior | Worst case of any lever failing is *slower*, never *wrong* — the property that makes the system safe to adopt and safe under future Xcode changes. |
| Skip mutation points inside log/print/os_log lines | Flipping a log-string interpolation changes no observable behavior; counting it as a survivor deflates the kill rate for nothing. |

---

## Related docs

- [`critical-path-mutation-coverage.md`](./critical-path-mutation-coverage.md) — which critical-path files are mutation-gated vs contract-snapshot-covered, and the exemption rationale.
- [`superpartner-spectrum.md`](./superpartner-spectrum.md) — the "is there a test at all?" floor; mutation testing is the "does the test catch bugs?" proof above it.
- `CLAUDE.md` → "Mutation testing", "TDD & Test Quality", "Definition of Done" check #5 — the policy that consumes this tooling.
