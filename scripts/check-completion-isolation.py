#!/usr/bin/env python3
"""Fail if a completion handler is invoked from a Task that does not run on the main actor.

THE DEFECT (PP-4955). `DefaultAudiobookManager.seekWithSlider` in the audiobook
toolkit did its work inside a bare `Task { … }` and called the caller's
completion closure from that Task. The app's `AudiobookSessionManager` is
`@MainActor`, so the closure it passed in was main-actor-isolated. Swift does not
warn about this. At runtime it does not throw either — it kills the process:

    dispatch_assert_queue_fail
    swift_task_checkIsolatedSwift
    closure #1 in AudiobookSessionManager.seek(to:)
    closure #2 in DefaultAudiobookManager.seekWithSlider(value:completion:)

Scrubbing a DRM audiobook terminated the app, with no error and no chance to save
the patron's position. Three crash reports in one minute on a shipping build.

THE RULE, which is the entire subtlety. `Task { }` INHERITS the enclosing actor
isolation. So a bare `Task { }` inside a `@MainActor` type already runs on main
and its completion call is safe — `CarPlayAudiobookBridge.playAudiobook` and
`LibraryService.openPublication` both look exactly like the crash and are both
fine for this reason. `DefaultAudiobookManager` is a plain class, so ITS `Task { }`
inherited nothing and landed on the cooperative executor. The difference between
a crash and correct code is the isolation of the enclosing declaration, not the
shape of the call. That is why this check reads context rather than grepping for
`Task`. `Task.detached` inherits nothing regardless and is always flagged.

WHY NOT A RUNTIME ASSERTION. An explicit `MainActor.assertIsolated()` inside a
closure created by a `@MainActor` type is unreachable: Swift's own isolation
check runs on entry and traps first. In this app every audiobook call site is
inside a `@MainActor` type, so such an assertion would be dead code that looks
like safety. The check that earns its place is this one — static, over the sites
where isolation is genuinely absent.

WHAT IT DELIBERATELY DOES NOT FLAG. Completions documented as off-main whose
callers handle it — `TPPBookRegistry.syncLocation` is the live example: the
registry is `@unchecked Sendable`, not `@MainActor`, and its one caller hops
explicitly. Add such a site to EXEMPT with the reason, not a blanket suppression.

    python3 scripts/check-completion-isolation.py [file ...]

With no arguments it scans every tracked Swift file under Palace/.
Exit 0 when clean, 1 on a finding, 2 on a usage error.
"""

from __future__ import annotations

import os
import re
import subprocess
import sys

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

# "path:symbol" -> reason. Every entry was triaged by reading the CALLERS and
# establishing that no caller passes a @MainActor-isolated closure. That is the
# only question that matters: off-main delivery is not itself a defect, it is a
# defect when the closure on the other side is actor-isolated.
EXEMPT: dict[str, str] = {
    "Palace/Book/Models/TPPBookRegistry+Extensions.swift:syncLocation":
        "TPPBookRegistry is @unchecked Sendable, not @MainActor, and this completion is "
        "documented as firing off-main. Its sole caller "
        "(AudiobookSessionManager.swift:1746) hops deliberately and says so.",

    "Palace/Accounts/AgeCheck/TPPAgeCheck.swift:verifyCurrentAccountAgeRequirement":
        "delivery is explicitly onto a private serialQueue — an intentional off-main "
        "contract, not an omitted hop.",

    # URLSession hands these completions to the delegate itself. There is no
    # caller-supplied closure and therefore no isolation to violate; URLSession
    # requires only that the handler be invoked, not on which queue.
    "Palace/MyBooks/MyBooksDownloadCenter.swift:urlSession":
        "completionHandler is a URLSessionDelegate parameter supplied by URLSession, "
        "not a caller's isolated closure.",
    "Palace/Reader2/ReaderStackConfiguration/LCP/LicensesService.swift:urlSession":
        "completionHandler is a URLSessionDownloadDelegate parameter supplied by "
        "URLSession, not a caller's isolated closure.",

    # Documented off-main contract. Worth knowing: NOT hopping here is exactly what
    # crashed Sign In in 3.3.0 (Crashlytics, 2/2 repro) — the caller comment at
    # TPPSignInBusinessLogic.swift:583 records it. The call site now hops with
    # `Task { @MainActor in }`, so the contract is honoured rather than absent.
    # This is the strongest evidence that this defect class is live in this app.
    "Palace/Network/TPPNetworkExecutor.swift:executeTokenRefresh":
        "documented as completing on a background queue; both callers "
        "(TPPSignInBusinessLogic:579 hops to @MainActor; TPPNetworkExecutor:675 is "
        "itself non-isolated) handle it.",
    "Palace/Packages/PalaceAuth/Sources/PalaceAuth/TokenRequest.swift:execute":
        "PalaceAuth is a transport package with no main-actor callers; the completion "
        "is consumed by TPPNetworkExecutor, which is not main-actor isolated.",

    # ReaderModule is `@unchecked Sendable`, NOT @MainActor, so the closure it
    # passes to `sync` is not isolated. `finalizePresentation` does touch UIKit,
    # and marshals onto the main actor itself via MainActor.run — see its comment.
    "Palace/Reader2/BusinessLogic/TPPLastReadPositionSynchronizer.swift:sync":
        "sole completion-taking caller is ReaderModule (not @MainActor); its closure "
        "calls finalizePresentation, which marshals its own UIKit work onto main.",
    "Palace/Reader2/BusinessLogic/TPPLastReadPositionSynchronizer.swift:presentNavigationAlert":
        "the async twin it awaits already wraps its UI in DispatchQueue.main.async; the "
        "completion afterwards carries no main-actor closure.",
}

