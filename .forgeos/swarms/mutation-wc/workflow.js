export const meta = {
  name: 'mutation-testing-world-class',
  description: 'Build world-class mutation testing for Palace iOS: coverage-gating, test-selection, per-build flags, diff-default, critical-path metric, per-mutant cache, parallel pool, equivalent-mutant suppress-list',
  phases: [
    { title: 'Coverage engine (A)' },
    { title: 'Core engine (C)' },
    { title: 'Parallel + Gate (B, D)' },
    { title: 'Docs + integration gate (E)' },
  ],
}

// ---------------------------------------------------------------------------
// Shared context every implementer needs.
// ---------------------------------------------------------------------------
const REPO = '/Users/mauricework/PalaceProject/ios-core'

const COMMON = `
You are a careful implementer on Palace iOS's CRITICAL quality tooling (mutation
testing). Coherence and correctness matter more than raw speed. This is Python +
bash tooling under scripts/, NOT Swift — ignore xcodebuild/ForgeOS/pbxproj swarm
ceremony.

Repo root: ${REPO}

HARD CONSTRAINTS (all components):
- Every pure-logic addition gets unit tests that DO NOT invoke xcodebuild or boot
  a simulator. Mock subprocess. The xcodebuild path is the slow thing we are
  fixing; tests must run in <5s. Follow the style of scripts/test_palace_mutate.py.
- Read the files you touch IN FULL before editing. Preserve ALL existing careful
  comments in palace_mutate.py and resolve-tests-for.py.
- Do NOT commit, stage, or push. Leave changes in the working tree; the
  orchestrator integrates.
- Python 3, no third-party deps beyond stdlib (no pip installs).
- When you finish, your StructuredOutput IS your report. In 'evidence' paste the
  ACTUAL output of running your unit tests (python3 -m unittest ...), not a claim.
`

// ---------------------------------------------------------------------------
// THE A<->C INTERFACE CONTRACT (orchestrator-pinned; both A and C obey it).
// ---------------------------------------------------------------------------
const INTERFACE_CONTRACT = `
=== PINNED INTERFACE CONTRACT: scripts/mutate_coverage.py (A) <-> palace_mutate.py (C) ===

A creates scripts/mutate_coverage.py exposing EXACTLY these callables. C imports
and calls them. Neither side may change the signatures without the other.

  def covered_lines(xcresult_path, source_relpath, repo_root):
      """Return a set[int] of 1-indexed line numbers in source_relpath that were
      EXECUTED by the tests recorded in the xcresult bundle. Return None on ANY
      failure (bundle missing, parse error, unsupported Xcode version, file not in
      coverage). None means 'coverage unknown' and C MUST fall back to NOT gating
      (i.e. behave exactly as today: mutate every discovered line). This graceful
      degradation is the safety property that makes coverage-gating low-risk."""

  def tests_for_lines(xcresult_path, source_relpath, lines, repo_root):
      """Best-effort per-test attribution for TEST SELECTION. Given a set[int] of
      lines, return dict[int, list[str]] mapping each line to the
      'PalaceTests/<Class>/<method>' selectors whose execution covered it. Return
      None if per-test coverage is unavailable in this xcresult (then C falls back
      to running the whole resolved test class — today's behavior). Partial maps
      are fine: a line absent from the dict means 'unknown, run the full class'."""

  def load_suppressions(repo_root, source_relpath):
      """Load human-curated equivalent-mutant suppressions for this source file.
      Storage: .forgeos/mutation-suppressions/<file-leaf-without-.swift>.json,
      a JSON list of objects: {"line_text": "...", "original": ">=", "mutated": ">",
      "reason": "loop bound is provably equivalent"}. line_text is compared
      STRIPPED of leading/trailing whitespace. Return [] if the file is absent.
      Document the format with a committed example file + a README in that dir."""

  def is_suppressed(suppressions, line_text, original, mutated):
      """True iff (line_text.strip(), original, mutated) matches a suppression
      entry. Pure function, trivially unit-testable without any xcresult."""

C calls these as: from a module import (sys.path already includes scripts/ dir
in palace_mutate.py). C must guard the import so palace_mutate.py still works if
mutate_coverage.py is somehow absent (try/except ImportError -> disable gating).
`

