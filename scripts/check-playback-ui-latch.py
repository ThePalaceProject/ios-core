#!/usr/bin/env python3
"""
check-playback-ui-latch.py — detect a BLOCKING audiobook UI state derived from a
live readiness signal without the session-phase latch.

Catches the PP-5205 wall-failure class. `LCPStreamingPlayer.play(at:)` drops
`isLoaded` on every cross-track seek (":204 — Only show loading state for heavy
operations (rebuilds or track changes)"), and iOS drops it again when it evicts the
AVPlayer buffer on backgrounding (AudiobookSessionPresenter:601). A UI predicate that
asks only "is the player loaded right now" cannot tell those transients from the
pre-playback window, so it replaces a PLAYING book with a full-screen loading panel
and reads to the patron as though the audio broke.

`AudiobookDownloadProgressPolicy.shouldShowPlayerDownloadBar` already solved this one
layer down by latching on `hasStartedPlayback`; `loadingOverlayState` sat directly
above it and never received the same input. This detector exists so the next such
predicate cannot repeat that.

PREDICATE — all three must hold:

  1. A `static func` (the pure-predicate shape this codebase uses for UI decisions).
  2. Its parameter list names a LIVE readiness signal: isLoaded / isBuffering /
     isDownloading / isPlaying.
  3. Its return type is a BLOCKING UI STATE — an enum whose name ends in
     `OverlayState`, `LoadingState`, `PresentationState` or `ScreenState`.

...and it does NOT also take `hasStartedPlayback`.

Requirement 3 is load-bearing and was learned the hard way. A predicate that RETURNS
a blocking state owns the takeover decision; one that returns `Bool` merely GATES it
and is often the backstop that makes the latch safe (`shouldSurfaceLoadTimeout` is
exactly that — latching it would suppress genuine mid-session failures). During
PP-5205 the author's scope conclusion said 2 survivors while this refined predicate
said 1, and the predicate was right. Validating a detector against a survivor set
containing a false positive tunes it to keep firing on that false positive — the
failure mode CLAUDE.md's CI contract #4 forbids.

LIMIT, stated so a clean run is not over-read: this cannot see timer-lifecycle bugs.
PP-5205's second defect — a 30s `asyncAfter` with no `DispatchWorkItem` handle,
stacking on every re-entry — is invisible to any signature-shaped check. A clean run
means "no unlatched blocking predicate", never "this file is clean".

ESCAPE HATCH: `// no-playback-latch: <reason>` on the `static func` line itself.
Deliberately line-adjacent: a marker on a preceding comment line is silently ignored
by several linters in this repo, which produces an annotation that looks applied and
is not.

Exit 0 clean, 1 on violations, 2 on usage error.
"""
from __future__ import annotations
import re
import sys
import pathlib

LIVE_SIGNALS = ("isLoaded", "isBuffering", "isDownloading", "isPlaying")
LATCH = "hasStartedPlayback"
BLOCKING_RETURN = re.compile(r"->\s*\w*(OverlayState|LoadingState|PresentationState|ScreenState)\b")
STATIC_FUNC = re.compile(r"\bstatic\s+func\s+(\w+)\s*\(")
ESCAPE = re.compile(r"//\s*no-playback-latch\s*:")

SEARCH_ROOTS = ("Palace",)
MAX_SIGNATURE_LINES = 14


def signature_at(lines: list[str], start: int) -> tuple[str, int]:
    """Collect a possibly multi-line signature starting at `start`.

    Multi-line matters: BOTH known instances of this class are written with one
    parameter per line, so a single-line regex finds neither.
    """
    text = ""
    depth = 0
    for offset in range(min(MAX_SIGNATURE_LINES, len(lines) - start)):
        line = lines[start + offset]
        text += line + "\n"
        depth += line.count("(") - line.count(")")
        if depth <= 0 and "(" in text:
            return text, start + offset
    return text, start


def scan_file(path: pathlib.Path) -> list[tuple[int, str]]:
    lines = path.read_text(errors="ignore").splitlines()
    out: list[tuple[int, str]] = []
    for i, line in enumerate(lines):
        m = STATIC_FUNC.search(line)
        if not m:
            continue
        if ESCAPE.search(line):
            continue
        sig, _ = signature_at(lines, i)
        if not BLOCKING_RETURN.search(sig):
            continue
        if not any(f"{s}:" in sig for s in LIVE_SIGNALS):
            continue
        if f"{LATCH}:" in sig:
            continue
        out.append((i + 1, m.group(1)))
    return out


def main(argv: list[str]) -> int:
    root = pathlib.Path(argv[1]) if len(argv) > 1 else pathlib.Path(".")
    violations: list[tuple[pathlib.Path, int, str]] = []
    for r in SEARCH_ROOTS:
        base = root / r
        if not base.exists():
            continue
        for f in base.rglob("*.swift"):
            for ln, name in scan_file(f):
                violations.append((f.relative_to(root), ln, name))

    if not violations:
        print("[playback-ui-latch] OK — no blocking UI predicate reads a live readiness signal without `hasStartedPlayback`.")
        print("[playback-ui-latch] NOTE: this cannot see timer-lifecycle bugs (PP-5205's second defect). A clean run is not 'this file is clean'.")
        return 0

    print("[playback-ui-latch] FAIL: blocking UI state derived from a live readiness signal, with no session-phase latch.\n")
    for f, ln, name in violations:
        print(f"  {f}:{ln}  {name}(...)")
    print(
        "\nA live readiness signal goes false mid-session — a cross-track seek"
        "\n(LCPStreamingPlayer:204) or iOS evicting the AVPlayer buffer"
        "\n(AudiobookSessionPresenter:601). Without `hasStartedPlayback` this predicate"
        "\ncannot tell that from the pre-playback window, and will replace a PLAYING"
        "\nbook with a loading panel (PP-5205)."
        "\n\nTake `hasStartedPlayback` and branch on phase. Do NOT return a hidden/empty"
        "\nstate mid-session unless you have checked what else that state's `.onAppear`"
        "\nwas responsible for — in PP-5205 it was the only site arming the load-error"
        "\ntimer, so hiding made a real failure unreachable for the whole session."
        "\n\nIf this predicate genuinely should not latch (it GATES a takeover rather than"
        "\nowning one — e.g. a backstop that must stay reachable), annotate the"
        "\n`static func` line itself: // no-playback-latch: <reason>"
    )
    return 1


if __name__ == "__main__":
    sys.exit(main(sys.argv))