DECL = re.compile(
    r"^\s*(?:@\w+(?:\([^)]*\))?\s+)*"
    r"(?:public\s+|internal\s+|private\s+|fileprivate\s+|open\s+)?"
    r"(?:final\s+)?(class|struct|actor|enum|extension)\s+([A-Za-z_]\w*)"
)
FUNC = re.compile(
    r"^\s*(?:@\w+(?:\([^)]*\))?\s+)*"
    r"(?:public\s+|internal\s+|private\s+|fileprivate\s+|open\s+)?"
    r"(?:static\s+|class\s+|final\s+|override\s+|nonisolated\s+)*func\s+([A-Za-z_]\w*)"
)
# `let handle = Task { … }` is the same construct as a bare `Task { … }`;
# a binding on the left does not change what the closure inherits. This
# used to miss the `let`/`var` form entirely (found by its own pytest).
TASK = re.compile(
    r"^\s*(?:(?:let|var)\s+\w+\s*(?::[^=]+)?=\s*|\w+\s*=\s*)?"
    r"Task(\.detached)?\s*(?:\([^)]*\))?\s*\{")
COMPLETION_CALL = re.compile(
    r"\b(?:completion|callback|completionHandler)\s*\??\s*\(|\bcompletionBox\.call\s*\??\s*\("
)
MAIN = re.compile(r"@MainActor|MainActor\.run|MainActor\.assumeIsolated|DispatchQueue\.main")


def die(msg: str) -> "NoReturn":  # type: ignore[valid-type]
    print(f"error: {msg}", file=sys.stderr)
    raise SystemExit(2)


def _annotation_block(lines: list[str], idx: int) -> str:
    """The attribute lines immediately above `idx`, which is where @MainActor lives."""
    out = []
    j = idx - 1
    while j >= 0 and lines[j].strip().startswith("@"):
        out.append(lines[j])
        j -= 1
    return "\n".join(out)


def check_file(path: str, rel: str) -> list[str]:
    try:
        lines = open(path, encoding="utf-8", errors="replace").read().splitlines()
    except OSError as exc:
        return [f"{rel}: could not read ({exc})"]

    problems: list[str] = []
    type_is_main = False       # enclosing type / extension is @MainActor
    func_is_main = False       # this func is itself @MainActor
    current_func: str | None = None
    task_line: int | None = None
    task_detached = False
    task_indent = 0

    for i, raw in enumerate(lines):
        line = raw.rstrip()
        stripped = line.strip()
        indent = len(line) - len(line.lstrip())

        d = DECL.match(line)
        if d and indent == 0:
            head = line + "\n" + _annotation_block(lines, i)
            type_is_main = "@MainActor" in head
            current_func, task_line = None, None

        f = FUNC.match(line)
        if f:
            current_func = f.group(1)
            head = line + "\n" + _annotation_block(lines, i)
            func_is_main = "@MainActor" in head
            task_line = None

        if TASK.match(line):
            task_detached = bool(TASK.match(line).group(1))
            # A Task pinned to the main actor at the declaration is fine.
            task_line = None if MAIN.search(line) else i
            task_indent = indent
            continue

        if task_line is not None and stripped.startswith("}") and indent <= task_indent:
            task_line = None
            continue

        if task_line is None or current_func is None:
            continue

        # A plain `Task { }` inherits the enclosing isolation. If that isolation is
        # the main actor, the completion is already delivered on main. `Task.detached`
        # inherits nothing, so it is unsafe no matter where it appears.
        inherits_main = (type_is_main or func_is_main) and not task_detached
        if inherits_main:
            continue

        if COMPLETION_CALL.search(line) and not MAIN.search(line):
            if f"{rel}:{current_func}" in EXEMPT:
                continue
            body = "\n".join(lines[task_line:i + 1])
            if MAIN.search(body):
                continue
            kind = "Task.detached" if task_detached else "Task"
            problems.append(
                f"{rel}:{i + 1}: `{stripped[:52]}` runs in a {kind} inside "
                f"`{current_func}`, which is not main-actor isolated, so the completion "
                f"is delivered off the main actor. If any caller is @MainActor its "
                f"closure TRAPS the process here (PP-4955). Either annotate the "
                f"declaration @MainActor or wrap the call: `await MainActor.run {{ … }}`."
            )
    return problems


def swift_files(paths: list[str]) -> list[str]:
    if paths:
        return paths
    try:
        out = subprocess.run(
            ["git", "-C", REPO, "ls-files", "-z", "Palace/*.swift"],
            capture_output=True, check=True,
        ).stdout.decode("utf-8", "replace")
        return sorted(os.path.join(REPO, p) for p in out.split("\0") if p)
    except (OSError, subprocess.CalledProcessError) as exc:
        die(f"could not list tracked files via git ({exc})")


def main(argv: list[str]) -> int:
    for arg in argv[1:]:
        if arg.startswith("-"):
            die(f"unknown option {arg!r}; this check takes file paths or nothing")

    files = swift_files(argv[1:])
    if not files:
        die("no Swift files to check; expected tracked files under Palace/")

    problems: list[str] = []
    for path in files:
        problems.extend(check_file(path, os.path.relpath(path, REPO)))

    if problems:
        print(f"{len(problems)} completion(s) delivered off the main actor:\n")
        for p in problems:
            print(f"  {p}")
        print(
            "\nSwift does not warn about this. At runtime a @MainActor caller's closure "
            "invoked off the main actor fails an isolation assertion and the process is "
            "killed outright — no error, no unwinding, no saved reading position."
        )
        return 1

    print(f"ok: {len(files)} file(s); no completion is delivered off the main actor")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
