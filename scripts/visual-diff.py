#!/usr/bin/env python3
"""
visual-diff.py — masked perceptual / SSIM pixel-diff for the regression rebuild.

This is **stage 3** of the fleet regression campaign (RC-VISUAL). It is the
net-new capability that catches the bug class the OCR-marks structural diff
(`marks-diff.py`) misses: an empty-but-correctly-labelled loading skeleton that
*looks* broken while passing every text check — i.e. PP-4553 (final lanes with
1-2 books rendered a perpetual loading shimmer).

It compares a candidate screenshot against a per-device-cell golden baseline and
emits `visual-parity` findings in the campaign findings.csv schema. Pixel
comparison is masked so that legitimately-varying regions (the status-bar clock,
server-rotated book covers) do NOT produce false findings, while structural
collapses (covers -> empty skeleton) DO.

Two mask-region types resolve the central tension (you cannot just mask the cover
region — that is exactly where PP-4553 hides):
  - `exclude`  : region fully ignored (clock, battery, other dynamic chrome).
  - `content`  : cover / lane regions compared for **structural presence**
                 (gradient energy), not pixel identity. A different cover does
                 NOT fire; covers collapsing to a flat skeleton DOES.

Everything outside the masks is compared with a masked, uniform-window SSIM
(implemented in pure numpy — no scikit-image / scipy dependency).

Findings schema (campaign BUILD-PLAN shared contract):
  id,area,device_cell,severity,classification,verified,evidence_paths,
  screenshot_pair,first_seen_commit,dedup_cluster,disposition

Usage
-----
    # One pair -> diff image + a finding row:
    visual-diff.py diff \\
      --baseline baselines/C-iphone-26/catalog/03-catalog.png \\
      --candidate candidates/C-iphone-26/catalog/03-catalog.png \\
      --mask-config .simdrive/fixtures/masks/catalog.json \\
      --device-cell C-iphone-26 --area catalog/03-catalog \\
      --diff-out diffs/C-iphone-26/catalog/03-catalog.png \\
      --append-csv .regression-runs/run-1/findings.csv

    # A whole flow (dir vs dir), plus the structural marks diff merged in:
    visual-diff.py diff \\
      --baseline-dir baselines/C-iphone-26/catalog \\
      --candidate-dir candidates/C-iphone-26/catalog \\
      --device-cell C-iphone-26 --area catalog \\
      --diffs-dir diffs/C-iphone-26/catalog \\
      --with-marks --append-csv .regression-runs/run-1/findings.csv

    # Promote a candidate run to the golden baseline for a cell:
    visual-diff.py baseline promote \\
      --from candidates/C-iphone-26/catalog --cell C-iphone-26 --area catalog \\
      --root .regression-runs/golden

    # List golden baselines:
    visual-diff.py baseline list --root .regression-runs/golden
"""

from __future__ import annotations

import argparse
import json
import shutil
import sys
from dataclasses import dataclass, field
from pathlib import Path

import numpy as np
from PIL import Image, ImageDraw

# ---------------------------------------------------------------------------
# Shared campaign findings.csv schema (BUILD-PLAN contract).
# ---------------------------------------------------------------------------
# Mirrors regression_findings.FINDINGS_COLUMNS; the pinned-order equality is
# asserted by test_visual_diff.test_writes_through_real_shared_module.
CSV_HEADER = [
    "id", "area", "device_cell", "severity", "classification", "verified",
    "evidence_paths", "screenshot_pair", "first_seen_commit", "dedup_cluster",
    "disposition", "suspected_cause", "cause_status",
]

# Tuning defaults. Calibratable per-area (design open-question #3).
DEFAULT_SSIM_THRESHOLD = 0.90      # global masked SSIM below this -> pixel_regressed
DEFAULT_WINDOW_RADIUS = 3          # SSIM window = 2r+1 = 7px
DEFAULT_CONTENT_MIN_STRUCTURE = 4.0   # baseline gradient energy to call a region "populated"
DEFAULT_CONTENT_COLLAPSE_RATIO = 0.35  # candidate/baseline structure below this -> collapsed