// ---------------------------------------------------------------------------
const IMPL_SCHEMA = {
  type: 'object',
  additionalProperties: false,
  properties: {
    status: { type: 'string', enum: ['READY', 'BLOCKED'] },
    files_changed: { type: 'array', items: { type: 'string' } },
    tests_added: { type: 'array', items: { type: 'string' } },
    interface: { type: 'string', description: 'For A: final public signatures + suppress-list path/format + the exact xccov/xcresulttool command used + whether tests_for_lines is real or returns None. For C: final CLI flags, report-schema additions, per-mutant cache path/format, exit-code semantics.' },
    evidence: { type: 'string', description: 'ACTUAL pasted output of running the new unit tests + any DoD greps.' },
    notes: { type: 'string' },
    blocked_reason: { type: 'string' },
  },
  required: ['status', 'files_changed', 'interface', 'evidence'],
}

const E_SCHEMA = {
  type: 'object',
  additionalProperties: false,
  properties: {
    status: { type: 'string', enum: ['PASS', 'FAIL'] },
    pytest_summary: { type: 'string' },
    bash_n_summary: { type: 'string' },
    docs_written: { type: 'array', items: { type: 'string' } },
    fixes_applied: { type: 'array', items: { type: 'string' } },
    remaining_issues: { type: 'array', items: { type: 'string' } },
  },
  required: ['status', 'pytest_summary', 'bash_n_summary'],
}

// ===========================================================================
// Phase A — coverage engine (no deps)
// ===========================================================================
phase('Coverage engine (A)')
const a = await agent(`${COMMON}

COMPONENT A — Coverage engine. Create scripts/mutate_coverage.py and
scripts/test_mutate_coverage.py.

${INTERFACE_CONTRACT}

Your deliverables:
1. scripts/mutate_coverage.py implementing the four callables above EXACTLY.
   - covered_lines / tests_for_lines: figure out the correct Xcode 26 incantation.
     Try: 'xcrun xccov view --report --json <xcresult>' for file-level, and for
     LINE-level use 'xcrun xccov view --archive --file <abs-source> <xcresult>'
     (the .xcresult contains the coverage archive; if that form fails, probe
     'xcrun xcresulttool' / the .xccovarchive inside DerivedData). You do NOT
     have a real xcresult handy — you cannot fully run this end to end. That is
     OK: design defensively so EVERY failure path returns None, and unit-test the
     PARSING logic by feeding the functions saved/synthetic xccov JSON/text
     fixtures (capture the documented output shapes; commit small fixtures under
     scripts/fixtures/ if helpful). Per-test attribution (tests_for_lines) is
     genuinely hard in Xcode 26 — if you cannot do it reliably from the xcresult,
     implement it to return None (graceful fallback) and document WHY in a
     comment. Returning None is acceptable and expected; a wrong map is not.
   - load_suppressions / is_suppressed: fully implementable + fully testable now.
2. Create .forgeos/mutation-suppressions/README.md documenting the JSON format and
   an example file .forgeos/mutation-suppressions/EXAMPLE.json (a sample, clearly
   marked as an example, that load_suppressions for a real leaf will NOT pick up).
3. scripts/test_mutate_coverage.py: unit tests for is_suppressed (match/no-match,
   whitespace-insensitive line_text), load_suppressions (present/absent/malformed
   -> []), and the coverage PARSER fed synthetic fixtures (covered lines extracted
   correctly; malformed/empty -> None). All tests pure-Python, no xcodebuild.

Run: python3 -m unittest scripts.test_mutate_coverage  (paste real output in evidence).
Report via StructuredOutput. In 'interface' give C the EXACT final signatures and
note whether tests_for_lines is real or stubbed-to-None.`,
  { label: 'A:coverage-engine', phase: 'Coverage engine (A)', schema: IMPL_SCHEMA })

if (!a || a.status === 'BLOCKED') {
  log(`A BLOCKED: ${a ? a.blocked_reason : 'agent returned null'}`)
  return { aborted: 'A failed', a }
}
log(`A READY. interface:\n${a.interface}`)

