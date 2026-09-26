#!/usr/bin/env python3
"""Print the `run:` bodies of GitHub-workflow steps that can actually fail a build.

prior-art-checked: no existing script in scripts/ parses workflow steps; the
repo's other workflow-aware checks grep the YAML text, which is precisely the
approach this replaces. `harness capabilities` has nothing for workflow parsing.

WHY NOT PyYAML
    The first version imported yaml. `/usr/bin/python3` on macOS has no PyYAML,
    so any run with a restricted PATH -- a git hook, verify-pr.sh on a fresh
    checkout, an outside contributor who never pip-installed anything -- got
    exit 2 from a gate that had nothing to say about their tree. CLAUDE.md
    requires verify-pr.sh to run unaided, so the dependency had to go. This
    parses the narrow shape it actually needs, with the standard library only.

WHY "EFFECTIVE" IS THE QUESTION
    A grep over workflow text answers "does this string appear". The question a
    wiring gate asks is "will this run AND can it fail the build", and three
    shapes separate those, all of them normal in this repo's workflows:

        continue-on-error: true   runs, cannot redden the board
        if: false                 never runs
        echo "swift test ..."     prints the command (handled by the caller)

THE TWO DEFAULTS POINT OPPOSITE WAYS, DELIBERATELY
    `if:` with an expression is treated as EFFECTIVE. Guessing that a
    `${{ ... }}` condition is false would silently drop real coverage and redden
    a correctly wired tree, which is how a gate gets switched off.

    `continue-on-error:` with an expression is treated as INEFFECTIVE. Here the
    unsafe direction is reversed: an expression that evaluates true means the
    step cannot fail the build, and a gate that reports such a step as
    enforcement is making exactly the false-green claim it exists to prevent.
    False red is survivable; false green is the defect.

SCOPE — THE QUESTION THIS ANSWERS, AND THE ONE IT DOES NOT

    It answers: "does an effective step invoke `swift test --package-path <pkg>`".
    It does NOT answer: "parse this workflow".

    The distinction is the difference between a bounded job and an unbounded
    one, and it is written here because nine review rounds demonstrated the
    cost. Each round found a real YAML shape this missed — job-level keys, keys
    ordered after `steps:`, quoted job ids, four-space indentation, a banner
    comment above a job, a comment between a step's `run:` and a sibling key.
    Every one was a genuine defect and every one was fixed. The supply is not
    exhausted, because approximating a parser by example has no natural end.

    So the bound is declared rather than discovered: this reads the shapes that
    occur in THIS repository's workflows, which are checked by
    `test_the_gates_own_workflow_yields_its_exact_run_count` against the file
    the gate actually consumes. A newly-invented shape that no workflow here
    uses is a gap in an approximation, not a defect in a gate — worth fixing if
    it is cheap, not worth another round if it is not.

    The honest alternative was PyYAML, which would delete most of this file.
    It was rejected because /usr/bin/python3 does not have it and CLAUDE.md
    requires verify-pr.sh to run unaided; that trade bought portability and
    costs edge cases, and both halves of it should be visible to whoever reads
    this next.

WHAT THIS DOES NOT DO, STATED PLAINLY
    It does not validate YAML, and it therefore CANNOT fail closed on malformed
    input. An earlier version of this module claimed it could. Measured
    refutation: a file PyYAML rejects (an unterminated quoted scalar) still
    yields its `run:` bodies here, because a line-regex scanner has no parse
    step to fail. A malformed workflow is reported as wired, not as broken.

    The compensating control is GitHub's own parser: a workflow it cannot parse
    does not run at all, so "malformed" is not a state in which this gate's
    answer decides anything. That is an honest answer; "fail-closed" was not.

Exit: 0 printed the effective run bodies - 2 there is no steps: key at all.
"""
import re
import sys

STEP_RE = re.compile(r"^(?P<indent>\s*)-\s+(?P<rest>\S.*)$")
KEY_RE = re.compile(
    r"^(?P<indent>\s*)(?P<q>[\"']?)(?P<key>[A-Za-z_][\w-]*)(?P=q)\s*:\s?(?P<value>.*)$"
)


def _skippable(stripped: str) -> bool:
    """Blank or comment — carries no YAML structure.

    ONE definition, called from every loop that walks lines. Three loops make
    boundary decisions here and comments were patched into them one at a time
    across three review rounds, each patch leaving the others wrong: a comment
    ended a job's key scan, then truncated a dead job's span, then made the
    `jobs:` tracker think it had left the mapping entirely. Sharing the
    predicate is what makes them agree by construction; three correct copies
    only agree by coincidence, and a fourth loop would forget again.

    `_step_blocks` deliberately does NOT use it: a comment between a step's
    `- name:` and its `run:` drops that run, which reports UNWIRED. That is
    fail-closed, the direction this module declares survivable, and changing it
    is a behaviour change rather than a consistency fix.
    """
    return not stripped or stripped.startswith("#")