# ---------------------------------------------------------------------------
# Finding model
# ---------------------------------------------------------------------------
@dataclass
class Finding:
    fid: str
    area: str
    device_cell: str
    severity: str
    classification: str
    evidence_paths: list[str]
    screenshot_pair: str
    subtype: str = ""           # pixel_regressed | empty_skeleton | dims_mismatch | text_*
    detail: dict = field(default_factory=dict)
    first_seen_commit: str = ""

    def _evidence(self) -> str:
        ev = list(self.evidence_paths)
        if self.subtype:
            ev.append(f"subtype={self.subtype}")
        for k, v in self.detail.items():
            ev.append(f"{k}={v}")
        return ";".join(ev)

    def to_csv_row(self) -> list[str]:
        return [
            self.fid, self.area, self.device_cell, self.severity, self.classification,
            "false", self._evidence(), self.screenshot_pair, self.first_seen_commit,
            "", "",
            # A pixel diff reports a difference; it never claims a mechanism.
            # `none` is the honest cause status, not an empty placeholder.
            "", "none",
        ]

    def to_dict(self) -> dict:
        """Schema-keyed dict — what the shared regression_findings.py writer consumes."""
        return dict(zip(CSV_HEADER, self.to_csv_row()))


# ---------------------------------------------------------------------------
# Image / SSIM primitives (pure numpy)
# ---------------------------------------------------------------------------
def load_gray(path: Path) -> np.ndarray:
    return np.asarray(Image.open(path).convert("L"), dtype=np.float64)


def load_rgb(path: Path) -> np.ndarray:
    return np.asarray(Image.open(path).convert("RGB"), dtype=np.uint8)


def _box_mean(a: np.ndarray, r: int) -> np.ndarray:
    """Uniform (box) filter, same-size output, via an integral image. O(n)."""
    w = 2 * r + 1
    ap = np.pad(a, r, mode="edge")
    ii = np.zeros((ap.shape[0] + 1, ap.shape[1] + 1), dtype=np.float64)
    ii[1:, 1:] = np.cumsum(np.cumsum(ap, axis=0), axis=1)
    h, wd = a.shape
    s = (ii[w:w + h, w:w + wd] - ii[0:h, w:w + wd]
         - ii[w:w + h, 0:wd] + ii[0:h, 0:wd])
    return s / (w * w)


def ssim_map(x: np.ndarray, y: np.ndarray, r: int = DEFAULT_WINDOW_RADIUS) -> np.ndarray:
    """Per-pixel SSIM map (same size as input), uniform window. Wang et al. 2004."""
    c1 = (0.01 * 255) ** 2
    c2 = (0.03 * 255) ** 2
    mu_x = _box_mean(x, r)
    mu_y = _box_mean(y, r)
    mu_x2, mu_y2, mu_xy = mu_x * mu_x, mu_y * mu_y, mu_x * mu_y
    sig_x2 = _box_mean(x * x, r) - mu_x2
    sig_y2 = _box_mean(y * y, r) - mu_y2
    sig_xy = _box_mean(x * y, r) - mu_xy
    num = (2 * mu_xy + c1) * (2 * sig_xy + c2)
    den = (mu_x2 + mu_y2 + c1) * (sig_x2 + sig_y2 + c2)
    return num / den


def structure_score(gray_region: np.ndarray) -> float:
    """Mean gradient energy. ~0 for a flat skeleton, high for cover art."""
    if gray_region.size == 0 or min(gray_region.shape) < 2:
        return 0.0
    gx = np.abs(np.diff(gray_region, axis=1))
    gy = np.abs(np.diff(gray_region, axis=0))
    return float((gx.mean() + gy.mean()) / 2.0)


# ---------------------------------------------------------------------------
# Mask config
# ---------------------------------------------------------------------------
@dataclass
class MaskRegion:
    kind: str          # "exclude" | "content"
    rect: tuple[int, int, int, int]   # x, y, w, h
    label: str = ""


def load_masks(path: Path | None) -> list[MaskRegion]:
    """A mask config is JSON: {"regions": [{"type","rect":[x,y,w,h],"label"}]}.

    Rects may be fractional (0..1) — interpreted relative to image size at
    apply time — or absolute pixels (>1). Fractional is recommended so one
    config works across resolutions within a device cell.
    """
    if not path:
        return []
    data = json.loads(Path(path).read_text())
    out: list[MaskRegion] = []
    for reg in data.get("regions", []):
        kind = reg.get("type", "exclude")
        if kind not in ("exclude", "content"):
            raise ValueError(f"mask region type must be exclude|content, got {kind!r}")
        rect = tuple(reg["rect"])
        if len(rect) != 4:
            raise ValueError(f"mask rect must be [x,y,w,h], got {rect!r}")
        out.append(MaskRegion(kind=kind, rect=rect, label=reg.get("label", "")))
    return out


