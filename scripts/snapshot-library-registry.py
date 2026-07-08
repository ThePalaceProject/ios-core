#!/usr/bin/env python3
"""Snapshot the paginated Palace library registry into a single bundled JSON.

PP-4258 — At build time (or release pipeline), fetch every page of the OPDS 2.0
crawlable feed at `https://registry.palaceproject.io/libraries/crawlable`,
merge all `catalogs` entries into one consolidated feed, and write the result
to a stable path that ships inside the app bundle.

On first launch with no on-disk cache, the app loads this snapshot to populate
the library picker immediately, then kicks off an asynchronous incremental
refresh (PP-4259) to pick up anything that changed since the snapshot was cut.

Usage:
    scripts/snapshot-library-registry.py \\
        [--url URL] \\
        [--out PATH] \\
        [--timeout SECS] \\
        [--user-agent UA]

Exits non-zero if the registry is unreachable, returns an HTTP error, or
serves a malformed/empty feed. The output is written atomically — a partial
or failed run never leaves a half-written file behind.
"""

from __future__ import annotations

import argparse
import json
import os
import sys
import tempfile
import urllib.error
import urllib.request
from typing import Any, Optional
from urllib.parse import urljoin

DEFAULT_URL = "https://registry.palaceproject.io/libraries/crawlable"
DEFAULT_OUT = os.path.join(
    os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
    "Palace",
    "Accounts",
    "Library",
    "bundled_registry.json",
)
DEFAULT_TIMEOUT_SECS = 30
DEFAULT_USER_AGENT = "PalaceiOS-RegistrySnapshot/1.0"
MAX_PAGES = 1000  # belt-and-suspenders: stop chasing rel=next after this many


def _next_url(feed: dict[str, Any], base: str) -> Optional[str]:
    """Return the absolute URL of the rel=next link in `feed`, or None."""
    for link in feed.get("links", []) or []:
        rel = link.get("rel")
        rels = rel if isinstance(rel, list) else [rel] if rel else []
        if "next" in rels:
            href = link.get("href")
            if isinstance(href, str) and href:
                return urljoin(base, href)
    return None


def _fetch_json(url: str, *, timeout: float, user_agent: str) -> dict[str, Any]:
    """Fetch and parse a single JSON page from the registry."""
    req = urllib.request.Request(
        url,
        headers={"User-Agent": user_agent, "Accept": "application/opds+json, application/json"},
    )
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        if resp.status != 200:
            raise SystemExit(f"Registry returned HTTP {resp.status} for {url}")
        raw = resp.read()
    try:
        return json.loads(raw.decode("utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError) as exc:
        raise SystemExit(f"Malformed JSON from {url}: {exc}") from exc


def snapshot(
    url: str = DEFAULT_URL,
    *,
    timeout: float = DEFAULT_TIMEOUT_SECS,
    user_agent: str = DEFAULT_USER_AGENT,
) -> dict[str, Any]:
    """Paginate the registry and return a single consolidated OPDS 2.0 feed."""
    catalogs: list[dict[str, Any]] = []
    first_metadata: Optional[dict[str, Any]] = None
    first_facets: Optional[list[Any]] = None

    current = url
    pages = 0
    while current is not None:
        pages += 1
        if pages > MAX_PAGES:
            raise SystemExit(f"Aborting after {MAX_PAGES} pages — registry feed has no end-of-pagination signal")

        page = _fetch_json(current, timeout=timeout, user_agent=user_agent)
        page_catalogs = page.get("catalogs")
        if not isinstance(page_catalogs, list):
            raise SystemExit(f"Page {pages} at {current} is missing `catalogs` array")
        catalogs.extend(page_catalogs)

        if first_metadata is None:
            metadata = page.get("metadata")
            if isinstance(metadata, dict):
                first_metadata = dict(metadata)
            facets = page.get("facets")
            if isinstance(facets, list):
                first_facets = facets

        current = _next_url(page, base=current)

    if not catalogs:
        raise SystemExit("Registry feed contained zero libraries — refusing to write empty snapshot")

    consolidated: dict[str, Any] = {
        "metadata": first_metadata or {"title": "Palace Library Registry"},
        "catalogs": catalogs,
        "links": [{"href": url, "rel": "self"}],
    }
    # Drop numberOfItems from metadata — it described the paginated count of
    # one page, not the consolidated total. Recompute to match the merged set.
    consolidated["metadata"]["numberOfItems"] = len(catalogs)
    if first_facets is not None:
        consolidated["facets"] = first_facets

    return consolidated


def _atomic_write(path: str, payload: bytes) -> None:
    """Write `payload` to `path` atomically (write-temp + rename)."""
    parent = os.path.dirname(os.path.abspath(path))
    os.makedirs(parent, exist_ok=True)
    fd, tmp_path = tempfile.mkstemp(
        prefix=".bundled_registry.",
        suffix=".tmp",
        dir=parent,
    )
    try:
        with os.fdopen(fd, "wb") as out:
            out.write(payload)
        os.replace(tmp_path, path)
    except Exception:
        try:
            os.unlink(tmp_path)
        except OSError:
            pass
        raise


def main(argv: Optional[list[str]] = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0] if __doc__ else None)
    parser.add_argument("--url", default=DEFAULT_URL, help=f"Registry crawlable URL (default: {DEFAULT_URL})")
    parser.add_argument("--out", default=DEFAULT_OUT, help=f"Output JSON path (default: {DEFAULT_OUT})")
    parser.add_argument("--timeout", type=float, default=DEFAULT_TIMEOUT_SECS, help="Per-request timeout in seconds")
    parser.add_argument("--user-agent", default=DEFAULT_USER_AGENT, help="HTTP User-Agent header value")
    args = parser.parse_args(argv)

    try:
        feed = snapshot(args.url, timeout=args.timeout, user_agent=args.user_agent)
    except urllib.error.URLError as exc:
        print(f"Registry unreachable: {exc}", file=sys.stderr)
        return 1
    except SystemExit:
        raise
    except Exception as exc:  # noqa: BLE001 — script entry point
        print(f"Snapshot failed: {exc}", file=sys.stderr)
        return 1

    payload = json.dumps(feed, indent=2, sort_keys=True).encode("utf-8") + b"\n"
    _atomic_write(args.out, payload)
    print(f"Wrote {len(feed['catalogs'])} libraries to {args.out} ({len(payload)} bytes)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
