# Recovering simulator logs after the fact

A QA or chaos pass records the log lines its operator thought to quote. Every
other line the app and the system emitted during that pass is, by default,
treated as gone. It usually is not gone: the simulator keeps its own unified-log
store on the host filesystem, independent of anything the harness captured, and
that store outlives the pass.

`scripts/sim-log-recover.sh` reads it.

## Why this matters more than it sounds

A finding backed by one pasted log line cannot survive being questioned. When a
reviewer asks "was that really two requests, or one request retried?", the
quoted fragment cannot answer — and the usual next step is to re-drive the
scenario, which costs a simulator, a build, and an hour, and produces a *new*
observation rather than evidence about the original one.

This is not hypothetical. In one release regression the run's `logs/` and
`crashes/` trees were empty for every device cell, so 41 findings rested
entirely on quoted fragments. One of them was filed **minor** on the strength of
a single `-999 cancelled` line, with a stated cause of "a duplicate fulfillment
download that is cancelled mid-flight."

Recovering the store showed three download tasks on the app's background
session, not one:

```
<5848D9C1…>.<1>  resumed 21.139 → finished with error [-999] cancelled 22.749
<BBBBBD5C…>.<2>  resumed 24.420 → finished successfully              25.917
<C7AF18D9…>.<3>  resumed 27.472 → finished successfully              28.619
```

— each preceded by its own request to the fulfillment endpoint. One borrow
billed the circulation manager three times and downloaded the same EPUB twice.
The finding was promoted to major on the critical path. Nothing was re-driven;
the evidence had been sitting on disk the whole time.

## The contract

**It does not touch the device.** The script reads host files only. It is safe
against a simulator another session or agent currently owns — no lock is
claimed, and a pass running on that device is not disturbed. This is the point:
evidence recovery must never require taking a simulator away from whoever is
using it.

**It reads system subsystems, not the app's own narration.** The shim carries
partial metadata, so the app's `os_log` output renders as
`<compose failure [UUID]>`. `com.apple.CFNetwork`, `com.apple.network`,
`runningboard`, and WebKit come through complete. That is enough to settle
network- and lifecycle-shaped questions — how many requests were issued, whether
they succeeded, whether a process was respawned — and not enough to read what
the app said about itself. Know which kind of question you have before you
start.

**Coverage is finite.** The store rotates. Check what a device still holds
before assuming a window is recoverable:

```bash
ls -t ~/Library/Developer/CoreSimulator/Devices/<UDID>/data/var/db/diagnostics/Persist
```

## Empty results are disambiguated, not just reported

This tool exists to settle questions of the form "did the app actually issue
that request." An operator error that silently reads as "no, it didn't" would
retract true findings, so the script refuses to let the two look alike:

| exit | meaning | safe to reason from? |
|---|---|---|
| `0` + output | matches found | yes |
| `0` + `0 matches` on stderr | the window HAS log data; nothing matched | **yes** — a real negative |
| `3` + `WINDOW NOT COVERED` | the window has no log data at all | **no** — says nothing either way |
| `1` | no store for that UDID | no |

The distinction is pinned by `scripts/tests/test_sim_log_recover.sh`, which
stubs `log` so it needs no simulator. Two mutants were used to prove the guard
bites: counting raw lines instead of data lines (an uncovered window then
reports itself as a real negative) and dropping the `|| true` on the filter
(a legitimate zero-match then exits non-zero). Both are caught by name.

## Four ways to get an empty result that is not missing data

Each of these returns zero lines. The script now tells the first three apart
from a genuine negative, but knowing them still saves time — all four have
bitten someone.

1. **Omitting `--info --debug`.** CFNetwork task lifecycle is emitted at Debug
   level. The script always passes both; anyone hand-rolling `log show` must
   too.
2. **Using a process predicate.** `process == "Palace"` matches nothing here,
   because process names do not resolve against partial metadata — and it fails
   silently rather than erroring. Filter on message text instead.
3. **Passing a UTC timestamp.** The tool wants local time. Chaos shard
   directories are named in UTC, so a shard named `…T15-06-59Z` is `11:06` in a
   UTC-4 zone. Passing `15:06` yields an empty window.
4. **Grepping for a symbol the app emits.** Searching a recovered archive for
   `downloadTaskWithRequest`, a `Log.debug` message, or any other app-authored
   string returns zero — not because it did not happen, but because app `os_log`
   lines cannot be composed here (see the contract above). This one is the most
   dangerous of the four: it produces a confident zero that *contradicts* a real
   finding. Once, a recommendation to re-count a confirmed defect this way would
   have returned 0 and retracted it. **Count what the system emitted — task
   UUIDs, connection IDs — never a string the app itself logged.**

## Usage

```bash
scripts/sim-log-recover.sh <UDID> <start> <end> [grep-pattern]

# every Palace-attributed URLSession task created in a one-minute window
scripts/sim-log-recover.sh "$UDID" '2026-08-20 11:11:00' '2026-08-20 11:12:00' \
    'is for <org.thepalaceproject.palace>'

# what a task did next
scripts/sim-log-recover.sh "$UDID" '2026-08-20 11:11:00' '2026-08-20 11:16:00' \
    '5848D9C1|BBBBBD5C|C7AF18D9'
```

Counting distinct network operations is the common case, and
`Task <UUID>.<n> is for <bundle-id>.<session-id>` is the line that does it: one
per task actually created, attributed to the session that created it. Pair it
with `finished successfully` / `finished with error` to get outcomes rather than
intentions.

## When to reach for it

- A finding's stated cause rests on a single quoted line and someone disputes it.
- You are about to re-drive a scenario **only** to recover a log. Read the store
  first; if the original run is still in coverage, you already have the answer,
  and it is evidence about the original observation rather than a new one.
- A differential needs the same measurement on both builds and one side has
  already been driven.

See also `docs/bug-investigation-process.md` — step 1, "reproduce against the
REAL artifact first." This is one of the ways to get that artifact when the
moment has passed.
