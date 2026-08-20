# Recovering simulator logs after the fact

A QA or chaos pass records the log lines its operator thought to quote. Every
other line the app and the system emitted during that pass is, by default,
treated as gone. It usually is not gone: the simulator keeps its own unified-log
store on the host filesystem, independent of anything the QA run captured, and
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

**It reads what was PERSISTED, which is not everything the device logged.**
Two separate gaps, and the second one is easy to miss because it looks like a
real negative:

- The app's own `os_log` output renders as `<compose failure [UUID]>` — the
  shim carries partial metadata and cannot resolve app format strings.
- **Info-level records are ~98% absent.** Measured on one window: debug 5,861
  of 5,972 and error 133 of 139 came through; info, 78 of 4,472. Info records
  live in a buffer that is never written to disk, so no combination of log-level
  flags recovers them from an archive.

The second gap has teeth because ordinary network chatter is info level. TLS
teardown, `nw_endpoint_handler_cancel`, boringssl warning alerts — grep this
store for any of them and you get a confident zero from a window that held
hundreds. An earlier version of this page claimed system subsystems "come
through complete." That was wrong, and it produced exactly that false zero
during a live investigation: four quoted log strings were reported as
non-existent across three device cells when they were simply info level.

**Info records are recoverable while the simulator is still booted**, with a
live read that sees the unpersisted buffer:

```bash
xcrun simctl spawn <UDID> log show --start '...' --end '...' \
    --style compact --info --debug
```

That spawns a process on the device, so it requires owning the simulator —
the trade this script otherwise avoids. **Shut the simulator down and the info
records are gone permanently.** If a pass produced evidence you may need, read
it live before the device is reclaimed.

So: this script for debug- and error-level evidence — CFNetwork task lifecycle,
process spawns, WebKit errors. A live read for anything info level. Neither for
the app's own narration.

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

## If you will want to quote it at info level, capture it live during the run

The archive is complete for debug and error and near-empty for info. So
anything you expect to quote at info level must be captured **live, while the
run is happening**, or it does not exist afterward — a shutdown ends the buffer
and a later boot starts a new one rather than restoring the old.

That makes live capture a property of the RUN, not of the analysis. A QA or
chaos pass that will cite log evidence should stream its own log to a file for
the duration:

```bash
xcrun simctl spawn <UDID> log stream --style compact --info --debug > pass.log &
```

Everything this page describes is recovery of what survived. It is not a
substitute for capturing the record in the first place, and the gap is silent:
a pass that never captured looks identical afterward to one whose evidence was
merely never quoted.

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
 Searching a recovered archive for
   `downloadTaskWithRequest`, a `Log.debug` message, or any other app-authored
   string returns zero — not because it did not happen, but because app `os_log`
   lines cannot be composed here (see the contract above). This one is the most
   dangerous of the four: it produces a confident zero that *contradicts* a real
   finding. Once, a recommendation to re-count a confirmed defect this way would
   have returned 0 and retracted it. **Count what the system emitted — task
   UUIDs, connection IDs — never a string the app itself logged.**

## A zero is only a measurement if the command hit something

The section above is about a tool returning nothing. This is the layer beneath
it, and no tooling catches it: a command that never reached its target prints a
clean, confident zero.

Three instances turned up in a single afternoon, two of them in the hands of
people who had just written the warning:

- `git show $ref:path` unquoted in zsh. `:P` is a path modifier, so the ref
  expands to an absolute path, git fatals, and the piped `grep -c` prints `0`.
  Two failures stacked, one visible result.
- A `pytest` invocation piped to `tail`, whose exit status came from `tail`.
- A grep against `Palace/Book/BookDetailView.swift`, a path that does not
  exist — the file is at `Palace/Book/UI/BookDetail/BookDetailView.swift`.
  Correct quoting, clean exit code, still a zero from nothing.

The habit that catches all three: **confirm the target resolves, then count.**
`git cat-file -e "$ref:$path"` before grepping it; check the file exists before
searching it; read the exit code rather than the number. When a zero would
change a decision, prove the command hit something first — show a non-zero
count of a line you KNOW is there, then run the real query.

The same rule applies to any artifact a pass depends on, not just to a grep.
A shared build directory once vanished from `/tmp` mid-campaign with no error
and no warning; it was discovered forty minutes later when an install failed.
A two-second `ls` in the pass preamble would have caught it at the start. Treat
a missing artifact as an expected condition to check for, not an incident to
discover — and note that "we moved it somewhere safer" is not the same as
knowing what removed it.

This is deliberately written as discipline rather than a script. A guard that
covered only the wrong-target cases would leave the merely-wrong-pattern case
returning an identical honest zero, while implying the class was handled —
which is the failure shape this whole document exists to prevent.


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
