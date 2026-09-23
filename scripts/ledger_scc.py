#!/usr/bin/env python3
"""
ledger_scc.py — collapse CodeAtlas Ledger's cycle-PATH enumeration into the
distinct dependency cycles it actually represents.

WHY THIS EXISTS
---------------
`ledger observe --domains arch` reports a "Dependency Cycles" count that
enumerates cycle PATHS through the dependency graph, not distinct cycles. On
develop that reads as 36 cycles:

    Accounts → Book → Accounts
    Accounts → Book → Audiobooks → Accounts
    Accounts → Book → Audiobooks → ErrorHandling → Accounts
    Accounts → Book → Audiobooks → ErrorHandling → Logging → Accounts
    ...

Every line is a different walk through the SAME tangle. Collapsed to
strongly-connected components it is 2 cycles — a 17-component core and a
2-component pair — and one of those two is an edge SwiftPM structurally
forbids (see --config below), so the actionable answer is 1.

Path count in a dense SCC is combinatorial, which makes it useless as a trend:
across 46 PRs (2026-07-23 → 2026-08-18) it ranged 10..29 with a same-day
spread of 10..19, while components and average coupling held constant. SCC
count and largest-SCC size move only when a component genuinely enters or
leaves a tangle, which is what the decomposition campaign is actually doing.

The input `.issues[]` entries are the ONLY place the detail lives —
`.cycles` is an integer and `.findings` is empty. `ledger.yml` previously read
`jq '.cycles[] | .components'`, which errors on an integer, so every PR
comment fell through to "See full report for cycle details."

USAGE
-----
    ledger_scc.py --analysis artifacts/ledger/observe/latest/arch/analysis.json \
                  [--config tools/ledger/ledger-config.json] \
                  [--json out.json] [--markdown out.md]

Writes GitHub-flavored markdown to stdout unless --markdown is given.
Exit 0 on success (including "no cycles"), 2 on a missing/unreadable input —
a broken input must not be reported as a clean architecture.
"""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

_CYCLE_TYPE = "dependency_cycle"
_PREFIX = "Dependency cycle detected: "
_ARROW = "→"


# ────────────────────────────────── parsing ──────────────────────────────────
def parse_paths(issues: list[dict]) -> tuple[list[list[str]], int]:
    """Extract ordered component paths from dependency_cycle issues.

    Returns (paths, unparsed_count). A path is closed — its last element is
    the same component as its first — so consecutive pairs cover every edge
    including the one that closes the loop.

    Falls back to the issue's `components` list when the description does not
    carry an arrow-joined path (upstream format drift): the analyzer has
    already asserted those components form a cycle, so treating them as a ring
    preserves the SCC membership even if the exact edges are lost.
    """
    paths: list[list[str]] = []
    unparsed = 0
    for issue in issues:
        if issue.get("type") != _CYCLE_TYPE:
            continue
        desc = issue.get("description", "")
        body = desc[len(_PREFIX):] if desc.startswith(_PREFIX) else desc
        if _ARROW in body:
            nodes = [n.strip() for n in body.split(_ARROW) if n.strip()]
        else:
            nodes = [str(c).strip() for c in issue.get("components", []) if str(c).strip()]
            if not nodes:
                continue
            unparsed += 1
            nodes = nodes + [nodes[0]]  # close the ring
        if len(nodes) == 1:
            nodes = nodes * 2  # a self-loop is written "A → A"; tolerate "A"
        paths.append(nodes)
    return paths, unparsed


def load_discounts(config_path: Path | None) -> list[tuple[str, str]]:
    """Read `knownFalsePositiveEdges` — edges the config declares impossible.

    Each entry names a `from` and a `to`, plus an optional `aka` for the
    component name the analyzer actually emits (a SwiftPM package and its
    target are two different names for one thing). Both spellings are honored
    so the entry matches whichever the analyzer produced.
    """
    if config_path is None:
        return []
    try:
        cfg = json.loads(config_path.read_text())
    except (OSError, json.JSONDecodeError):
        return []
    pairs: list[tuple[str, str]] = []
    for e in cfg.get("knownFalsePositiveEdges", []) or []:
        to = (e.get("to") or "").strip()
        if not to:
            continue
        for src in (e.get("from"), e.get("aka")):
            if src and (src.strip(), to) not in pairs:
                pairs.append((src.strip(), to))
    return pairs


# ──────────────────────────────────── SCC ────────────────────────────────────
def tarjan(nodes: list[str], adj: dict[str, list[str]]) -> list[list[str]]:
    """Iterative Tarjan. Iterative because a 17-node tangle today is a deeper
    one tomorrow, and a RecursionError in CI would read as "no cycles"."""
    index: dict[str, int] = {}
    low: dict[str, int] = {}
    on_stack: dict[str, bool] = {}
    stack: list[str] = []
    counter = 0
    out: list[list[str]] = []

    for root in nodes:
        if root in index:
            continue
        work = [(root, 0)]
        while work:
            v, pi = work[-1]
            if pi == 0:
                index[v] = low[v] = counter
                counter += 1
                stack.append(v)
                on_stack[v] = True
            recursed = False
            neighbors = adj.get(v, [])
            for i in range(pi, len(neighbors)):
                w = neighbors[i]
                if w not in index:
                    work[-1] = (v, i + 1)
                    work.append((w, 0))
                    recursed = True
                    break
                if on_stack.get(w):
                    low[v] = min(low[v], index[w])
            if recursed:
                continue
            if low[v] == index[v]:
                comp = []
                while True:
                    w = stack.pop()
                    on_stack[w] = False
                    comp.append(w)
                    if w == v:
                        break
                out.append(sorted(comp))
            work.pop()
            if work:
                u = work[-1][0]
                low[u] = min(low[u], low[v])
    return out


