# HANDOFF — swarm_8ce6f5ae (world-class state-management) — resume E2 + test creation

**You are a fresh context.** This file + the contracts in this dir + `CLAUDE.md` are
everything you need. Read this top-to-bottom once, then work the ordered task list.
Memory pin: `swarm-8ce6f5ae-worldclass-statemgmt`. Campaign report artifact + full
context are gone from the model; THIS file is the source of truth.

---

## 60-second orientation
- **Goal tonight:** finish the campaign's *extraction* (E2) + *test creation* (record
  the E1 pins, mutation, fill borrow-side gaps). Ship-today/verify-Monday model.
- **Branch:** `swarm/swarm_8ce6f5ae-scaffold` in the ISOLATED worktree
  `/Users/mauricework/PalaceProject/ios-core/.claude/worktrees/swarm_8ce6f5ae-orchestrator`.
  **cd there and stay there.** Do NOT work in the main checkout (it's on `develop`, the user's).
- **Tip:** `1f244b221` — A/B/C/D/E1 + a ~50-file Swift-6 test-bundle repair, all
  integrated and compiling (`** TEST BUILD SUCCEEDED **`). NOT merged.
- **Authoritative specs:** `.forgeos/swarms/swarm_8ce6f5ae/contracts/{A..F}-*.md`.
  Contract **E** = pin-then-extract (your E2 work). Contract **F** = self-verifying gate.

## What's already DONE (committed — do NOT redo)
| WS | Done | Files (committed at 1f244b221) |
|----|------|------|
| A | doctrine ADR | `docs/architecture/state-management-doctrine.md` |
| B | PalaceAuth `Effect` boundary (Sendable bound, count-1 probe, keep pkg copy) | `Palace/Packages/PalaceAuth/Sources/PalaceAuth/{Effect,AuthReducer}.swift` + EffectBoundaryTests |
| C | kill `TPPBookRegistry` dual-write + enforce `allowedTransitions` | `TPPBookState.swift`, `TPPBookRegistry.swift`, 9 observers, 2 posters, `TPPBookRegistryMutationContractTests.swift` |
| D | `SideloadedBookRegistry` SoT boundary | `Palace/MyBooks/Sideload/{SideloadedBookRegistry,BookStateReading}.swift`, SideloadBoundaryTests |
| E1 | characterization pins (12 dispatcher + return branches) | `PalaceTests/Contract/{DownloadStartDispatcherContractTests, BookReturnServiceContractTests, BorrowOperationContractTests}.swift` |
| Infra | Swift-6 repair of ~50 PalaceTests files + 2 locked mocks + `SafeDictionary` annotation | (Fable) |

## Environment — how to build/test (learn from our pain)
- **Build (compile check):** `xcodebuild -project Palace.xcodeproj -scheme Palace
  -destination 'generic/platform=iOS Simulator' -derivedDataPath /tmp/dd-<tag>-$RANDOM build`
  (or `build-for-testing`). **Use `generic/platform=iOS Simulator`** — a hardcoded
  `name=iPhone 16 Pro` FAILS (sims are all claimed by ~40 parallel worktrees; it falls
  back to physical iPads on iOS 16 and errors).
- **Run tests on a sim:** `~/harness/bin/harness test -- -only-testing:PalaceTests/<Class>`
  (auto-claims a sim + isolated dd). `-only-testing` is a spot-check, NEVER "the suite".
- **Full CI-parity (Monday gate):** `scripts/xcode-test-optimized.sh` — must end
  `** TEST SUCCEEDED **` with no timeout/restart.