def _strip_comment(value: str) -> str:
    """Drop a trailing `# ...` comment outside quotes. Good enough for the keys
    this reads (`if`, `continue-on-error`), which are never quoted strings."""
    out, quote = [], None
    for i, ch in enumerate(value):
        if quote:
            if ch == quote:
                quote = None
        elif ch in "\"'":
            quote = ch
        elif ch == "#" and (i == 0 or value[i - 1].isspace()):
            break
        out.append(ch)
    return "".join(out).strip()


def _is_literal_false(value: str) -> bool:
    return _strip_comment(value).lower() in {"false", "no", "off", "${{ false }}"}


def _job_is_ineffective(lines, job_indent, job_start):
    """Whether a job's own `if:`/`continue-on-error:` kill everything in it.

    The extractor originally read step-level keys only, so `jobs.<id>.if: false`
    and `jobs.<id>.continue-on-error: true` both still yielded their run bodies
    as enforcement. The threat model is "someone silences a flaky package step
    during an incident" — silencing the whole JOB is the same move one scope up
    and one line shorter. This repo already uses job-level `if:` 8 times and
    job-level `continue-on-error: true` once, so the shape is live.

    The two defaults carry up unchanged: an `if:` expression stays effective, a
    `continue-on-error` expression does not.
    """
    # Scan the WHOLE job block, not up to `steps:`. An earlier version broke
    # there on the reasoning that job-level keys precede steps "in practice" —
    # but YAML key order is free, and moving one line below `steps:` reopened
    # the false-green this function exists to close. Step entries are indented
    # deeper than job_indent + 2, so they are filtered by the key test below
    # rather than by where the scan stops.
    i = job_start
    key_indent = None
    while i < len(lines):
        line = lines[i]
        i += 1
        stripped = line.strip()
        # A comment carries no structure. This skip already existed in the span
        # scan and was MISSING here — the same fix, applied to one of the two
        # loops that walk a job block. A comment at or left of the job's own
        # indent (including one trailing the job id) ended the key scan, so a
        # job-level `continue-on-error: true` below it was never seen and the
        # gate returned a false green.
        if _skippable(stripped):
            continue
        indent = len(line) - len(line.lstrip())
        if indent <= job_indent:
            break                      # left this job
        m = KEY_RE.match(line)
        if not m:
            continue
        # Derive the job's key indent from its first key rather than assuming
        # job_indent + 2. A 4-space-indented workflow is legal YAML and used to
        # slip every job-level key through this filter.
        if key_indent is None:
            key_indent = len(m.group("indent"))
        if len(m.group("indent")) != key_indent:
            continue                   # nested deeper; not a job-level key
        key, value = m.group("key"), m.group("value")
        if key == "continue-on-error" and not _is_literal_false(value):
            return True
        if key == "if" and _is_literal_false(value):
            return True
    return False


def _ineffective_job_spans(lines):
    """Line ranges belonging to jobs that cannot fail the build."""
    spans, in_jobs, jobs_indent, job_level = [], False, None, None
    for i, line in enumerate(lines):
        stripped = line.strip()
        # The `jobs:` tracker. It used to treat any column-0 line as leaving the
        # mapping, comments included, so a `# ----` banner above a job switched
        # job-scope detection off for every job after it and reported a
        # `continue-on-error: true` job's steps as enforcement. That banner shape
        # is this repo's own (ledger.yml:712).
        #
        # This is one of three loops that skip via `_skippable`; see its
        # docstring for why the predicate is shared rather than repeated.
        if _skippable(stripped):
            continue
        indent = len(line) - len(line.lstrip())
        m = KEY_RE.match(line)
        if m and m.group("key") == "jobs" and indent == 0:
            in_jobs, jobs_indent, job_level = True, indent, None
            continue
        if not in_jobs:
            continue
        if indent == 0:
            in_jobs = False
            continue
        # A job id sits at the FIRST indent level under `jobs:`. Derived from the
        # first key seen there rather than assumed to be two spaces (4-space
        # workflows are legal) — and NOT simply `> jobs_indent`, which matched
        # nested keys like `steps:` as jobs and collapsed three real workflows
        # from 65/63/167 effective runs down to 1.
        if m and job_level is None and indent > jobs_indent:
            job_level = indent
        # `_strip_comment` before the emptiness test: a job id with a trailing
        # comment (`test: # the package test job`) has a non-empty value, so it
        # was not recognised as a job at all and its job-level keys were never
        # scanned — the same false green by a third route.
        if m and indent == job_level and not _strip_comment(m.group("value")):
            if _job_is_ineffective(lines, indent, i + 1):
                end = len(lines)
                for j in range(i + 1, len(lines)):
                    stripped = lines[j].strip()
                    # A comment carries no structure. A column-0 comment INSIDE a
                    # job would otherwise truncate its span and hand back the
                    # steps below as effective — and that shape is live in this
                    # repo — ledger.yml carries a column-zero comment a line past a
                    # job's content. Measured, that one is a NEAR-MISS, not an
                    # instance: skipping comments changes output for 0 of the 16
                    # workflows. The shape is reachable, not currently reached.
                    if _skippable(stripped):
                        continue
                    if len(lines[j]) - len(lines[j].lstrip()) <= indent:
                        end = j
                        break
                spans.append((i, end))
    return spans