// ===========================================================================
// Phase C — core engine (depends on A's interface)
// ===========================================================================
phase('Core engine (C)')
const c = await agent(`${COMMON}

COMPONENT C — Core engine. You are the SINGLE OWNER of scripts/palace_mutate.py
and scripts/test_palace_mutate.py. Read both in full first.

Component A has shipped scripts/mutate_coverage.py. Its FINAL interface (obey it):
${a.interface}

${INTERFACE_CONTRACT}

Implement ALL of the following in palace_mutate.py, preserving every existing
comment and the existing behavior/exit-code contract:

1. TIER 1 per-build waste flags in run_targeted_tests(). Add to the xcodebuild
   command: -disableAutomaticPackageResolution -onlyUsePackageVersionsFromResolvedFile
   -skipPackagePluginValidation -parallel-testing-enabled NO, and the build setting
   COMPILER_INDEX_STORE_ENABLE=NO. Do NOT add -quiet (any_tests_ran parses
   'Executed N tests'). Make the whole extra-flag set overridable via env var
   PALACE_MUTATE_XCB_EXTRA_FLAGS (space-split; if set, REPLACES the defaults) and
   suppressible via PALACE_MUTATE_NO_FAST_FLAGS=1. Keep a module-level constant
   listing the defaults so a unit test can assert their presence.

2. COVERAGE-GATING (keystone). The BASELINE run (run before any mutation) should
   additionally pass -enableCodeCoverage YES -resultBundlePath <tmpdir bundle>.
   Add a helper that runs the baseline with coverage and returns the xcresult path.
   Then (unless --no-coverage-gate) call mutate_coverage.covered_lines(...) for
   args.file; intersect with the discovered mutation lines. Mutations on UNCOVERED
   lines are recorded with status 'uncovered' and NEVER run (a guaranteed survivor
   -> free coverage-gap signal). If covered_lines returns None, gating is DISABLED
   and behavior is exactly as today (mutate all lines). Default: gating ON;
   --no-coverage-gate disables. Guard the import with try/except ImportError so
   palace_mutate.py still runs if mutate_coverage.py is absent.

3. TEST SELECTION. Unless --no-test-selection, call tests_for_lines for the
   covered mutation lines. For a mutant whose line has a non-empty selector list,
   run ONLY those '-only-testing:Class/method' selectors instead of the full
   args.tests. Fall back to args.tests when the map is None or lacks that line.

4. PER-MUTANT INCREMENTAL CACHE (in addition to the existing whole-file cache —
   keep that as the fast path / check it first). New layer at
   .forgeos/mutation-cache/mutants/<leaf>.json: a JSON object mapping
   mutant_key -> {status, elapsed_sec, stored_at}. mutant_key = sha256 over
   (CACHE_VERSION, sorted(tests), context_before + '\\n' + line_text + '\\n' +
   context_after, original, mutated)[:16], where context_before/after are the
   stripped text of the immediately preceding/following source lines (so the key
   survives edits ELSEWHERE in the file but disambiguates two identical lines in
   different locations). Compute context at discovery time (store on the Mutation
   dataclass). On a run (unless --no-cache): for each planned mutant look up the
   per-mutant cache; reuse cached status; only execute misses; persist updates
   atomically. Add a tiny pure function compute_mutant_key(...) that is unit-tested
   for stability (same inputs -> same key) and disambiguation (same line_text,
   different context -> different key).

5. CRITICAL-PATH METRIC. Add a module-level CRITICAL_PATH_REGEX matching
   Palace/Audiobooks/, Palace/SignInLogic/, Palace/MyBooks/Download, Palace/MyBooks/Borrow,
   Palace/MyBooks/BookReturn, Palace/Migrations/, Palace/Network/TPPNetworkResponder,
   Palace/Network/TPPNetworkExecutor, Palace/Packages/PalaceAuth/. Add to the report
   summary: is_critical_path (bool, does args.file match), and
   critical_path_survivors (count of SURVIVED mutants whose op is consequential —
   cmp/bool/bound/retval/cond; exclude assign). When is_critical_path and
   critical_path_survivors > 0, the process exit code is 1 (gate fail) REGARDLESS
   of kill rate. PRESERVE the existing exit contract otherwise: 0 ok, 1 low-kill
   (<50%), 2 error. PRESERVE the printed summary line containing
   'killed: N  survived: N  errored: N  kill rate: P%' verbatim (verify-pr.sh
   greps it). Also keep emitting that line in the CACHED branch.

6. SUPPRESS-LIST. Load mutate_coverage.load_suppressions for args.file once.
   Mutants matching is_suppressed are recorded status 'suppressed' and NOT run and
   NOT counted as survived/killed.

7. Report schema additions (BACKWARD COMPATIBLE — only ADD keys). summary gains:
   uncovered, suppressed, is_critical_path, critical_path_survivors. Add a
   top-level 'coverage_gap' list of {line, op} for uncovered mutation points.
   Existing keys (killed/survived/errored/kill_rate_pct/partial/...) UNCHANGED.

8. Extend scripts/test_palace_mutate.py: keep all existing tests passing; add
   tests for compute_mutant_key (stability + disambiguation), the critical-path
   classification + critical_path_survivors counting (build a fake report dict),
   the Tier-1 default-flags constant presence, and the suppress/uncovered status
   accounting. NONE may invoke xcodebuild — test the pure functions; refactor
   small pure helpers OUT of the xcodebuild-calling code if needed to make them
   testable.

Run: python3 -m unittest scripts.test_palace_mutate  (paste real output).
Report via StructuredOutput; in 'interface' give B and D the FINAL CLI flags, the
report-schema additions, the per-mutant cache path/format, and the exact
exit-code semantics.`,
  { label: 'C:core-engine', phase: 'Core engine (C)', schema: IMPL_SCHEMA })

