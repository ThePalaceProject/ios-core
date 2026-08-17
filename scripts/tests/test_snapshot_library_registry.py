"""
test_snapshot_library_registry.py — pytest for the release-safe behavior of
scripts/snapshot-library-registry.py.

The snapshot refresh runs in the `beta`/`appstore` fastlane lanes BEFORE
`build_app`, so its exit code gates the release. A transient registry blip
(e.g. HTTP 502 Bad Gateway) once aborted the whole TestFlight export even though
a perfectly good committed snapshot ships in the bundle. These tests pin the
contract that makes that impossible:

  1. transient 5xx is retried, then a successful cut writes a fresh snapshot;
  2. a persistent transient failure with a usable committed snapshot present
     FALLS BACK (keeps the old file, exit 0) so the release proceeds;
  3. failure with NO usable snapshot to fall back to exits non-zero;
  4. --strict opts back into hard-fail even when a snapshot exists;
  5. a non-transient 4xx is NOT retried (fails fast, then falls back).

Network is fully stubbed via monkeypatched urlopen — no real registry is hit.
"""

from __future__ import annotations

import importlib.util
import json
import urllib.error
from pathlib import Path

import pytest

_REPO_ROOT = Path(__file__).resolve().parent.parent.parent
_SCRIPT = _REPO_ROOT / "scripts" / "snapshot-library-registry.py"


def _load_module():
    spec = importlib.util.spec_from_file_location("snapshot_library_registry", _SCRIPT)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


mod = _load_module()


class _FakeResp:
    """Minimal context-manager stand-in for an http.client.HTTPResponse."""

    def __init__(self, body: bytes, status: int = 200):
        self._body = body
        self.status = status

    def __enter__(self):
        return self

    def __exit__(self, *_a):
        return False

    def read(self) -> bytes:
        return self._body


def _page(catalogs, next_href=None, base="https://reg.test/crawlable"):
    links = [{"rel": "self", "href": base}]
    if next_href:
        links.append({"rel": "next", "href": next_href})
    return json.dumps({"metadata": {"title": "R"}, "catalogs": catalogs, "links": links}).encode()


def _http_502(url="https://reg.test/crawlable"):
    return urllib.error.HTTPError(url, 502, "Bad Gateway", hdrs=None, fp=None)


@pytest.fixture(autouse=True)
def _no_sleep(monkeypatch):
    # Keep the retry backoff from actually sleeping during the test run.
    monkeypatch.setattr(mod.time, "sleep", lambda *_a, **_k: None)


def _patch_urlopen(monkeypatch, behaviors):
    """behaviors: list of callables; each call pops the next and returns/raises it."""
    seq = list(behaviors)
    calls = {"n": 0}

    def fake_urlopen(req, timeout=None):  # noqa: ARG001
        calls["n"] += 1
        action = seq.pop(0) if seq else behaviors[-1]
        result = action() if callable(action) else action
        if isinstance(result, BaseException):
            raise result
        return result

    monkeypatch.setattr(mod.urllib.request, "urlopen", fake_urlopen)
    return calls


def test_transient_5xx_is_retried_then_succeeds(tmp_path, monkeypatch):
    out = tmp_path / "bundled_registry.json"
    # Two 502s, then a good single-page feed.
    calls = _patch_urlopen(monkeypatch, [
        lambda: _http_502(),
        lambda: _http_502(),
        lambda: _FakeResp(_page([{"id": "lib-a"}, {"id": "lib-b"}])),
    ])
    rc = mod.main(["--url", "https://reg.test/crawlable", "--out", str(out)])
    assert rc == 0
    assert calls["n"] == 3  # 1 initial + 2 retries
    written = json.loads(out.read_text())
    assert [c["id"] for c in written["catalogs"]] == ["lib-a", "lib-b"]


def test_persistent_transient_falls_back_to_committed_snapshot(tmp_path, monkeypatch, capsys):
    out = tmp_path / "bundled_registry.json"
    good = {"metadata": {"title": "committed"}, "catalogs": [{"id": "keep-me"}], "links": []}
    out.write_text(json.dumps(good))
    _patch_urlopen(monkeypatch, [lambda: _http_502()])  # always 502

    rc = mod.main(["--url", "https://reg.test/crawlable", "--out", str(out)])

    assert rc == 0, "a transient registry outage must not block the release"
    # The committed snapshot is untouched.
    assert json.loads(out.read_text()) == good
    # Loud, greppable fallback marker so a silent staleness is visible in CI logs.
    assert mod.FALLBACK_LOG_TOKEN in capsys.readouterr().err