def _step_blocks(lines):
    """Yield (key_indent, [lines]) for every `- ...` sequence item in the file.

    Not every such item is a workflow step -- a matrix entry is one too -- but a
    non-step has no `run:` key, so it contributes nothing and costs nothing.
    """
    i = 0
    while i < len(lines):
        m = STEP_RE.match(lines[i])
        if not m:
            i += 1
            continue
        start = i
        dash_indent = len(m.group("indent"))
        # The first key sits after "- ", so its column is the body indent.
        body_indent = dash_indent + (len(m.group(0)) - len(m.group("rest")) - dash_indent)
        block = [" " * body_indent + m.group("rest")]
        i += 1
        while i < len(lines):
            line = lines[i]
            stripped = line.strip()
            # The FOURTH boundary decision, and the last one still reading a
            # comment as structure. A comment left of the step's body indent
            # ended the block — so a silencing key BELOW such a comment was
            # never seen:
            #
            #     - name: Run PalaceAuth package tests
            #       run: swift test --package-path Palace/Packages/PalaceAuth
            #     # flaky during the incident, see PP-9999
            #       continue-on-error: true
            #
            # reported `ok`, exit 0. Delete the comment and the same file is
            # UNWIRED, exit 1. An earlier comment here called this omission
            # fail-CLOSED; that is true of a comment between `- name:` and
            # `run:` (which drops the run) and inverts for this ordering, which
            # is the gate's own threat model one scope below the job-level
            # banner. `_skippable` now governs all four decisions.
            #
            # SKIPPED, not appended: appending leaks comment prose into `run:`
            # bodies on 3 of the 16 workflows. Dropping them is also the right
            # answer on its own terms — a commented-out command inside a run
            # body is not an invocation.
            if _skippable(stripped):
                i += 1
                continue
            indent = len(line) - len(line.lstrip())
            if indent < body_indent or (indent == dash_indent and line.lstrip().startswith("- ")):
                break
            block.append(line)
            i += 1
        yield body_indent, block, start


def effective_runs(text: str):
    lines = text.splitlines()
    dead = _ineffective_job_spans(lines)

    def in_dead_job(index):
        return any(lo <= index < hi for lo, hi in dead)

    out = []
    for body_indent, block, block_start in _step_blocks(lines):
        if in_dead_job(block_start):
            continue
        keys = {}
        run_lines, in_run = None, False
        for line in block:
            if not line.strip():
                if in_run and run_lines is not None:
                    run_lines.append("")
                continue
            indent = len(line) - len(line.lstrip())
            km = KEY_RE.match(line)
            if km and indent == body_indent:
                in_run = False
                key, value = km.group("key"), km.group("value")
                keys[key] = value
                if key == "run":
                    in_run = True
                    run_lines = []
                    # `run: echo hi` (inline) vs `run: |` (block scalar).
                    if value.strip() and value.strip() not in {"|", ">", "|-", ">-", "|+", ">+"}:
                        run_lines.append(value)
                        in_run = False
                continue
            if in_run and run_lines is not None:
                run_lines.append(line.strip())

        if run_lines is None:
            continue
        coe = keys.get("continue-on-error")
        if coe is not None and not _is_literal_false(coe):
            continue          # true, or an expression that might be true
        cond = keys.get("if")
        if cond is not None and _is_literal_false(cond):
            continue          # provably dead; an expression is left effective
        out.extend(run_lines)
    return out


def main(argv):
    if len(argv) != 2:
        sys.stderr.write("usage: workflow_effective_runs.py <workflow.yml>\n")
        return 2
    try:
        text = open(argv[1], encoding="utf-8").read()
    except OSError as exc:
        sys.stderr.write(f"ERROR: cannot read {argv[1]}: {exc}\n")
        return 2
    if "steps:" not in text:
        sys.stderr.write(f"ERROR: {argv[1]} declares no steps: — not a workflow?\n")
        return 2
    print("\n".join(effective_runs(text)))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
