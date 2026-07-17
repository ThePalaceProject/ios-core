# Contract F — Self-Verifying Architecture (WS5)

**Module:** docs/architecture/.arch + scripts + .github/workflows
**Risk:** standard (tooling + docs; no production runtime). Gates the whole swarm's durability.
**Depends on:** A (doctrine → probes), C (registry probes), E (snapshots → diagrams)
— **land LAST.**

## Verified starting facts / constraints
- `docs/architecture/.arch/facts.json` exists (16 structural + 5 semantic anchors).
- **`harness arch drift` is machine-local** (`~/harness/core/lib/arch.py`) and is
  NOT available on CI runners — `.github/workflows/tooling-checks.yml` runs on
  `ubuntu-latest` with `submodules: false` and no harness. **Therefore WS5 must
  vendor a repo-local, dependency-free drift checker into `scripts/`** that reads
  the committed `facts.json` probes and greps the committed source. Do NOT wire the
  machine-local `harness` binary into the workflow — it will not exist in CI.
- Contract framework snapshots land under
  `PalaceTests/Contract/__Snapshots__/<TestClass>/*.json` (Contract E produces the
  MyBooks ones). Sequence diagrams must be DERIVED from these, not restated.
- `tooling-checks.yml` already runs `bash -n` on shell scripts + detector pytests
  in `scripts/tests/` — extend this job, honoring green-board rule #4.

## Scope (exact files)
1. **Expand `docs/architecture/.arch/facts.json`** — add nodes/manifest anchors for
   the flows not yet represented: **download** (`DownloadStartCoordinator`,
   `DownloadStartDispatcher`), **sign-in** (`AuthReducer` / PalaceAuth), **reader**
   (`Reader2` position/bookmark). Add semantic probes encoding Contract A doctrine:
   - `absent` probe: `BorrowReducer` contains no `.task` (shape-only holds).
   - `absent` probe: `Store.swift` contains no `scope(` (Not TCA holds).
   - `count`/justified probe: exactly 2 `struct Effect<...Sendable>` (Contract B).
   - `count` probe: exactly 2 book-state owner classes (Contract D).
   - `contains` probe: `TPPBookRegistry.setState` references `canTransition`
     (Contract C enforcement present).
2. **CREATE `scripts/arch-drift-check.py`** — reads `facts.json`, resolves each
   `manifest`/semantic probe against live source (grep for `probe`, honor
   `match: absent|contains|count`), exits non-zero on drift. Pure stdlib.
3. **CREATE `scripts/arch-sequence-diagrams.py`** (or a subcommand) — reads
   `PalaceTests/Contract/__Snapshots__/*/*.json` and emits Mermaid sequence
   diagrams into `docs/architecture/flows/` DERIVED from the recorded call logs
   (do not hand-author flow prose).
4. **Wire into `.github/workflows/tooling-checks.yml`** a step running
   `python3 scripts/arch-drift-check.py` on every PR.
5. **Rule #4 compliance (MANDATORY before this lands):**
   (a) add `scripts/tests/test_arch_drift_check.py` (pytest);
   (b) the pytest must assert BOTH a drift case FAILS and a **clean-tree case
   PASSES** (clean-path assertion);
   (c) dry-run `scripts/arch-drift-check.py` on the current tree → zero false
   positives before wiring it into the workflow.

## Off-limits
- Any `Palace/**` production source (this contract only READS it via probes).
- `PalaceTests/Contract/*.swift` bodies (owned by C/D/E) — F only READS the
  `__Snapshots__` JSON they emit.
- The machine-local `~/harness` tree — do not modify or depend on it in CI.

## What changes
- New scripts + expanded JSON + a workflow step + a pytest. No app-code change.

## Test contracts
- `scripts/tests/test_arch_drift_check.py`: drift → non-zero; clean → zero
  (both directions asserted). This IS the rule-#4 clean-path gate.

## Verification criteria (Phase 4.5)
```bash
# AC1: facts.json gained download + sign-in + reader anchors
python3 -c "import json;d=json.load(open('docs/architecture/.arch/facts.json'));s=json.dumps(d);assert 'DownloadStart' in s and ('AuthReducer' in s or 'PalaceAuth' in s) and 'Reader2' in s"

# AC2: doctrine encoded as probes (absent/count) in facts.json
python3 -c "import json;d=json.load(open('docs/architecture/.arch/facts.json'));s=json.dumps(d);assert 'canTransition' in s and 'scope(' in s"

# AC3: repo-local drift checker exists, is stdlib-only, and PASSES clean tree
test -f scripts/arch-drift-check.py
python3 scripts/arch-drift-check.py   # must exit 0 on the clean tree

# AC4: sequence diagrams are derived from snapshots, not hand-written
test -d docs/architecture/flows
grep -rq 'sequenceDiagram' docs/architecture/flows/

# AC5: wired into the tooling-checks workflow (NOT the machine-local harness)
grep -q 'arch-drift-check.py' .github/workflows/tooling-checks.yml
! grep -q 'harness arch drift' .github/workflows/tooling-checks.yml

# AC6: rule-#4 — pytest exists and asserts BOTH clean-pass and drift-fail
test -f scripts/tests/test_arch_drift_check.py
grep -Eq 'clean|pass|exit_code == 0|returncode == 0' scripts/tests/test_arch_drift_check.py
grep -Eq 'drift|fail|!= 0' scripts/tests/test_arch_drift_check.py
python3 -m pytest scripts/tests/test_arch_drift_check.py -q
```
