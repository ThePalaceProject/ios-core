#!/usr/bin/env python3
"""
check-override-drops-base-state.py — an override that replaces a base method
wholesale must not silently drop the STATE that method maintained.

Catches the FIRST of the two PP-5205 omissions: an override that never touches the
property at all. It does NOT catch the second — a set without a matching clear —
because "assigned somewhere" is satisfied by the set alone. See LIMIT below; the
area checklist's trap 13 is the guard for that half.

`OpenAccessPlayer.playCallback(at:completion:)` both SETS `queuedTrackPosition`
(so `currentTrackPosition` can report where a seek is going) and CLEARS it when the
seek lands. `LCPStreamingPlayer` overrides that method wholesale. The first version
of the override did neither, so every position-derived label fell through to the
previous track. The fix added the set and not the clear, so a seek WITHIN the
current track froze the reported position — and with it the SAVED position, which
is lost progress and lost bookmarks.

Both omissions have one shape: the override reimplements the method and the base's
state bookkeeping is invisible at the override's call site. Nothing in the type
system, the tests, or mutation can see it — a property that is never assigned has
no line to mutate.

PREDICATE. For every `override func NAME` in a class whose superclass this scan can
also see:

  1. Find the superclass's own `func NAME`.
  2. Collect the stored properties of the superclass that the BASE body assigns.
  3. Keep only those READ elsewhere in the superclass — live state the class acts
     on, not a write-only field or a local.
  4. Require the override body to assign each one somewhere.

Step 3 is what keeps this usable. Without it every override that skips an
incidental assignment is a finding; with it the check is about state the base class
demonstrably depends on.

LIMIT, stated so a clean run is not over-read: this is line-based, not an AST. It
sees `self.x =` and `x =` and nothing cleverer — an override that maintains the
property through a helper method reads as a miss, and one that assigns it to the
wrong value reads as a pass. It answers "was this state considered", never "was it
handled correctly".

ESCAPE HATCH: `// no-override-state: <reason>` on the `override func` line itself.
Deliberately line-adjacent: a marker on a preceding comment line is silently ignored
by several linters in this repo, which produces an annotation that looks applied and
is not.

Exit 0 clean, 1 on violations, 2 on usage error.
"""
from __future__ import annotations
import re
import sys
import pathlib

DEFAULT_ROOTS = ("ios-audiobooktoolkit/PalaceAudiobookToolkit/Player",)

# The inheritance clause is OPTIONAL. A base class declared `class Foo {` was
# invisible to the first version of this regex, so every subclass of it was skipped
# for want of a base — the detector reporting a clean run because it could not see
# the thing it was checking. Found by a fixture, not by the tree, where the real
# base happens to inherit.
CLASS_RE = re.compile(r"^\s*(?:public\s+|internal\s+|final\s+|open\s+)*class\s+(\w+)\s*(?::\s*([\w\s,]+?)\s*)?\{")
FUNC_RE = re.compile(r"^(\s*)((?:@\w+\s+)*(?:public\s+|internal\s+|private\s+|fileprivate\s+|open\s+|final\s+|override\s+|discardableResult\s+)*)func\s+(\w+)\s*(?P<tail>[\(<].*)$")

# Comments are stripped before EVERY textual test, including the `super.` exemption.
# They were not, at first: `// super.playCallback(...)` in a doc comment exempted the
# method — an escape hatch nobody wrote, in the detector built to stop a silent pass.
def strip_comment(line: str) -> str:
    return line.split("//", 1)[0]


def param_arity(tail: str) -> int:
    """Number of top-level parameters, so `play()` and `play(at:completion:)` are
    different keys. Overloads collapsing to whichever came last in the file meant a
    future `override func play` would be compared against the wrong base body and
    silently pass — `OpenAccessPlayer` already has two `play` definitions."""
    start = tail.find("(")
    if start < 0:
        return -1
    depth = 0
    inner = ""
    for ch in tail[start:]:
        if ch in "([<":
            depth += 1
            if depth == 1:
                continue
        elif ch in ")]>":
            depth -= 1
            if depth == 0:
                break
        if depth >= 1:
            inner += ch
    inner = inner.strip()
    if not inner:
        return 0
    depth = 0
    count = 1
    for ch in inner:
        if ch in "([<":
            depth += 1
        elif ch in ")]>":
            depth -= 1
        elif ch == "," and depth == 0:
            count += 1
    return count