def test_connection_error_is_retried_then_succeeds(tmp_path, monkeypatch):
    # The non-HTTP transient arm (connection reset / DNS blip -> URLError) must
    # be retried exactly like a 5xx, not treated as a hard failure.
    out = tmp_path / "bundled_registry.json"
    calls = _patch_urlopen(monkeypatch, [
        lambda: urllib.error.URLError("connection reset"),
        lambda: urllib.error.URLError("connection reset"),
        lambda: _FakeResp(_page([{"id": "recovered"}])),
    ])
    rc = mod.main(["--url", "https://reg.test/crawlable", "--out", str(out)])
    assert rc == 0
    assert calls["n"] == 3  # 1 initial + 2 retries on URLError
    assert [c["id"] for c in json.loads(out.read_text())["catalogs"]] == ["recovered"]


def test_timeout_is_transient_and_retries_are_bounded(tmp_path, monkeypatch):
    # A socket TimeoutError is transient; a persistent one must exhaust exactly
    # DEFAULT_RETRIES (1 initial + N retries), not spin forever, then fall back.
    out = tmp_path / "bundled_registry.json"
    out.write_text(json.dumps({"catalogs": [{"id": "keep-me"}]}))
    calls = _patch_urlopen(monkeypatch, [lambda: TimeoutError("timed out")])  # always times out
    rc = mod.main(["--url", "https://reg.test/crawlable", "--out", str(out)])
    assert rc == 0  # falls back to the committed snapshot
    assert calls["n"] == mod.DEFAULT_RETRIES + 1  # bounded: no infinite retry


def test_empty_committed_snapshot_is_not_a_usable_fallback(tmp_path, monkeypatch):
    # A committed file with zero catalogs is NOT a usable fallback: refreshing
    # fails AND there's nothing good to keep, so the run must hard-fail rather
    # than "succeed" on an empty snapshot. Kills the len>0 -> len>=0 mutation.
    out = tmp_path / "bundled_registry.json"
    out.write_text(json.dumps({"catalogs": []}))
    _patch_urlopen(monkeypatch, [lambda: _http_502()])
    rc = mod.main(["--url", "https://reg.test/crawlable", "--out", str(out)])
    assert rc == 1
    assert mod._existing_snapshot_ok(str(out)) is False


def test_failure_with_no_existing_snapshot_hard_fails(tmp_path, monkeypatch):
    out = tmp_path / "does-not-exist.json"
    _patch_urlopen(monkeypatch, [lambda: _http_502()])
    rc = mod.main(["--url", "https://reg.test/crawlable", "--out", str(out)])
    assert rc == 1
    assert not out.exists()


def test_strict_hard_fails_even_with_existing_snapshot(tmp_path, monkeypatch):
    out = tmp_path / "bundled_registry.json"
    out.write_text(json.dumps({"catalogs": [{"id": "keep-me"}]}))
    _patch_urlopen(monkeypatch, [lambda: _http_502()])
    rc = mod.main(["--url", "https://reg.test/crawlable", "--out", str(out), "--strict"])
    assert rc == 1


def test_non_transient_4xx_is_not_retried(tmp_path, monkeypatch):
    out = tmp_path / "bundled_registry.json"
    out.write_text(json.dumps({"catalogs": [{"id": "keep-me"}]}))
    calls = _patch_urlopen(monkeypatch, [
        lambda: urllib.error.HTTPError("https://reg.test/crawlable", 404, "Not Found", hdrs=None, fp=None),
    ])
    rc = mod.main(["--url", "https://reg.test/crawlable", "--out", str(out)])
    # 404 is not transient: exactly one attempt, no retries, then fall back.
    assert calls["n"] == 1
    assert rc == 0


def test_empty_feed_falls_back_and_leaves_snapshot(tmp_path, monkeypatch):
    out = tmp_path / "bundled_registry.json"
    good = {"catalogs": [{"id": "keep-me"}], "links": []}
    out.write_text(json.dumps(good))
    # A well-formed but EMPTY feed must not overwrite a good snapshot.
    _patch_urlopen(monkeypatch, [lambda: _FakeResp(_page([]))])
    rc = mod.main(["--url", "https://reg.test/crawlable", "--out", str(out)])
    assert rc == 0
    assert json.loads(out.read_text()) == good


def test_multipage_success_merges_catalogs(tmp_path, monkeypatch):
    out = tmp_path / "bundled_registry.json"
    _patch_urlopen(monkeypatch, [
        lambda: _FakeResp(_page([{"id": "p1"}], next_href="https://reg.test/crawlable?page=2")),
        lambda: _FakeResp(_page([{"id": "p2"}])),
    ])
    rc = mod.main(["--url", "https://reg.test/crawlable", "--out", str(out)])
    assert rc == 0
    written = json.loads(out.read_text())
    assert [c["id"] for c in written["catalogs"]] == ["p1", "p2"]
    assert written["metadata"]["numberOfItems"] == 2
