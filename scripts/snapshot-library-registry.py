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
        [--user-agent UA] \\
        [--strict]

Release-safe by design: the refresh is OPPORTUNISTIC. Transient upstream errors
(5xx gateway/overload, connection resets, timeouts) are retried with backoff,
and if a fresh snapshot still can't be cut, the existing committed snapshot is
kept and the run SUCCEEDS (exit 0) so a momentary registry blip — e.g. a 502
Bad Gateway — never blocks a release. It exits non-zero only when the snapshot
can't be refreshed AND there is no usable committed snapshot to fall back to, or
when `--strict` is given (for a job that must cut a genuinely fresh snapshot).
The output is written atomically — a partial or failed run never leaves a
half-written file behind, and a fallback leaves the committed snapshot untouched.
"""

from __future__ import annotations

import argparse
import json
import os
import sys
import tempfile
import time
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

# Transient upstream failures worth retrying: gateway/overload/timeout classes.
# A 502 Bad Gateway from the registry is exactly this — a momentary blip, not a
# reason to abort a release (see `main`'s fallback-to-committed-snapshot policy).
TRANSIENT_HTTP_STATUS = frozenset({500, 502, 503, 504})
DEFAULT_RETRIES = 3          # attempts AFTER the first try, on transient errors
DEFAULT_RETRY_BACKOFF_SECS = 2.0  # exponential: 2s, 4s, 8s

# Stable, greppable marker printed when the run falls back to the committed
# snapshot instead of cutting a fresh one — lets release/CI logs surface a
# silent staleness that would otherwise pass unnoticed.
FALLBACK_LOG_TOKEN = "[REGISTRY-SNAPSHOT-FALLBACK]"


class RegistrySnapshotError(Exception):
    """A registry page was unreachable, errored, or served a malformed feed.

    Raised for domain failures (bad HTTP, malformed/empty JSON) so `main` can
    apply the release-safe fallback policy instead of the process dying on a
    bare ``SystemExit`` deep in pagination.
    """


def _is_transient(exc: BaseException) -> bool:
    """True if `exc` is a momentary upstream failure worth retrying."""
    if isinstance(exc, urllib.error.HTTPError):
        return exc.code in TRANSIENT_HTTP_STATUS
    # URLError covers connection resets, DNS blips, timeouts; TimeoutError is
    # what a socket timeout raises directly on newer Pythons.
    return isinstance(exc, (urllib.error.URLError, TimeoutError))


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


def _fetch_json(
    url: str,
    *,
    timeout: float,
    user_agent: str,
    retries: int = DEFAULT_RETRIES,
    backoff: float = DEFAULT_RETRY_BACKOFF_SECS,
) -> dict[str, Any]:
    """Fetch and parse a single JSON page, retrying transient upstream errors.

    A transient error (5xx gateway/overload, connection reset, timeout) is
    retried up to `retries` times with exponential backoff; a non-transient
    failure (4xx, malformed JSON) fails immediately. All failures surface as
    ``RegistrySnapshotError`` so the caller can decide whether to abort or fall
    back to the committed snapshot.
    """
    req = urllib.request.Request(
        url,
        headers={"User-Agent": user_agent, "Accept": "application/opds+json, application/json"},
    )
    attempt = 0
    while True:
        try:
            with urllib.request.urlopen(req, timeout=timeout) as resp:
                if resp.status != 200:
                    raise RegistrySnapshotError(f"Registry returned HTTP {resp.status} for {url}")
                raw = resp.read()
            break
        except (urllib.error.URLError, TimeoutError) as exc:
            if _is_transient(exc) and attempt < retries:
                delay = backoff * (2 ** attempt)
                attempt += 1
                print(
                    f"[registry-snapshot] transient error fetching {url} ({exc}); "
                    f"retry {attempt}/{retries} in {delay:.0f}s",
                    file=sys.stderr,
                )
                time.sleep(delay)
                continue
            raise RegistrySnapshotError(f"Registry fetch failed for {url}: {exc}") from exc
    try:
        return json.loads(raw.decode("utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError) as exc:
        raise RegistrySnapshotError(f"Malformed JSON from {url}: {exc}") from exc


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
            raise RegistrySnapshotError(f"Aborting after {MAX_PAGES} pages — registry feed has no end-of-pagination signal")

        page = _fetch_json(current, timeout=timeout, user_agent=user_agent)
        page_catalogs = page.get("catalogs")
        if not isinstance(page_catalogs, list):
            raise RegistrySnapshotError(f"Page {pages} at {current} is missing `catalogs` array")
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
        raise RegistrySnapshotError("Registry feed contained zero libraries — refusing to write empty snapshot")

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


def _existing_snapshot_ok(path: str) -> bool:
    """True if `path` already holds a usable snapshot (parses, has ≥1 catalog).

    This is the release-safe fallback: an opportunistic refresh that can't reach
    the registry keeps the last good committed snapshot rather than aborting.
    """
    try:
        with open(path, "rb") as handle:
            data = json.loads(handle.read().decode("utf-8"))
    except (OSError, UnicodeDecodeError, json.JSONDecodeError):
        return False
    catalogs = data.get("catalogs") if isinstance(data, dict) else None
    return isinstance(catalogs, list) and len(catalogs) > 0


def main(argv: Optional[list[str]] = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0] if __doc__ else None)
    parser.add_argument("--url", default=DEFAULT_URL, help=f"Registry crawlable URL (default: {DEFAULT_URL})")
    parser.add_argument("--out", default=DEFAULT_OUT, help=f"Output JSON path (default: {DEFAULT_OUT})")
    parser.add_argument("--timeout", type=float, default=DEFAULT_TIMEOUT_SECS, help="Per-request timeout in seconds")
    parser.add_argument("--user-agent", default=DEFAULT_USER_AGENT, help="HTTP User-Agent header value")
    parser.add_argument(
        "--strict",
        action="store_true",
        help="Fail (non-zero) if a fresh snapshot can't be cut, even when a usable "
             "committed snapshot exists. Off by default so a transient registry "
             "outage never blocks a release.",
    )
    args = parser.parse_args(argv)

    try:
        feed = snapshot(args.url, timeout=args.timeout, user_agent=args.user_agent)
    except RegistrySnapshotError as exc:
        # The refresh is opportunistic: on first launch the app seeds its picker
        # from the committed snapshot and then reconciles via incremental refresh
        # (PP-4259), so a stale snapshot is recoverable but a BLOCKED RELEASE is
        # not. Unless --strict, fall back to the committed snapshot and succeed.
        have_fallback = _existing_snapshot_ok(args.out)
        if not args.strict and have_fallback:
            # Distinctive token so CI / release logs can grep for silent fallbacks
            # (an extended registry outage would otherwise ship an ever-staler
            # snapshot unnoticed — see the Deferred note on uptime monitoring).
            print(
                f"{FALLBACK_LOG_TOKEN} WARNING: could not refresh the registry snapshot "
                f"({exc}). Keeping the existing committed snapshot at {args.out}; the "
                f"release proceeds and the app's incremental refresh reconciles at runtime.",
                file=sys.stderr,
            )
            return 0
        if have_fallback:  # reached only under --strict
            print(
                f"Registry snapshot could not be refreshed and --strict forbids "
                f"falling back to the existing committed snapshot: {exc}",
                file=sys.stderr,
            )
        else:
            print(f"Registry snapshot failed and no usable snapshot to fall back to: {exc}", file=sys.stderr)
        return 1

    payload = json.dumps(feed, indent=2, sort_keys=True).encode("utf-8") + b"\n"
    _atomic_write(args.out, payload)
    print(f"Wrote {len(feed['catalogs'])} libraries to {args.out} ({len(payload)} bytes)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
