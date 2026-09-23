#!/usr/bin/env python3
"""Consolidate mined HelpSpot batches into an authoring set and a sealed holdout.

Run from anywhere; reads and writes alongside this file.

WHY THE SPLIT IS MECHANICAL. Once a ticket has been read while writing keywords
or copy, it can no longer measure whether that work generalises — it measures
whether we remembered it. So the split happens before anyone reads anything, by a
rule nobody can nudge: `id % 3 == 0` goes to the holdout. It is stable across
re-runs, verifiable by inspection, and independent of content, so it cannot drift
toward whichever tickets would flatter a score.

That stability also means a lost corpus can be reconstructed: re-mining the same
id ranges puts the same tickets in the same halves.

Only `authoring.json` may be opened while authoring catalog entries, keywords,
copy, or the per-category remedy priors. `holdout.json` stays sealed until that
work is frozen, and is then read ONCE. A second look starts spending the seal.
"""
import json, glob, os, re, collections

HERE = os.path.dirname(os.path.abspath(__file__))

def norm(t):
    """Collapse whitespace so near-identical filings compare equal."""
    return re.sub(r"\s+", " ", (t or "")).strip().lower()

def main():
    records, seen_ids = [], set()
    batches = sorted(glob.glob(os.path.join(HERE, "mined-*.json")))
    for path in batches:
        data = json.load(open(path))
        for r in data.get("kept", []):
            if r["id"] in seen_ids:      # same ticket returned by overlapping ranges
                continue
            seen_ids.add(r["id"])
            records.append(r)

    # One patron filing the same complaint twice (contact form AND direct email)
    # appears as two ids with identical text. Keeping both would double-weight one
    # voice in every rate computed from this corpus.
    by_text, dupes = {}, 0
    for r in sorted(records, key=lambda r: r["id"]):
        key = norm(r["text"])
        if not key:
            continue
        if key in by_text:
            dupes += 1
            continue
        by_text[key] = r
    records = list(by_text.values())

    authoring = [r for r in records if r["id"] % 3 != 0]
    holdout   = [r for r in records if r["id"] % 3 == 0]

    for name, rows in (("authoring", authoring), ("holdout", holdout)):
        json.dump(
            {"split": name,
             "rule": "id % 3 == 0 -> holdout",
             "count": len(rows),
             "records": rows},
            open(os.path.join(HERE, f"{name}.json"), "w"),
            indent=2, ensure_ascii=False,
        )

    cats  = collections.Counter(r["category"] for r in records)
    acats = collections.Counter(r["category"] for r in authoring)
    hcats = collections.Counter(r["category"] for r in holdout)
    resolved = sum(1 for r in records if r.get("resolution"))

    print(f"batches: {len(batches)}")
    print(f"unique tickets: {len(records)}  (dropped {dupes} duplicate filings)")
    print(f"  authoring: {len(authoring)}   holdout (SEALED): {len(holdout)}")
    print(f"  with a recorded resolution: {resolved}/{len(records)}")
    print("\ncategory        all  auth  hold")
    for c, n in cats.most_common():
        print(f"  {c:<12} {n:4}  {acats[c]:4}  {hcats[c]:4}")

    # A category with too few resolved authoring tickets cannot support a
    # per-category prior; the suppression rule needs >= 15. Say which ones are
    # under it rather than letting a thin cell look measured.
    print("\nresolved AUTHORING tickets per category (>=15 needed for a prior):")
    for c in cats:
        n = sum(1 for r in authoring if r["category"] == c and r.get("resolution"))
        print(f"  {c:<12} {n:4}  {'ok' if n >= 15 else 'TOO THIN — treat as unknown, not zero'}")

if __name__ == "__main__":
    main()