- **Disk:** builds are ~7.5 GB each and the shared volume hits ENOSPC. If a build dies on
  disk: `rm -rf /tmp/dd-<yourtags>-*` (ONLY your own; leave `dd-Bt`/`dd-buga`/other fleets').
- **Mutation:** `python3 scripts/palace_mutate.py --file <f> --tests <Class> --diff-only`.

## TONIGHT — ordered task list

### 1. E1 borrow-side pin coverage audit (BEFORE E2 — the gate)
E1's *dispatcher* (12) + *return* pins are solid. The *borrow-side* pins may be PARTIAL
(that implementer was stopped mid-hang). Confirm/fill in `BorrowOperationContractTests.swift`:
30s-timeout branch, streaming-HTML startDownload-skip, PP-4178 loan→hold race throw,
DRM `ensureDeviceActivated`. **E2 must NOT change behavior until every borrow/return/
download branch is pinned + green.**

### 2. Record + verify the contract snapshots (the test-creation blocker)
The E1 tests COMPILE + RUN (37 executed, real code paths driven) but new baselines FAIL to
persist: `ContractSnapshot` tried to write to `/PalaceTests/__Snapshots__` (absolute,
**read-only** on the sim) — `NSCocoaError 642 / read-only file system`. The 39 EXISTING
snapshots are fine; only NEW baselines won't record.
- **Fix:** read `PalaceTests/Contract/ContractSnapshot.swift` — its write path resolves
  wrong under the sim run. Make record write to the worktree SOURCE `__Snapshots__` dir
  (via `#filePath` base, or `CONTRACT_SNAPSHOT_RECORD=1` from a host-writable context — see
  CLAUDE.md "Contract-snapshot tests"). Then: run once to RECORD, review the `git diff`
  of the new `__Snapshots__/*.json`, run again to VERIFY (assert). Both passes green.

### 3. Mutation on the C critical lines
`palace_mutate.py --diff-only` on `Palace/Book/Models/TPPBookRegistry.swift` +
`TPPBookState.swift` — 100% on the `canTransition` call site + the `registryStatePublisher`
feed points. (Was blocked by the bundle earlier; bundle now compiles.)

### 4. E2 — EXTRACT the reducer cores (the main event)
Per contract **E** (`.forgeos/swarms/swarm_8ce6f5ae/contracts/E-*.md`). MBDC is ALREADY a
delegation hub over 27 collaborators — this is NOT "decompose the god-class." Extract the
DECISION CORES of these three into pure `reduce`-style functions, each **snapshot-proven
shape-equal to its E1 pin**; the collaborators + `MyBooksDownloadCenter` stay as
effect-runners (delegate conformances untouched):
- `BorrowOperation` (989 LOC) → `BorrowReducerCore`
- `BookReturnService` (744) → `ReturnReducer`
- `DownloadStartDispatcher` (321) → `DownloadStartReducer`
Write each core + its unit tests (TDD, hella tests, 100% mutation on critical lines). New
Swift files: `ruby scripts/pbxproj_add_swift.rb <files>` (both targets).

### 5. Re-run the E1 contract snapshots after E2 — they MUST still be shape-equal (proves
the extraction is behavior-preserving). Any snapshot drift = the extraction changed behavior = STOP.

## LATER (Monday gate — not tonight unless time):
F (vendor stdlib `scripts/arch-drift-check.py` into `.github/workflows/tooling-checks.yml`
+ rule-#4 pytest + doctrine probes) · full `xcode-test-optimized.sh` · simdrive regression
(borrow/return/download/audiobook/sign-in) · `/forge-review` 3 SoD via `heka2 gate review`
· `heka2 merge --check` → PR to `develop`.

## RULES — do not violate
- **Never bypass a detector.** If pre-commit blocks (e.g. phase35 unsynchronized-Sendable-mock),
  FIX it (lock mutable state with `NSLock`/`withLock` — pattern: `TPPBookRegistryMock`), don't `SKIP=`.
- **Commits ≥50 prod LOC need the `**Scope:** / **Not done:** / **Deferred:**` stanza.** No `--no-verify`.
- **Critical path** (registry/book-state/borrow/return/download/DRM/sign-in): every branch
  tested, every test kills a mutant. Air-tight.
- **Verify via the FULL suite**, never a `-only-testing` subset reported as green (PP-4542 lesson).
- **Leave the main checkout alone** (user's, on `develop`). Work only in the worktree.
- Governance is **heka2** (not ForgeOS): `heka2 context/route/gate/review/merge`; worktree-HEAD
  bug (#7) is FIXED so gates work from the worktree.

## Decisions ALREADY made (Fable-adjudicated — don't re-litigate)
1. B keeps the PalaceAuth `Effect` copy (package boundary), not collapse.
2. C corrected `allowedTransitions` (added `.downloadSuccessful`/`.used`/`.holding` → targets)
   BEFORE enforcing — enforcement is `assertionFailure` DEBUG / log RELEASE, then STILL applies.
3. C created + fed `registryStatePublisher` (syncStatePublisher was dead); lifecycle observers
   (registry:455 SAML-sync, MBDC:2076 launch-reconcile, AppTabHostView:456 badge) route there.
4. Bundle repair kept Swift 6 (surgical, ~50 files) — do NOT revert dd6b73ee0.

## Pointers
- Contracts: `.forgeos/swarms/swarm_8ce6f5ae/contracts/*.md` · Transcripts: `../transcripts/*.md`
- Fable reviews: `../architect-review.md`, `../architect-review-C.md`
- Doctrine: `docs/architecture/state-management-doctrine.md`
- Commits: `git log --oneline swarm/swarm_8ce6f5ae-scaffold` (scaffold → contracts → A → amend → integrate).
