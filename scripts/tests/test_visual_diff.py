"""
Unit + CLI tests for scripts/visual-diff.py (RC-VISUAL, regression rebuild stage 3).

Proves the two DoD behaviors against synthetic fixtures (no simulator needed):
  1. A clock-only change is SUPPRESSED by an `exclude` mask (no finding).
  2. A covers -> empty-skeleton change is CAUGHT as a `visual-parity` finding
     (the PP-4553 catch), while a different-cover change is NOT (content mask
     tolerates legitimate cover variation).
Plus: diff image is written, findings.csv row uses the BUILD-PLAN schema, the
SSIM primitive is correct, and the CLI runs end-to-end.
"""
from __future__ import annotations

import csv
import importlib.util
import json
import subprocess
import sys
from pathlib import Path

import pytest

# visual-diff.py is a numpy/Pillow tool. Guard the COLLECTION so that in a
# stdlib-only env (the tooling-integrity CI gate) a missing dep SKIPS this file
# cleanly instead of raising a collection ERROR that interrupts the entire
# detector-pytest suite (exit 2). The gate installs numpy+Pillow so these tests
# actually run there; this guard is the safety net if they are ever absent.
np = pytest.importorskip("numpy", exc_type=ImportError)
pytest.importorskip("PIL", exc_type=ImportError)
from PIL import Image  # noqa: E402  (after importorskip by design)

SCRIPT = Path(__file__).resolve().parents[1] / "visual-diff.py"