if (!c || c.status === 'BLOCKED') {
  log(`C BLOCKED: ${c ? c.blocked_reason : 'agent returned null'}`)
  return { aborted: 'C failed', a, c }
}
log(`C READY. interface:\n${c.interface}`)

// ===========================================================================
// Phase B + D — parallel orchestrator and gate wiring (both depend on C, disjoint files)
// ===========================================================================
phase('Parallel + Gate (B, D)')
const [b, d] = await parallel([
  () => agent(`${COMMON}

COMPONENT B — Parallel worker-pool orchestrator. Create
scripts/palace_mutate_parallel.py and scripts/test_palace_mutate_parallel.py.

It shells out to the improved palace_mutate.py. Its FINAL interface:
${c.interface}

Design:
- CLI: --files F [F ...] OR --changed (compute changed prod Swift vs --base,
  default origin/develop); --workers N (default = min(#sims, max(1, ncpu//4),
  #files)); --base; pass-through flags (--diff-only, --max-mutations, --no-cache,
  etc.) forwarded to each palace_mutate.py invocation; --report-dir.
- FILE-LEVEL fan-out (NOT mutant-level): each worker processes whole files so
  within-file DerivedData stays warm. ISOLATION via one git worktree + one pool
  sim + one PALACE_MUTATE_DERIVED_DATA_PATH per worker. NEVER batch mutants into
  one build (that masks survivors behind killed mutants — explicitly forbidden).
- Sim pool UDIDs: 141BD227-6E9A-4409-8D99-2D4FE818238D,
  BFB9B169-4E06-4087-BD6B-F54BB56EAA6B, 6C6BD82F-D659-4F77-8B9E-C2CBDF3A6CF8.
- Worktree setup: reuse the Palace recipe (Carthage/Build via 'cp -RL' not symlink;
  ios-audiobooktoolkit a REAL 'git submodule update --init'; other 7 submodules +
  adobe-rmsdk symlinked; copy gitignored secrets). See
  .claude/skills/swarm/SKILL.md Phase 0 for the exact recipe — replicate it.
- GATE parallelism on cost: if #files < 2 OR --workers 1, run SERIALLY in the main
  tree (no worktree/cold-build overhead) — small PRs must not get slower. log() the
  decision and what was parallelized vs serial (no silent caps).
- Aggregate each file's JSON report into a combined summary (total killed/survived/
  uncovered/suppressed, per-file kill rates, any critical_path_survivors>0 ->
  overall fail). Exit non-zero if any file fails its gate (mirror palace_mutate's
  contract).

TESTS (scripts/test_palace_mutate_parallel.py, pure-Python, mock subprocess +
worktree creation + filesystem): worker-count computation across (#files, #sims,
ncpu) edge cases incl. 0/1/many; serial-vs-parallel gating decision; sim
round-robin assignment to workers; report AGGREGATION from synthetic per-file
report dicts (sums, overall pass/fail, critical-path override). DO NOT create real
worktrees or run xcodebuild in tests — factor the orchestration so the pure logic
is callable in isolation.

Run: python3 -m unittest scripts.test_palace_mutate_parallel  (paste real output).
Report via StructuredOutput.`,
    { label: 'B:parallel-pool', phase: 'Parallel + Gate (B, D)', schema: IMPL_SCHEMA }),

  () => agent(`${COMMON}

COMPONENT D — Gate wiring. Modify scripts/verify-pr.sh and
scripts/post-mutation-pr-comment.py (read both first; verify-pr.sh is large —
read the '--- Mutation Testing ---' section thoroughly, roughly lines 610-735).
Touch scripts/resolve-tests-for.py ONLY if strictly needed.

palace_mutate.py's FINAL interface (from component C):
${c.interface}

Deliverables:
1. DIFF-SCOPED BY DEFAULT for the PR gate. In verify-pr.sh's mutation loop, pass
   --diff-only to palace_mutate.py BY DEFAULT (whole-file only when a new flag
   --mutation-whole-file is given — for release runs). Keep --enforce-mutations /
   --no-enforce-mutations / --mutation-min-kill-rate working. Update the header
   usage comment block.
2. CRITICAL-PATH ENFORCEMENT. After each palace_mutate run, read the per-file JSON
   report (jq or python one-liner) and if summary.critical_path_survivors > 0, mark
   that file a STRICT FAIL with a clear message naming the survivors' lines, even
   if the kill rate is >= the floor. Preserve the existing kill-rate parsing from
   the printed 'killed:/survived:' line and the exit-code handling (2 = hard error).
3. post-mutation-pr-comment.py: render new report sections — coverage_gap
   (uncovered lines as a 'free coverage-gap' callout), suppressed count, and
   critical_path_survivors prominently (these BLOCK). Keep existing table output.
4. DO NOT break the existing flow when the new report keys are absent (older cached
   reports) — default-missing-keys defensively.

VERIFICATION (no full xcodebuild needed):
- bash -n scripts/verify-pr.sh  (paste output; must be clean).
- python3 -c 'import ast; ast.parse(open("scripts/post-mutation-pr-comment.py").read())' (paste).
- If post-mutation-pr-comment.py has or can take a small pytest for its rendering
  given a synthetic report dict, add one under scripts/ and run it.
Report via StructuredOutput; paste real command output in 'evidence'.`,
    { label: 'D:gate-wiring', phase: 'Parallel + Gate (B, D)', schema: IMPL_SCHEMA }),
])