def analyze(analysis: dict, discounts: list[tuple[str, str]]) -> dict:
    paths, unparsed = parse_paths(analysis.get("issues", []) or [])

    edges: set[tuple[str, str]] = set()
    for nodes in paths:
        for a, b in zip(nodes, nodes[1:]):
            edges.add((a, b))

    discount_set = set(discounts)
    dropped = sorted(edges & discount_set)
    edges -= discount_set

    nodes = sorted({n for e in edges for n in e})
    adj: dict[str, list[str]] = {n: [] for n in nodes}
    for a, b in edges:
        adj[a].append(b)

    self_loops = {a for a, b in edges if a == b}
    sccs = [
        c for c in tarjan(nodes, adj)
        if len(c) > 1 or (len(c) == 1 and c[0] in self_loops)
    ]
    sccs.sort(key=lambda c: (-len(c), c[0]))

    members = {n for c in sccs for n in c}
    detail = []
    for c in sccs:
        inside = sorted((a, b) for a, b in edges if a in c and b in c)
        detail.append({
            "size": len(c),
            "components": c,
            "edges": [{"from": a, "to": b} for a, b in inside],
        })

    return {
        "cyclePathCount": len(paths),
        "unparsedPaths": unparsed,
        "sccCount": len(sccs),
        "largestSccSize": max((len(c) for c in sccs), default=0),
        "componentsInCycles": len(members),
        "edgesInCycles": sum(len(d["edges"]) for d in detail),
        "sccs": detail,
        "discountedEdges": [{"from": a, "to": b} for a, b in dropped],
    }


# ────────────────────────────────── rendering ────────────────────────────────
def render(summary: dict) -> str:
    paths = summary["cyclePathCount"]
    n = summary["sccCount"]

    if n == 0:
        if paths:
            return (
                "No dependency cycles remain after discounting edges the project "
                "config declares structurally impossible.\n"
            )
        return "No dependency cycles.\n"

    lines: list[str] = []
    noun = "cycle" if n == 1 else "cycles"
    lines.append(
        f"**{n} distinct dependency {noun}** "
        f"(largest spans **{summary['largestSccSize']}** components).\n"
    )
    if paths > n:
        lines.append(
            f"> The analyzer reports **{paths}** entries — those are cycle *paths* "
            f"through the {noun} listed below, not {paths} separate problems. Adding "
            f"one edge inside a tangle multiplies the path count without changing the "
            f"architecture, so track the {noun} instead.\n"
        )
    lines.append("")

    for i, scc in enumerate(summary["sccs"], 1):
        if scc["size"] == 1:
            head = f"**Cycle {i}** — `{scc['components'][0]}` depends on itself"
        else:
            head = (
                f"**Cycle {i}** — {scc['size']} components, "
                f"{len(scc['edges'])} edges between them"
            )
        lines.append(head)
        lines.append("")
        lines.append("> " + ", ".join(f"`{c}`" for c in scc["components"]))
        lines.append("")
        lines.append("<details><summary>edges</summary>\n")
        lines.append("```")
        for e in scc["edges"]:
            lines.append(f"{e['from']} → {e['to']}")
        lines.append("```")
        lines.append("</details>")
        lines.append("")

    if summary["discountedEdges"]:
        pretty = ", ".join(f"`{e['from']} → {e['to']}`" for e in summary["discountedEdges"])
        lines.append(
            f"_Discounted {pretty} — declared a known false positive in "
            f"`tools/ledger/ledger-config.json`._\n"
        )
    return "\n".join(lines)


# ──────────────────────────────────── main ───────────────────────────────────
def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(
        description="Collapse Ledger cycle paths into distinct dependency cycles (SCCs).",
    )
    ap.add_argument("--analysis", required=True, type=Path,
                    help="path to arch/analysis.json from `ledger observe`")
    ap.add_argument("--config", type=Path, default=None,
                    help="path to ledger-config.json (reads knownFalsePositiveEdges)")
    ap.add_argument("--json", dest="json_out", type=Path, default=None,
                    help="write the machine-readable summary here")
    ap.add_argument("--markdown", dest="md_out", type=Path, default=None,
                    help="write the PR-comment markdown here (default: stdout)")
    args = ap.parse_args(argv)

    if not args.analysis.is_file():
        print(f"error: analysis file not found: {args.analysis}", file=sys.stderr)
        return 2
    try:
        doc = json.loads(args.analysis.read_text())
    except (OSError, json.JSONDecodeError) as exc:
        print(f"error: could not read {args.analysis}: {exc}", file=sys.stderr)
        return 2

    summary = analyze(doc, load_discounts(args.config))
    body = render(summary)

    if args.json_out:
        args.json_out.write_text(json.dumps(summary, indent=2) + "\n")
    if args.md_out:
        args.md_out.write_text(body)
    else:
        sys.stdout.write(body)
    return 0


if __name__ == "__main__":
    sys.exit(main())