def _abs_rect(rect, h: int, w: int) -> tuple[int, int, int, int]:
    x, y, rw, rh = rect
    frac = all(0.0 <= float(v) <= 1.0 for v in rect)
    if frac:
        x, y, rw, rh = round(x * w), round(y * h), round(rw * w), round(rh * h)
    x = max(0, min(int(x), w)); y = max(0, min(int(y), h))
    rw = max(0, min(int(rw), w - x)); rh = max(0, min(int(rh), h - y))
    return x, y, rw, rh


# ---------------------------------------------------------------------------
# Core comparison
# ---------------------------------------------------------------------------
@dataclass
class CompareResult:
    findings: list[Finding]
    ssim_global: float
    diff_image: Image.Image | None


def compare_pair(
    baseline_png: Path,
    candidate_png: Path,
    *,
    area: str,
    device_cell: str,
    masks: list[MaskRegion],
    ssim_threshold: float = DEFAULT_SSIM_THRESHOLD,
    window_radius: int = DEFAULT_WINDOW_RADIUS,
    content_min_structure: float = DEFAULT_CONTENT_MIN_STRUCTURE,
    content_collapse_ratio: float = DEFAULT_CONTENT_COLLAPSE_RATIO,
    diff_out: Path | None = None,
    first_seen_commit: str = "",
    fid_prefix: str = "V",
) -> CompareResult:
    bg = load_gray(baseline_png)
    cg = load_gray(candidate_png)
    pair = f"{baseline_png}|{candidate_png}"
    findings: list[Finding] = []

    # Dimension mismatch is itself a finding — a layout regression (or a wrong
    # capture); cannot SSIM meaningfully, so report and stop.
    if bg.shape != cg.shape:
        findings.append(Finding(
            fid=f"{fid_prefix}-dims-001", area=area, device_cell=device_cell,
            severity="major", classification="visual-parity",
            evidence_paths=[str(diff_out)] if diff_out else [],
            screenshot_pair=pair, subtype="dims_mismatch",
            detail={"baseline_dims": f"{bg.shape[1]}x{bg.shape[0]}",
                    "candidate_dims": f"{cg.shape[1]}x{cg.shape[0]}"},
            first_seen_commit=first_seen_commit,
        ))
        return CompareResult(findings=findings, ssim_global=0.0, diff_image=None)

    h, w = bg.shape
    smap = ssim_map(bg, cg, window_radius)

    # Build the "count this pixel toward global SSIM" mask. exclude AND content
    # regions are removed from the global score; content regions get the
    # structural-presence check instead.
    counted = np.ones((h, w), dtype=bool)
    content_regions: list[tuple[MaskRegion, tuple[int, int, int, int]]] = []
    for m in masks:
        x, y, rw, rh = _abs_rect(m.rect, h, w)
        if rw == 0 or rh == 0:
            continue
        counted[y:y + rh, x:x + rw] = False
        if m.kind == "content":
            content_regions.append((m, (x, y, rw, rh)))

    ssim_global = float(smap[counted].mean()) if counted.any() else 1.0

    # Global pixel regression (chrome / layout / skeleton background drift).
    if ssim_global < ssim_threshold:
        sev = "major" if ssim_global < ssim_threshold - 0.15 else "minor"
        findings.append(Finding(
            fid=f"{fid_prefix}-pixel-001", area=area, device_cell=device_cell,
            severity=sev, classification="visual-parity",
            evidence_paths=[str(diff_out)] if diff_out else [],
            screenshot_pair=pair, subtype="pixel_regressed",
            detail={"ssim": round(ssim_global, 4), "threshold": ssim_threshold},
            first_seen_commit=first_seen_commit,
        ))

    # Structural-presence collapse in content regions — the PP-4553 catch.
    for idx, (m, (x, y, rw, rh)) in enumerate(content_regions):
        b_score = structure_score(bg[y:y + rh, x:x + rw])
        c_score = structure_score(cg[y:y + rh, x:x + rw])
        if b_score >= content_min_structure and c_score < b_score * content_collapse_ratio:
            findings.append(Finding(
                fid=f"{fid_prefix}-skeleton-{idx + 1:03d}", area=area,
                device_cell=device_cell, severity="major",
                classification="visual-parity",
                evidence_paths=[str(diff_out)] if diff_out else [],
                screenshot_pair=pair, subtype="empty_skeleton",
                detail={"region": m.label or f"content-{idx}",
                        "baseline_structure": round(b_score, 3),
                        "candidate_structure": round(c_score, 3),
                        "collapse_ratio": round(c_score / b_score, 3) if b_score else 0.0},
                first_seen_commit=first_seen_commit,
            ))

    diff_img = _render_diff(cg, smap, masks, h, w) if diff_out else None
    if diff_out and diff_img is not None:
        diff_out.parent.mkdir(parents=True, exist_ok=True)
        diff_img.save(diff_out)

    return CompareResult(findings=findings, ssim_global=ssim_global, diff_image=diff_img)