# `= <initialiser>` is allowed; `{` (a computed property or an observer) is not.
# The first version required the line to END after the type, so every
# `var isLoaded: Bool = false` was invisible — a whole category of live state the
# detector silently did not check.
STORED_PROP_RE = re.compile(r"^\s*(?:public\s+|internal\s+|private\s+|fileprivate\s+|open\s+)*var\s+(\w+)\s*:\s*[^={]+(?:=[^{]*)?$")
ESCAPE = re.compile(r"//\s*no-override-state\s*:")

BASELINE_NAME = "override-drops-base-state-baseline.txt"


def load_baseline(script_dir: pathlib.Path) -> set[str]:
    """Pre-existing findings, amnestied so the gate can land without a same-day
    refactor of unrelated code. Keyed on `<Class>.<method>:<property>` and NOT on a
    line number, so an unrelated edit above them does not churn the file."""
    f = script_dir / BASELINE_NAME
    if not f.exists():
        return set()
    out = set()
    for line in f.read_text().splitlines():
        line = line.split("#", 1)[0].strip()
        if line:
            out.add(line)
    return out


def body_range(lines: list[str], start: int) -> tuple[int, int]:
    """Return (first_line, last_line) inclusive of the brace-delimited body whose
    opening brace is at or after `start`. Naive brace counting; string literals with
    unbalanced braces would confuse it, which no Swift in these files has."""
    depth = 0
    opened = False
    for i in range(start, len(lines)):
        line = lines[i]
        # strip line comments so a `}` in prose does not count
        code = line.split("//", 1)[0]
        for ch in code:
            if ch == "{":
                depth += 1
                opened = True
            elif ch == "}":
                depth -= 1
                if opened and depth == 0:
                    return (start, i)
        if opened and depth <= 0:
            return (start, i)
    return (start, len(lines) - 1)


def parse_file(path: pathlib.Path):
    """-> (classes, funcs) where classes maps name -> superclass, and funcs maps
    (class, funcname) -> (is_override, first, last, header_line_index)."""
    lines = path.read_text(errors="replace").splitlines()
    classes: dict[str, str] = {}
    funcs: dict[tuple[str, str], tuple[bool, int, int, int]] = {}
    class_spans: list[tuple[str, int, int]] = []

    for i, line in enumerate(lines):
        m = CLASS_RE.match(line)
        if m:
            name = m.group(1)
            inherits = [x.strip() for x in (m.group(2) or "").split(",") if x.strip()]
            classes[name] = inherits[0] if inherits else ""
            first, last = body_range(lines, i)
            class_spans.append((name, first, last))

    for i, line in enumerate(lines):
        m = FUNC_RE.match(line)
        if not m:
            continue
        modifiers, fname = m.group(2), m.group(3)
        arity = param_arity(m.group("tail"))
        owner = ""
        for cname, cfirst, clast in class_spans:
            if cfirst <= i <= clast:
                owner = cname
        if not owner:
            continue
        first, last = body_range(lines, i)
        funcs[(owner, fname, arity)] = ("override" in modifiers, first, last, i)
    return lines, classes, funcs, class_spans


def stored_props(lines: list[str], span: tuple[int, int]) -> set[str]:
    out = set()
    for i in range(span[0], span[1] + 1):
        m = STORED_PROP_RE.match(lines[i])
        if m:
            out.add(m.group(1))
    return out


def assigned_in(lines: list[str], first: int, last: int, names: set[str]) -> set[str]:
    out = set()
    for i in range(first, last + 1):
        code = lines[i].split("//", 1)[0]
        for n in names:
            if re.search(r"(?:^|[^\w.])(?:self\?\.|self\.)?" + re.escape(n)
                         + r"\s*(?:[-+*/%|&^]|<<|>>)?=(?!=)", code):
                out.add(n)
    return out


def read_outside(lines: list[str], span: tuple[int, int], skip: tuple[int, int], names: set[str]) -> set[str]:
    out = set()
    for i in range(span[0], span[1] + 1):
        if skip[0] <= i <= skip[1]:
            continue
        code = strip_comment(lines[i])
        # A property's own DECLARATION is not a read of it. Counting it as one made
        # every stored property "live", which surfaced the moment declarations with
        # an initialiser became visible at all: a write-only field was reported as
        # state the override had dropped.
        if STORED_PROP_RE.match(code):
            continue
        for n in names:
            # a READ: the name appears not immediately followed by `=`
            for m in re.finditer(r"(?:^|[^\w.])(?:self\?\.|self\.)?" + re.escape(n) + r"\b", code):
                tail = code[m.end():].lstrip()
                if not tail.startswith("=") or tail.startswith("=="):
                    out.add(n)
    return out