log(`B: ${b ? b.status : 'null'}; D: ${d ? d.status : 'null'}`)

// ===========================================================================
// Phase E — docs + whole-suite integration gate
// ===========================================================================
phase('Docs + integration gate (E)')
const e = await agent(`${COMMON}

COMPONENT E — Docs + integration gate. Two jobs:

1. Write docs/architecture/mutation-testing.md: the first-principles rationale for
   the whole system. Cover: the cost model (cost = #mutants x cost-per-run); the
   theory (DeMillo-Lipton-Sayward 1978, Competent Programmer Hypothesis, Coupling
   Effect); each lever and WHY it helps (coverage-gating, test-selection, Tier-1
   flags, diff-default, critical-path metric, per-mutant cache, parallel pool via
   ISOLATION-not-batching with the masking explanation, equivalent-mutant
   suppress-list); the graceful-degradation safety property (coverage parse fail ->
   behaves as before); and a 'Future work: mutant schemata' note (compile-once
   behind runtime switches — the real fix for the build being the bottleneck, hard
   in Swift). Include a short decision log. Keep it accurate to what actually
   shipped — read the changed scripts to verify claims before writing them.

2. INTEGRATION GATE — run and report (this is the real tooling contract):
   - Run EVERY python test in scripts: 'python3 -m unittest discover -s scripts -p "test_*.py" -v'
     AND any pytest suite under scripts/tests/ ('python3 -m pytest scripts/tests/ -q'
     if pytest is available; else note it). Paste the real summary lines.
   - 'bash -n' on every shell script changed by this swarm (at minimum
     scripts/verify-pr.sh). Paste output.
   - 'python3 -c "import ast,glob,sys; [ast.parse(open(f).read()) for f in
     glob.glob(\\'scripts/*.py\\')]"' to confirm all scripts parse.
   - Import-smoke: 'cd ${REPO} && python3 -c "import sys; sys.path.insert(0,\\'scripts\\');
     import palace_mutate, mutate_coverage, palace_mutate_parallel"' (paste).
   If any test FAILS, FIX the smallest cause directly (you may edit any scripts/
   file) and re-run until green, OR if a failure reveals a genuine design conflict
   between components, report status FAIL with remaining_issues so the orchestrator
   resolves it. Do not paper over a real failure by deleting tests.

Report via StructuredOutput (E_SCHEMA): status PASS only if all gates green.`,
  { label: 'E:docs+gate', phase: 'Docs + integration gate (E)', schema: E_SCHEMA })

return {
  A: a && a.status,
  C: c && c.status,
  B: b && b.status,
  D: d && d.status,
  E: e && e.status,
  e_remaining: e && e.remaining_issues,
  files: {
    A: a && a.files_changed,
    C: c && c.files_changed,
    B: b && b.files_changed,
    D: d && d.files_changed,
  },
}