def _render_diff(cand_gray, smap, masks, h, w) -> Image.Image:
    """Heatmap of (1 - SSIM) blended over the candidate, with masks outlined."""
    base = np.stack([cand_gray] * 3, axis=-1).astype(np.float64)
    heat = np.clip(1.0 - smap, 0.0, 1.0)
    # Red where SSIM is low.
    overlay = base.copy()
    overlay[..., 0] = np.clip(base[..., 0] + heat * 220, 0, 255)
    overlay[..., 1] = base[..., 1] * (1 - heat * 0.6)
    overlay[..., 2] = base[..., 2] * (1 - heat * 0.6)
    img = Image.fromarray(overlay.astype(np.uint8), "RGB")
    draw = ImageDraw.Draw(img)
    for m in masks:
        x, y, rw, rh = _abs_rect(m.rect, h, w)
        if rw == 0 or rh == 0:
            continue
        color = (40, 120, 255) if m.kind == "exclude" else (40, 220, 120)
        draw.rectangle([x, y, x + rw - 1, y + rh - 1], outline=color, width=3)
    return img


# ---------------------------------------------------------------------------
# marks-diff integration
# ---------------------------------------------------------------------------
def run_marks_diff(baseline_json: Path, candidate_json: Path, area: str,
                   device_cell: str, tolerance: int = 50) -> list[Finding]:
    """Call the existing structural marks diff and map its rows into the
    campaign schema as visual-parity findings. Imported, not re-implemented."""
    import importlib.util
    md_path = Path(__file__).resolve().parent / "marks-diff.py"
    spec = importlib.util.spec_from_file_location("marks_diff", md_path)
    if spec is None or spec.loader is None:
        return []
    md = importlib.util.module_from_spec(spec)
    sys.modules.setdefault(spec.name, md)
    spec.loader.exec_module(md)
    raw = md.diff_step(md.load(baseline_json), md.load(candidate_json), tolerance)
    pair = f"{baseline_json}|{candidate_json}"
    out: list[Finding] = []
    for i, f in enumerate(raw):
        sub = ("text_disappeared" if "disappeared" in f.title
               else "text_appeared" if "appeared" in f.title
               else "text_moved")
        out.append(Finding(
            fid=f"V-marks-{i + 1:03d}", area=area, device_cell=device_cell,
            severity=f.severity, classification="visual-parity",
            evidence_paths=[], screenshot_pair=pair, subtype=sub,
            detail={"marks": f.title},
        ))
    return out


# ---------------------------------------------------------------------------
# findings.csv writer
# ---------------------------------------------------------------------------
def _shared_writer():
    """Load the campaign's single source of truth for findings.csv I/O,
    `scripts/regression_findings.py` (on develop as of RC-AREA #1076), co-located
    next to this script. Required — we do NOT hand-roll a parallel CSV writer.
    """
    mod_path = Path(__file__).resolve().parent / "regression_findings.py"
    if not mod_path.exists():
        raise RuntimeError(
            f"regression_findings.py not found next to {Path(__file__).name}; "
            "it is the campaign's single source of truth for findings.csv I/O.")
    import importlib.util
    spec = importlib.util.spec_from_file_location("regression_findings", mod_path)
    mod = importlib.util.module_from_spec(spec)
    sys.modules.setdefault(spec.name, mod)
    spec.loader.exec_module(mod)
    return mod


def append_findings(path: Path, findings: list[Finding]) -> int:
    """Append `visual-parity` rows through the shared writer's
    append_findings(csv_path, rows) — bind to that name ONLY (never write_findings,
    which OVERWRITES). The writer returns None; we report the submitted count."""
    _shared_writer().append_findings(str(path), [f.to_dict() for f in findings])
    return len(findings)