def main(argv: list[str]) -> int:
    root = pathlib.Path(argv[1]) if len(argv) > 1 else pathlib.Path(".")
    roots = [root / r for r in DEFAULT_ROOTS]
    present = [r for r in roots if r.exists()]
    if not present:
        # LOUD skip. An absent submodule must never render as a clean run.
        print("[override-drops-base-state] SKIP — none of the scanned roots exist under "
              f"{root}: {', '.join(str(r) for r in roots)}")
        print("[override-drops-base-state] This is NOT a pass. The toolkit submodule is "
              "probably not checked out.")
        return 0

    files = sorted(f for r in present for f in r.rglob("*.swift"))
    parsed = {f: parse_file(f) for f in files}

    # class name -> (file, span)
    where: dict[str, tuple[pathlib.Path, tuple[int, int]]] = {}
    for f, (lines, classes, funcs, spans) in parsed.items():
        for cname, cfirst, clast in spans:
            where[cname] = (f, (cfirst, clast))

    violations: list[tuple[pathlib.Path, int, str, str, str]] = []

    for f, (lines, classes, funcs, spans) in parsed.items():
        for (owner, fname, arity), (is_override, first, last, header) in funcs.items():
            if not is_override:
                continue
            if ESCAPE.search(lines[header]):
                continue
            # An override that DELEGATES still gets the base's bookkeeping. This is
            # not a nicety: without it the check fires on every `super.x()` wrapper in
            # the tree and would be tuned away rather than fixed. The class this
            # detector exists for is the override that replaces the method WHOLESALE.
            if re.search(r"\bsuper\." + re.escape(fname) + r"\s*[\(<]",
                         "\n".join(strip_comment(l) for l in lines[first:last + 1])):
                continue
            base = classes.get(owner, "")
            if not base or base not in where:
                continue
            bfile, bspan = where[base]
            blines, bclasses, bfuncs, bspans = parsed[bfile]
            bkey = (base, fname, arity)
            if bkey not in bfuncs:
                continue
            _, bfirst, blast, _ = bfuncs[bkey]
            props = stored_props(blines, bspan)
            if not props:
                continue
            base_assigns = assigned_in(blines, bfirst, blast, props)
            if not base_assigns:
                continue
            live = base_assigns & read_outside(blines, bspan, (bfirst, blast), base_assigns)
            if not live:
                continue
            over_assigns = assigned_in(lines, first, last, live)
            missing = sorted(live - over_assigns)
            for name in missing:
                violations.append((f.relative_to(root), header + 1, owner, fname, name))

    baseline = load_baseline(pathlib.Path(__file__).resolve().parent)
    seen = {f"{owner}.{fname}:{prop}" for _, _, owner, fname, prop in violations}
    new_findings = [v for v in violations if f"{v[2]}.{v[3]}:{v[4]}" not in baseline]
    # A baseline entry that no longer fires is an amnesty that has gone stale. Failing
    # on it is what stops the file growing quietly into a permanent exemption list.
    resolved = sorted(baseline - seen)

    if not new_findings and not resolved:
        print("[override-drops-base-state] OK — every override assigns the live base state its "
              f"base method maintained ({len(baseline)} baselined, 0 new).")
        print("[override-drops-base-state] NOTE: line-based, not an AST. It answers 'was this "
              "state considered', never 'was it handled correctly'.")
        return 0

    if resolved:
        print("[override-drops-base-state] FAIL: a baselined finding no longer fires — remove it "
              f"from scripts/{BASELINE_NAME}:\n")
        for entry in resolved:
            print(f"  {entry}")
        if new_findings:
            print()

    if not new_findings:
        return 1

    print("[override-drops-base-state] FAIL: an override drops state its base method maintained.\n")
    for f, ln, owner, fname, prop in new_findings:
        print(f"  {f}:{ln}  {owner}.{fname} does not assign `{prop}`, which the base does")
    print(
        "\nThe base method both maintains this property and the class READS it elsewhere, so"
        "\nan override that replaces the method wholesale leaves it stale for the rest of the"
        "\nsession. In PP-5205 that property was `queuedTrackPosition`: dropping the SET made"
        "\nevery position label show the previous track, and then dropping the CLEAR froze the"
        "\nreported — and SAVED — position on a seek within the current track."
        "\n\nAssign it in the override, or, if the override genuinely does not need it,"
        "\nannotate the `override func` line itself: // no-override-state: <reason>"
    )
    return 1


if __name__ == "__main__":
    sys.exit(main(sys.argv))
