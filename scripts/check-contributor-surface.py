#!/usr/bin/env python3
r"""
check-contributor-surface.py — keep the contributor-facing surface clean + safe.

Two independent checks, both aimed at the experience of someone who clones this
repo WITHOUT the maintainer's private local tooling (the harness, ForgeOS,
simdrive, the swarm skills). That tooling lives outside the repo on purpose; the
committed files must not (a) leak references to it into the contributor-facing
docs, or (b) hard-depend on it at runtime so a clean clone breaks.

    CHECK A — leak guard
        The contributor-facing doc(s) (default: CLAUDE.md) must not reintroduce
        references to private, maintainer-only tooling. Those belong in the
        git-ignored CLAUDE.local.md, not the tracked file every contributor
        reads. This is what stops CLAUDE.md from slowly re-accreting the
        governance apparatus we just moved out.

    CHECK B — clean-clone hook safety
        Every hook command in .claude/settings.json that invokes a script under
        the git-ignored scripts/hooks/ directory (a per-machine symlink into the
        private harness, ABSENT on a clean clone) must be guarded so a missing
        script is a silent no-op. Without the guard, every Claude Code hook fires
        "No such file or directory" on a clean clone and the tool is unusable.
        This locks in the fix from the clean-clone-safety PR.

Exit 0 = clean. Exit 1 = violation(s) found (printed with file:line + guidance).

Per-line opt-out for CHECK A: append an HTML comment containing `leak-ok` to the
offending line (e.g. `... <!-- leak-ok: explains the opt-in boundary -->`). Use
sparingly and only for a reference that is genuinely safe/necessary for
contributors to see.

Usage:
    python3 scripts/check-contributor-surface.py                 # repo defaults
    python3 scripts/check-contributor-surface.py --docs CLAUDE.md README.md
    python3 scripts/check-contributor-surface.py --settings path/to/settings.json
    python3 scripts/check-contributor-surface.py --root /path/to/repo
"""
from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path

# CHECK A denylist: (compiled regex, human label). Case-insensitive. These are
# markers of private, maintainer-only tooling that a clean clone does not have.
# Keep this list specific — false positives erode trust in the gate.
_DENY = [
    (r"~/harness\b", "harness home path (~/harness)"),
    (r"\bbin/harness\b", "harness CLI (bin/harness)"),
    (r"/harness/(?:core|bin|projects)\b", "harness internals path"),
    (r"\bforgeos\b", "ForgeOS governance tooling"),
    (r"\bFORGEOS_[A-Z_]+", "ForgeOS env var"),
    (r"forgeos-api\.synctek", "ForgeOS API host"),
    (r"\bmcp__forgeos__", "ForgeOS MCP tool"),
    (r"\bmcp__simdrive__", "simdrive MCP tool"),
    (r"\bsimdrive\b", "simdrive (private UI-driver tooling)"),
    (r"\bSpecterQA\b", "SpecterQA (deprecated private tooling)"),
    (r"(?<![\w-])/(?:swarm|forge-review|rigorous-fix|intent)\b",
     "private maintainer skill invocation"),
    (r"\.forgeos/", "private .forgeos/ path"),
    (r"\.simdrive/", "private .simdrive/ path"),
]
_DENY = [(re.compile(pat, re.IGNORECASE), label) for pat, label in _DENY]

_LEAK_OK = re.compile(r"leak-ok", re.IGNORECASE)

# CHECK B: a hook command that references this path prefix depends on a script
# that is git-ignored (scripts/hooks is a symlink into the harness) and thus
# absent on a clean clone.
_GITIGNORED_HOOK_PREFIX = "scripts/hooks/"

# A command is considered guarded if it tolerates the script being absent.
_GUARD_MARKERS = ("[ -e ", "[ -x ", "[ -f ", "|| exit 0", "|| true")


def check_docs(doc_paths: list[Path]) -> list[str]:
    """CHECK A — private-tooling leak guard over contributor-facing docs."""
    violations: list[str] = []
    for path in doc_paths:
        if not path.exists():
            continue  # a doc we don't ship is not a leak
        for lineno, line in enumerate(path.read_text().splitlines(), start=1):
            if _LEAK_OK.search(line):
                continue
            for pat, label in _DENY:
                m = pat.search(line)
                if m:
                    violations.append(
                        f"{path}:{lineno}: leaks {label} "
                        f"(matched {m.group(0)!r})"
                    )
                    break  # one finding per line is enough
    return violations


def _iter_hook_commands(settings: dict):
    """Yield every hook command string in a Claude Code settings.json."""
    for _event, groups in (settings.get("hooks") or {}).items():
        for group in groups or []:
            for hook in group.get("hooks") or []:
                cmd = hook.get("command")
                if isinstance(cmd, str):
                    yield cmd


def check_settings(settings_path: Path) -> list[str]:
    """CHECK B — clean-clone safety of hooks pointing at git-ignored scripts."""
    if not settings_path.exists():
        return []
    try:
        settings = json.loads(settings_path.read_text())
    except json.JSONDecodeError as exc:
        return [f"{settings_path}: not valid JSON ({exc})"]

    violations: list[str] = []
    for cmd in _iter_hook_commands(settings):
        if _GITIGNORED_HOOK_PREFIX not in cmd:
            continue
        if not any(marker in cmd for marker in _GUARD_MARKERS):
            violations.append(
                f"{settings_path}: unguarded hook command depends on "
                f"git-ignored {_GITIGNORED_HOOK_PREFIX} (breaks a clean clone): "
                f"{cmd!r}"
            )
    return violations


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", default=".", help="repo root (default: cwd)")
    parser.add_argument(
        "--docs", nargs="*", default=None,
        help="contributor-facing docs to leak-check (default: CLAUDE.md)",
    )
    parser.add_argument(
        "--settings", default=None,
        help="path to Claude settings.json (default: .claude/settings.json)",
    )
    args = parser.parse_args(argv)

    root = Path(args.root)
    doc_paths = [root / d for d in (args.docs or ["CLAUDE.md"])]
    settings_path = (
        Path(args.settings) if args.settings
        else root / ".claude" / "settings.json"
    )

    violations = check_docs(doc_paths) + check_settings(settings_path)

    if violations:
        print("Contributor-surface check FAILED:\n", file=sys.stderr)
        for v in violations:
            print(f"  - {v}", file=sys.stderr)
        print(
            "\nMove maintainer/private-tooling guidance into the git-ignored "
            "CLAUDE.local.md, guard clean-clone-absent hooks with "
            "`[ -e <script> ] || exit 0`, or append `<!-- leak-ok -->` to a "
            "doc line that is intentionally safe to expose.",
            file=sys.stderr,
        )
        return 1

    print("Contributor-surface check passed: no private-tooling leaks, "
          "all clean-clone-absent hooks guarded.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