# ---------------------------------------------------------------------------
# baseline subcommand (golden capture / promote / list per device cell)
# ---------------------------------------------------------------------------
def cmd_baseline(args) -> int:
    root = Path(args.root)
    if args.action in ("capture", "promote"):
        if not args.cell or not args.area:
            print("error: --cell and --area required", file=sys.stderr)
            return 2
        src = Path(getattr(args, "from"))
        dest = root / args.cell / args.area
        dest.mkdir(parents=True, exist_ok=True)
        pngs = [src] if src.is_file() else sorted(src.glob("*.png"))
        if not pngs:
            print(f"error: no PNGs under {src}", file=sys.stderr)
            return 2
        n = 0
        for p in pngs:
            shutil.copy2(p, dest / p.name)
            sidecar = p.with_suffix(".json")
            if sidecar.exists():
                shutil.copy2(sidecar, dest / sidecar.name)
            n += 1
        print(f"baseline {args.action}: {n} golden image(s) -> {dest}")
        return 0
    if args.action == "list":
        if not root.exists():
            print(f"(no baselines under {root})")
            return 0
        for cell_dir in sorted(p for p in root.iterdir() if p.is_dir()):
            for area_dir in sorted(p for p in cell_dir.iterdir() if p.is_dir()):
                pngs = sorted(area_dir.glob("*.png"))
                print(f"{cell_dir.name}/{area_dir.name}: {len(pngs)} step(s)")
        return 0
    print(f"error: unknown baseline action {args.action!r}", file=sys.stderr)
    return 2