def _load_named(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    mod = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = mod          # dataclasses resolves annotations via sys.modules
    spec.loader.exec_module(mod)
    return mod


vd = _load_named("visual_diff", SCRIPT)


# ---------------------------------------------------------------------------
# Synthetic fixture builders
# ---------------------------------------------------------------------------
WIDTH, HEIGHT = 200, 400
CLOCK_RECT = (70, 0, 60, 24)          # top status-bar clock
LANE_RECT = (10, 120, 180, 120)       # a catalog lane of covers


def _base_canvas(rng_seed: int) -> np.ndarray:
    """White screen + chrome text strip + a clock + a lane of 'cover' tiles."""
    img = np.full((HEIGHT, WIDTH, 3), 245, dtype=np.uint8)
    # static chrome strip (nav bar) — stable across versions
    img[40:70, :, :] = np.array([30, 60, 120], dtype=np.uint8)
    # clock glyphs (just some dark pixels in the clock rect)
    x, y, w, h = CLOCK_RECT
    img[y + 6:y + 18, x + 8:x + 52:4, :] = 20
    return img


def _draw_covers(img: np.ndarray, seed: int) -> np.ndarray:
    """Fill the lane with high-structure 'cover art' (random tiles)."""
    rng = np.random.default_rng(seed)
    x, y, w, h = LANE_RECT
    img = img.copy()
    # three book covers side by side, each a noisy colored block (high gradient energy)
    for i in range(3):
        cx = x + i * 60
        tile = rng.integers(0, 255, size=(h - 10, 50, 3), dtype=np.uint8)
        img[y + 5:y + 5 + tile.shape[0], cx + 2:cx + 2 + tile.shape[1], :] = tile
    return img


def _draw_skeleton(img: np.ndarray) -> np.ndarray:
    """Fill the lane with a flat gray loading skeleton (low structure) — PP-4553."""
    x, y, w, h = LANE_RECT
    img = img.copy()
    img[y:y + h, x:x + w, :] = 220   # uniform shimmer placeholder
    return img


def _change_clock(img: np.ndarray) -> np.ndarray:
    x, y, w, h = CLOCK_RECT
    img = img.copy()
    img[y + 6:y + 18, x + 8:x + 52:3, :] = 20   # different time -> different glyphs
    return img


@pytest.fixture
def fixtures(tmp_path: Path):
    base = _base_canvas(0)
    baseline = _draw_covers(base, seed=1)
    cand_clock = _draw_covers(_change_clock(base), seed=1)   # only clock differs
    cand_skeleton = _draw_skeleton(base)                     # covers -> skeleton
    cand_other_covers = _draw_covers(base, seed=99)          # different covers, still populated

    paths = {}
    for name, arr in [("baseline", baseline), ("cand_clock", cand_clock),
                      ("cand_skeleton", cand_skeleton), ("cand_other", cand_other_covers)]:
        p = tmp_path / f"{name}.png"
        Image.fromarray(arr, "RGB").save(p)
        paths[name] = p

    # mask config: clock excluded, lane is a content region.
    mask = {"regions": [
        {"type": "exclude", "rect": list(CLOCK_RECT), "label": "clock"},
        {"type": "content", "rect": list(LANE_RECT), "label": "catalog-lane"},
    ]}
    mp = tmp_path / "mask.json"
    mp.write_text(json.dumps(mask))
    paths["mask"] = mp
    paths["dir"] = tmp_path
    return paths


# ---------------------------------------------------------------------------
# SSIM primitive
# ---------------------------------------------------------------------------
def test_ssim_identical_is_one():
    a = np.random.default_rng(3).integers(0, 255, (50, 50)).astype(np.float64)
    m = vd.ssim_map(a, a)
    assert m.mean() > 0.999


def test_ssim_drops_when_region_flattens():
    a = np.random.default_rng(3).integers(0, 255, (50, 50)).astype(np.float64)
    b = np.full((50, 50), 128.0)
    assert vd.ssim_map(a, b).mean() < 0.5


def test_structure_score_distinguishes_covers_from_skeleton():
    rng = np.random.default_rng(7)
    covers = rng.integers(0, 255, (100, 150)).astype(np.float64)
    skeleton = np.full((100, 150), 220.0)
    assert vd.structure_score(covers) > vd.DEFAULT_CONTENT_MIN_STRUCTURE
    assert vd.structure_score(skeleton) < 0.5


# ---------------------------------------------------------------------------
# DoD behavior 1 — clock-only change suppressed by exclude mask
# ---------------------------------------------------------------------------
def test_clock_only_change_is_suppressed(fixtures):
    masks = vd.load_masks(fixtures["mask"])
    res = vd.compare_pair(
        fixtures["baseline"], fixtures["cand_clock"],
        area="catalog/03", device_cell="C-iphone-26", masks=masks)
    assert res.findings == [], f"clock-only change should be masked, got {res.findings}"
    assert res.ssim_global > 0.99


def test_clock_change_WOULD_fire_without_mask(fixtures):
    """Control: without the exclude mask the clock change does perturb SSIM —
    proves the suppression is the mask doing work, not the change being invisible."""
    res = vd.compare_pair(
        fixtures["baseline"], fixtures["cand_clock"],
        area="catalog/03", device_cell="C-iphone-26", masks=[],
        ssim_threshold=0.999999)
    assert res.ssim_global < 0.999999


# ---------------------------------------------------------------------------
# DoD behavior 2 — covers -> skeleton caught; different-covers tolerated
# ---------------------------------------------------------------------------
def test_empty_skeleton_is_caught(fixtures, tmp_path):
    masks = vd.load_masks(fixtures["mask"])
    diff_out = tmp_path / "diff.png"
    res = vd.compare_pair(
        fixtures["baseline"], fixtures["cand_skeleton"],
        area="catalog/03", device_cell="C-iphone-26", masks=masks,
        diff_out=diff_out)
    skels = [f for f in res.findings if f.subtype == "empty_skeleton"]
    assert len(skels) == 1, f"expected one empty_skeleton finding, got {res.findings}"
    f = skels[0]
    assert f.classification == "visual-parity"
    assert f.severity == "major"
    assert diff_out.exists(), "diff heatmap image must be written"


def test_different_covers_are_tolerated(fixtures):
    """Legitimate server-side cover variation must NOT fire (content mask)."""
    masks = vd.load_masks(fixtures["mask"])
    res = vd.compare_pair(
        fixtures["baseline"], fixtures["cand_other"],
        area="catalog/03", device_cell="C-iphone-26", masks=masks)
    assert [f for f in res.findings if f.subtype == "empty_skeleton"] == []


def test_dims_mismatch_is_a_finding(tmp_path):
    a = tmp_path / "a.png"; b = tmp_path / "b.png"
    Image.new("RGB", (100, 100), "white").save(a)
    Image.new("RGB", (120, 100), "white").save(b)
    res = vd.compare_pair(a, b, area="x", device_cell="C", masks=[])
    assert len(res.findings) == 1 and res.findings[0].subtype == "dims_mismatch"


# ---------------------------------------------------------------------------
# findings.csv schema
# ---------------------------------------------------------------------------
def test_csv_row_matches_buildplan_schema(fixtures, tmp_path):
    masks = vd.load_masks(fixtures["mask"])
    res = vd.compare_pair(
        fixtures["baseline"], fixtures["cand_skeleton"],
        area="catalog/03", device_cell="C-iphone-26", masks=masks)
    csv_path = tmp_path / "findings.csv"
    n = vd.append_findings(csv_path, res.findings)
    assert n >= 1
    with csv_path.open() as fh:
        rows = list(csv.reader(fh))
    assert rows[0] == vd.CSV_HEADER
    assert rows[0] == ["id", "area", "device_cell", "severity", "classification",
                       "verified", "evidence_paths", "screenshot_pair",
                       "first_seen_commit", "dedup_cluster", "disposition"]
    row = rows[1]
    assert row[4] == "visual-parity"     # classification
    assert row[5] == "false"             # verified starts false
    assert "subtype=empty_skeleton" in row[6]


# ---------------------------------------------------------------------------
# baseline subcommand
# ---------------------------------------------------------------------------
def test_baseline_promote_and_list(fixtures, tmp_path, capsys):
    root = tmp_path / "golden"
    ns = vd.build_parser().parse_args([
        "baseline", "promote", "--from", str(fixtures["baseline"]),
        "--cell", "C-iphone-26", "--area", "catalog", "--root", str(root)])
    assert ns.func(ns) == 0
    assert (root / "C-iphone-26" / "catalog" / "baseline.png").exists()
    ns2 = vd.build_parser().parse_args(["baseline", "list", "--root", str(root)])
    assert ns2.func(ns2) == 0
    assert "C-iphone-26/catalog" in capsys.readouterr().out


# ---------------------------------------------------------------------------
# shared-writer adapter (w-stabilize's regression_findings.py contract)
# ---------------------------------------------------------------------------
def test_writes_through_real_shared_module(tmp_path):
    """End-to-end against the REAL regression_findings.py co-located in scripts/
    (on develop as of RC-AREA #1076) — no monkeypatch. Proves visual-diff binds
    the campaign's single source of truth and a row round-trips."""
    rf = _load_named("regression_findings", SCRIPT.parent / "regression_findings.py")
    assert vd.CSV_HEADER == rf.FINDINGS_COLUMNS   # column order is the contract
    f = vd.Finding(fid="V-skeleton-001", area="catalog/03", device_cell="C-iphone-26",
                   severity="major", classification="visual-parity",
                   evidence_paths=["diff.png"], screenshot_pair="b.png|c.png",
                   subtype="empty_skeleton", detail={"region": "lane-1"})
    shard = tmp_path / "C-iphone-26__catalog.csv"
    assert vd.append_findings(shard, [f]) == 1
    rows = rf.read_findings(str(shard))
    assert len(rows) == 1
    assert rows[0]["classification"] == "visual-parity"
    assert rows[0]["verified"] == "false"
    assert "subtype=empty_skeleton" in rows[0]["evidence_paths"]


def test_missing_shared_writer_is_a_hard_error(tmp_path, monkeypatch):
    """No silent fallback — if the single-source-of-truth writer is absent, fail
    loudly rather than hand-rolling a parallel CSV."""
    def _boom():
        raise RuntimeError("regression_findings.py not found")
    monkeypatch.setattr(vd, "_shared_writer", _boom)
    f = vd.Finding(fid="V-1", area="a", device_cell="C", severity="minor",
                   classification="visual-parity", evidence_paths=[],
                   screenshot_pair="b|c", subtype="pixel_regressed")
    with pytest.raises(RuntimeError):
        vd.append_findings(tmp_path / "shard.csv", [f])


def test_adapter_binds_append_findings_never_write_findings(tmp_path, monkeypatch):
    """Must call the pinned append_findings(csv_path, rows); must NOT touch
    write_findings (which overwrites the shard)."""
    calls = {}

    class FakeWriter:
        @staticmethod
        def append_findings(csv_path, rows):
            calls["append"] = (csv_path, rows)

        @staticmethod
        def write_findings(csv_path, rows):
            raise AssertionError("write_findings must never be called by the adapter")

    monkeypatch.setattr(vd, "_shared_writer", lambda: FakeWriter)
    f = vd.Finding(fid="V-1", area="catalog", device_cell="C-iphone-26",
                   severity="major", classification="visual-parity",
                   evidence_paths=["d.png"], screenshot_pair="b|c",
                   subtype="empty_skeleton")
    n = vd.append_findings(tmp_path / "shard.csv", [f])
    assert n == 1
    csv_path, rows = calls["append"]
    assert csv_path.endswith("shard.csv")
    assert isinstance(rows, list) and isinstance(rows[0], dict)
    assert list(rows[0].keys()) == vd.CSV_HEADER       # schema-keyed dicts
    assert rows[0]["classification"] == "visual-parity"


def test_run_dir_derives_shard_path(fixtures, tmp_path):
    run = tmp_path / "run-1"
    (run / "baselines" / "C-iphone-26" / "catalog").mkdir(parents=True)
    (run / "candidates" / "C-iphone-26" / "catalog").mkdir(parents=True)
    import shutil as _sh
    _sh.copy2(fixtures["baseline"], run / "baselines" / "C-iphone-26" / "catalog" / "anon-03.png")
    _sh.copy2(fixtures["cand_skeleton"], run / "candidates" / "C-iphone-26" / "catalog" / "anon-03.png")
    ns = vd.build_parser().parse_args([
        "diff", "--run-dir", str(run), "--device-cell", "C-iphone-26",
        "--area", "catalog", "--mask-config", str(fixtures["mask"])])
    assert ns.func(ns) == 0
    assert (run / "findings" / "C-iphone-26__catalog.csv").exists()
    assert (run / "diffs" / "C-iphone-26" / "catalog" / "anon-03.png").exists()


# ---------------------------------------------------------------------------
# CLI end-to-end
# ---------------------------------------------------------------------------
def test_cli_diff_strict_exit_and_csv(fixtures, tmp_path):
    csv_path = tmp_path / "findings.csv"
    diff_out = tmp_path / "diff.png"
    r = subprocess.run(
        [sys.executable, str(SCRIPT), "diff",
         "--baseline", str(fixtures["baseline"]),
         "--candidate", str(fixtures["cand_skeleton"]),
         "--mask-config", str(fixtures["mask"]),
         "--device-cell", "C-iphone-26", "--area", "catalog/03",
         "--diff-out", str(diff_out), "--append-csv", str(csv_path), "--strict"],
        capture_output=True, text=True)
    assert r.returncode == 1, r.stdout + r.stderr      # strict: findings -> exit 1
    assert "empty_skeleton" in r.stdout
    assert csv_path.exists() and diff_out.exists()


def test_cli_clock_only_is_clean(fixtures, tmp_path):
    r = subprocess.run(
        [sys.executable, str(SCRIPT), "diff",
         "--baseline", str(fixtures["baseline"]),
         "--candidate", str(fixtures["cand_clock"]),
         "--mask-config", str(fixtures["mask"]),
         "--device-cell", "C-iphone-26", "--area", "catalog/03", "--strict"],
        capture_output=True, text=True)
    assert r.returncode == 0, r.stdout + r.stderr      # no findings -> exit 0
    assert "0 finding(s)" in r.stdout