# ---------------------------------------------------------------------------
# diff subcommand
# ---------------------------------------------------------------------------
def cmd_diff(args) -> int:
    # Ratified path convention (RC-AREA+CHAOS): candidates/baselines/diffs mirror
    # under <run-dir>/<kind>/<cell>/<area>/. --run-dir derives all three dirs.
    if args.run_dir:
        if not args.device_cell or not args.area:
            print("error: --run-dir requires --device-cell and --area", file=sys.stderr)
            return 2
        rel = Path(args.device_cell) / args.area
        run = Path(args.run_dir)
        args.baseline_dir = args.baseline_dir or str(run / "baselines" / rel)
        args.candidate_dir = args.candidate_dir or str(run / "candidates" / rel)
        args.diffs_dir = args.diffs_dir or str(run / "diffs" / rel)
        # Per-shard output (NOT a shared findings.csv) — the campaign driver merges
        # shards to the master, so there is no concurrent-write race.
        shard = f"{args.device_cell}__{args.area.replace('/', '_')}.csv"
        args.append_csv = args.append_csv or str(run / "findings" / shard)

    masks = load_masks(Path(args.mask_config) if args.mask_config else None)
    all_findings: list[Finding] = []

    if args.baseline_dir and args.candidate_dir:
        bdir, cdir = Path(args.baseline_dir), Path(args.candidate_dir)
        for bpng in sorted(bdir.glob("*.png")):
            cpng = cdir / bpng.name
            step = bpng.stem
            step_area = f"{args.area}/{step}" if args.area else step
            if not cpng.exists():
                all_findings.append(Finding(
                    fid=f"V-missing-{step}", area=step_area, device_cell=args.device_cell,
                    severity="major", classification="visual-parity",
                    evidence_paths=[], screenshot_pair=f"{bpng}|<missing>",
                    subtype="step_missing"))
                continue
            diff_out = (Path(args.diffs_dir) / bpng.name) if args.diffs_dir else None
            res = compare_pair(
                bpng, cpng, area=step_area, device_cell=args.device_cell, masks=masks,
                ssim_threshold=args.threshold, window_radius=args.window,
                content_min_structure=args.content_min_structure,
                content_collapse_ratio=args.content_collapse_ratio,
                diff_out=diff_out, first_seen_commit=args.commit,
                fid_prefix=f"V-{step}")
            all_findings.extend(res.findings)
            if args.with_marks:
                bjson, cjson = bpng.with_suffix(".json"), cpng.with_suffix(".json")
                if bjson.exists() and cjson.exists():
                    all_findings.extend(run_marks_diff(bjson, cjson, step_area, args.device_cell))
    elif args.baseline and args.candidate:
        res = compare_pair(
            Path(args.baseline), Path(args.candidate), area=args.area or "unspecified",
            device_cell=args.device_cell, masks=masks, ssim_threshold=args.threshold,
            window_radius=args.window, content_min_structure=args.content_min_structure,
            content_collapse_ratio=args.content_collapse_ratio,
            diff_out=Path(args.diff_out) if args.diff_out else None,
            first_seen_commit=args.commit)
        all_findings.extend(res.findings)
        print(f"global masked SSIM: {res.ssim_global:.4f}")
        if args.with_marks:
            bjson = Path(args.baseline).with_suffix(".json")
            cjson = Path(args.candidate).with_suffix(".json")
            if bjson.exists() and cjson.exists():
                all_findings.extend(run_marks_diff(bjson, cjson, args.area or "unspecified",
                                                   args.device_cell))
    else:
        print("error: provide --baseline+--candidate or --baseline-dir+--candidate-dir",
              file=sys.stderr)
        return 2

    by_sub: dict[str, int] = {}
    for f in all_findings:
        by_sub[f.subtype] = by_sub.get(f.subtype, 0) + 1
    print(f"visual-diff: {len(all_findings)} finding(s) {dict(sorted(by_sub.items()))}")
    for f in all_findings:
        print(f"  - [{f.severity:8}] [{f.subtype}] {f.area} :: {f.detail}")

    if args.json:
        Path(args.json).write_text(json.dumps(
            [{"id": f.fid, "area": f.area, "device_cell": f.device_cell,
              "severity": f.severity, "subtype": f.subtype, "detail": f.detail,
              "screenshot_pair": f.screenshot_pair} for f in all_findings],
            indent=2))
    if args.append_csv:
        n = append_findings(Path(args.append_csv), all_findings)
        print(f"appended {n} row(s) to {args.append_csv}")
    if args.strict and all_findings:
        return 1
    return 0


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------
def build_parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(description=__doc__,
                                formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = p.add_subparsers(dest="cmd", required=True)

    d = sub.add_parser("diff", help="masked SSIM + structural pixel diff")
    d.add_argument("--baseline", help="single baseline PNG")
    d.add_argument("--candidate", help="single candidate PNG")
    d.add_argument("--baseline-dir", help="baseline flow dir")
    d.add_argument("--candidate-dir", help="candidate flow dir")
    d.add_argument("--run-dir", help="campaign run dir; derives baselines/candidates/diffs/<cell>/<area> per the ratified path convention")
    d.add_argument("--mask-config", help="JSON mask config (exclude/content regions)")
    d.add_argument("--device-cell", default="", help="e.g. C-iphone-26")
    d.add_argument("--area", default="", help="area/flow label")
    d.add_argument("--diff-out", help="diff heatmap PNG (single-pair mode)")
    d.add_argument("--diffs-dir", help="diff heatmap dir (flow mode)")
    d.add_argument("--threshold", type=float, default=DEFAULT_SSIM_THRESHOLD)
    d.add_argument("--window", type=int, default=DEFAULT_WINDOW_RADIUS)
    d.add_argument("--content-min-structure", type=float, default=DEFAULT_CONTENT_MIN_STRUCTURE)
    d.add_argument("--content-collapse-ratio", type=float, default=DEFAULT_CONTENT_COLLAPSE_RATIO)
    d.add_argument("--with-marks", action="store_true", help="also run marks-diff.py on .json sidecars")
    d.add_argument("--commit", default="", help="first_seen_commit for findings")
    d.add_argument("--append-csv", help="append findings rows (BUILD-PLAN schema)")
    d.add_argument("--json", help="write full findings JSON sidecar")
    d.add_argument("--strict", action="store_true", help="exit 1 if any finding")
    d.set_defaults(func=cmd_diff)

    b = sub.add_parser("baseline", help="capture/promote/list golden baselines per cell")
    b.add_argument("action", choices=["capture", "promote", "list"])
    b.add_argument("--from", help="source PNG or dir (capture/promote)")
    b.add_argument("--cell", help="device cell (e.g. C-iphone-26)")
    b.add_argument("--area", help="area/flow label")
    b.add_argument("--root", default=".regression-runs/golden", help="golden baseline root")
    b.set_defaults(func=cmd_baseline)
    return p


def main(argv=None) -> int:
    args = build_parser().parse_args(argv)
    return args.func(args)


if __name__ == "__main__":
    sys.exit(main())
