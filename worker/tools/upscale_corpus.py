"""Decision A1 quality corpus: per-image PSNR for `upscale.4x`, measured only.

The owner approved the installed `swin2sr-x4 1.0.0` and fixed one bar: the
per-image minimum PSNR over the corpus must be >= 24.0 dB. That bar is the
only input to this harness's exit code. Nothing is downloaded, installed,
adopted or converted here.

The bicubic-x4 control is a diagnostic, never a gate. The independent review
of 2026-11-18 measured the control on the same eight pairs: it cleared
24.0 dB on every image (minimum 32.23 dB, mean 34.15 dB) against the model's
32.42 dB / 34.13 dB. On a corpus degraded by a bicubic downscale the bar
therefore does not discriminate a learned upscaler from a classical resize,
and **quality value-add over the control is NOT PROVEN and is not claimed by
this tool, its record, or `Docs/W5_UPSCALER_ACCEPTANCE.md` §9**. "Must beat
the control" was added by the harness, not by the owner, and the project
manager withdrew it as a gate on 2026-11-18; it stays here as a recorded
win/tie/lose per image.

Three degradations are selectable:

  bicubic    the corpus the first A1 run measured: a plain bicubic x4
             downscale. Kept so §7.5 stays reproducible.
  realistic  the §8 protocol as measured on 2026-11-18: JPEG q=70 (4:2:0),
             Gaussian noise sigma = 5 code values out of 255 and Gaussian
             blur radius 1.2 -- all at the reference resolution -- then the
             bicubic x4 downscale. Kept unchanged so §8 stays reproducible.
             Its defect is recorded: the x4 downscale averages the injected
             noise (the review measured an RMS difference of 1.83-1.97 code
             values against the plain bicubic input), so most of the
             adversarial content never reaches the model.
  lr         the intended adversarial gate: Gaussian blur radius 1.2 at the
             reference resolution, bicubic x4 downscale, then JPEG q=70
             (4:2:0) and Gaussian noise sigma = 5/255 at the *degraded*
             resolution, so compression and noise survive to the model input.
             A radius-1.2 reference-resolution blur is a 0.3 px-equivalent
             blur at the degraded resolution; the record carries both radii.

Parameters and a per-sample seed are recorded; a rerun of the same image at
the same position and seed measures the same pair. The bar is applied to
every image, never to the mean.

Measurement contract (restated here so a reader never has to guess):

  1. read the source, convert it to sRGB using its embedded ICC profile with
     `renderingIntent=1` (relative colorimetric; recorded, and originally 0);
  2. crop to a multiple of 4 (`width - width % 4`, from the top-left corner);
  3. degrade by a factor of 4 with the selected protocol -> `D`;
  4. hand `D` to the real 4x capability over the worker socket -> `D4`;
  5. PSNR(D4, cropped sRGB reference) on 8-bit, gamma-encoded sRGB code
     values, RGB, RMS over all channels (the same metric as `psnr()` in
     `worker/tools/upscale_acceptance.py`);
  6. repeat 5 on a bicubic-x4 upscale of `D` and record it as a diagnostic.

`D` is written to a temporary directory and deleted again: derived pixels are
private, and nothing of the owner's photo leaves memory. Only metadata and
numbers are recorded; a fixture path is recorded only with `--record-paths`.

Seam bands (+/- 32 px around the internal tile boundaries the engine blends)
are recorded as diagnostics and no threshold is applied to them. The
boundaries follow the engine's own rule (`engine._axis_tiles`): starts are
`range(0, length - 256 + 1, 240)`, and when the last tile would end short the
start `length - 256` is appended; those starts, except the first, scaled by 4,
are the output boundaries. A 567x1008 input therefore has x boundaries
960 and 1244 and y boundaries 960, 1920, 2880 and 3008 -- the earlier corpus
used multiples of 960 only and missed the clamped last boundary.

Tiles the engine refuses are not retried or resized: an output above the
40 MP ceiling is a contract error, not something a harness may paper over.

Usage (worker already listening; the model must already be adopted):

    <runtime>/bin/python worker/tools/upscale_corpus.py \
        --socket /tmp/rs-a1/worker.sock \
        --jobs-root /tmp/rs-a1/jobs \
        --sample C1=/path/to/fixture-1.jpg \
        --sample C2=/path/to/fixture-2.jpg \
        --degradation lr \
        --out /tmp/rs-a1/out/upscale-corpus.json

Exit codes: 0 every sample was measured and the bar was met on every image;
1 the bar was missed on at least one measured image (the control outcome is
reported but never changes this code); 2 nothing measurable -- the capability
is not `supported`, the model failed verification, the worker is unreachable,
a fixture is unreadable, or a job produced no exact-size output from the
approved model version; 3 the harness itself raised. Only 0 and 1 are
verdicts about image quality; 2 and 3 claim nothing.
"""
from __future__ import annotations

import argparse
import io
import json
import math
import statistics
import sys
import tempfile
import time
import traceback
from pathlib import Path

TOOLS = Path(__file__).resolve().parent
ROOT = TOOLS.parents[1]
sys.path.insert(0, str(ROOT / "worker"))
sys.path.insert(0, str(TOOLS))

import numpy as np  # noqa: E402
from PIL import Image, ImageCms, ImageFilter  # noqa: E402

from retouch_ai_worker import provenance  # noqa: E402
from upscale_acceptance import Client  # noqa: E402

CAPABILITY = "upscale.4x"
MODEL = "swin2sr-x4"
APPROVED_VERSION = "1.0.0"
# The engine's tiling, restated rather than imported so this tool never pulls
# the engine (and torch) in: `UPSCALE_TILE = 256`, `overlap = tile // 16`, and
# `_axis_tiles` clamps the last start to `length - tile`.
TILE = 256
OVERLAP = 16
TILE_STEP = TILE - OVERLAP
SCALE = 4
SEAM_BAND = 32
DEFAULT_MIN_PSNR = 24.0

# The 2026-11-18 degradation parameters. The three numbers are the project
# manager's decision, not this tool's invention. `realistic` applies them at
# the reference resolution (as §8 measured); `lr` applies JPEG and noise at
# the degraded resolution so they survive the x4 downscale.
JPEG_QUALITY = 70
JPEG_SUBSAMPLING = 2  # 4:2:0, stated so libjpeg defaults cannot drift
NOISE_SIGMA = 5.0     # 8-bit code values out of 255
BLUR_RADIUS = 1.2
DEFAULT_SEED = 20261118

DEGRADATION_PARAMS = {
    "bicubic": {"order": "bicubic x4 downscale only"},
    "realistic": {
        "jpegQuality": JPEG_QUALITY,
        "jpegSubsampling": "4:2:0",
        "noiseSigmaCodeValues": NOISE_SIGMA,
        "blurRadiusReferencePixels": BLUR_RADIUS,
        "order": "jpeg, noise and blur at reference resolution, then the "
                 "bicubic x4 downscale"},
    "lr": {
        "jpegQuality": JPEG_QUALITY,
        "jpegSubsampling": "4:2:0",
        "noiseSigmaCodeValues": NOISE_SIGMA,
        "blurRadiusReferencePixels": BLUR_RADIUS,
        "blurRadiusInputPixels": round(BLUR_RADIUS / SCALE, 2),
        "order": "gaussian blur at reference resolution, bicubic x4 "
                 "downscale, then jpeg and noise at the degraded "
                 "resolution"},
}
NOISE_MODES = ("realistic", "lr")
RENDERING_INTENT = 1  # relative colorimetric; explicit and recorded


class BadInput(Exception):
    """A fixture, argument or environment this run cannot use (exit 2)."""


class NotRunnable(Exception):
    """The capability or model is not measurable right now (exit 2)."""


def to_srgb(image: Image.Image) -> tuple[Image.Image, str]:
    """Convert to sRGB with the embedded profile, or pass RGB through."""
    icc = image.info.get("icc_profile")
    if not icc:
        return image.convert("RGB"), "none (assumed sRGB)"
    try:
        source = ImageCms.ImageCmsProfile(io.BytesIO(icc))
        description = ImageCms.getProfileDescription(source).strip()
        target = ImageCms.createProfile("sRGB")
        converted = ImageCms.profileToProfile(
            image.convert("RGB"), source, target,
            renderingIntent=RENDERING_INTENT, outputMode="RGB")
        return converted, description or "unnamed ICC"
    except (ImageCms.PyCMSError, OSError, ValueError) as exc:
        raise BadInput(f"cannot convert this fixture to sRGB: {exc}") from exc


def psnr(reference: Image.Image, output: Image.Image) -> float:
    """PSNR over RGB, 8-bit sRGB code values, RMS over every sample."""
    if reference.size != output.size:
        raise ValueError("PSNR needs identical sizes")
    a = np.asarray(reference.convert("RGB"), dtype=np.float64)
    b = np.asarray(output.convert("RGB"), dtype=np.float64)
    mse = ((a - b) ** 2).mean()
    if mse == 0:
        return float("inf")
    return 10.0 * math.log10(255.0 ** 2 / mse)


def axis_tile_starts(length: int, tile: int = TILE,
                     step: int = TILE_STEP) -> list[int]:
    """The engine's own start positions along one axis (`_axis_tiles`).

    `range(0, length - tile + 1, step)`, and when the last tile would end
    short, the start `length - tile` is appended so every tile has full
    context. A length <= tile is one tile starting at 0.
    """
    if length <= tile:
        return [0]
    starts = list(range(0, length - tile + 1, step))
    if starts[-1] + tile < length:
        starts.append(length - tile)
    return starts


def seam_boundaries(length: int, tile: int = TILE, step: int = TILE_STEP,
                    scale: int = SCALE) -> list[int]:
    """Internal tile boundaries for an input axis of `length` pixels.

    Returned in *output* pixels: the first tile has no seam before it, and
    every later start -- where two tiles meet -- is scaled by the upscale
    factor.
    """
    return [start * scale for start in axis_tile_starts(length, tile, step)[1:]]


def seam_psnr(reference: Image.Image, output: Image.Image,
              band: int = SEAM_BAND) -> float | None:
    """PSNR over the pixels within `band` of an internal tile boundary.

    The engine tiles the *input*, so its boundaries are computed from
    `width // SCALE` and `height // SCALE` and come back in output pixels:
    the engine's tile rule, not multiples of the step, because the clamped
    last start is a boundary too. The outer edges are not seams, so a 1-tile
    render has no band and returns None.
    """
    width, height = reference.size
    a = np.asarray(reference.convert("RGB"), dtype=np.float64)
    b = np.asarray(output.convert("RGB"), dtype=np.float64)
    mask = np.zeros((height, width), dtype=bool)
    for x in seam_boundaries(width // SCALE):
        mask[:, max(0, x - band):min(width, x + band)] = True
    for y in seam_boundaries(height // SCALE):
        mask[max(0, y - band):min(height, y + band), :] = True
    if not mask.any():
        return None
    diff = (a - b) ** 2
    mse = diff[mask].mean()
    if mse == 0:
        return float("inf")
    return 10.0 * math.log10(255.0 ** 2 / mse)


def describe(image: Image.Image, description: str) -> dict:
    """Source metadata, the same fields `upscale_acceptance.describe_image`
    records, plus the ICC description this tool already recorded."""
    exif = image.getexif()
    return {"width": image.width, "height": image.height,
            "mode": image.mode,
            "bitDepth": 16 if "I;16" in image.mode or image.mode == "I" else 8,
            "channels": len(image.getbands()),
            "alpha": any(band in image.getbands()
                         for band in ("A", "transparency")),
            "exifOrientation": exif.get(274) if exif else None,
            "icc": description}


def _jpeg_roundtrip(image: Image.Image) -> Image.Image:
    buffer = io.BytesIO()
    image.save(buffer, "JPEG", quality=JPEG_QUALITY,
               subsampling=JPEG_SUBSAMPLING)
    buffer.seek(0)
    with Image.open(buffer) as compressed:
        compressed.load()
        return compressed.convert("RGB")


def _add_noise(image: Image.Image, seed: int) -> Image.Image:
    rng = np.random.default_rng(seed)
    pixels = np.asarray(image, dtype=np.float64)
    pixels += rng.normal(0.0, NOISE_SIGMA, pixels.shape)
    return Image.fromarray(np.rint(np.clip(pixels, 0.0, 255.0)).astype(np.uint8),
                           "RGB")


def degrade(reference: Image.Image, mode: str, seed: int) -> tuple[Image.Image, dict]:
    """Produce the protocol input `D` for one reference.

    `bicubic` is the original A1 corpus. `realistic` is the §8 protocol as
    measured: JPEG, noise and blur at the reference resolution, then the
    bicubic downscale. `lr` keeps JPEG and noise after the downscale, where
    the model receives them. Both noise paths are seeded, so a rerun on the
    same image and seed measures the same pair.
    """
    if mode not in DEGRADATION_PARAMS:
        raise BadInput(f"unknown degradation: {mode}")
    size = (reference.width // SCALE, reference.height // SCALE)
    if mode == "bicubic":
        return reference.resize(size, Image.BICUBIC), dict(
            DEGRADATION_PARAMS["bicubic"], mode="bicubic")
    if mode == "realistic":
        degraded = _jpeg_roundtrip(reference)
        degraded = _add_noise(degraded, seed)
        degraded = degraded.filter(ImageFilter.GaussianBlur(radius=BLUR_RADIUS))
        degraded = degraded.resize(size, Image.BICUBIC)
    else:  # lr
        degraded = reference.filter(ImageFilter.GaussianBlur(radius=BLUR_RADIUS))
        degraded = degraded.resize(size, Image.BICUBIC)
        degraded = _jpeg_roundtrip(degraded)
        degraded = _add_noise(degraded, seed)
    return degraded, dict(DEGRADATION_PARAMS[mode], mode=mode, seed=seed)


def run_sample(client: Client, label: str, path: Path, jobs_root: Path,
               temp: Path, job_timeout: float, degradation: str,
               seed: int) -> dict:
    try:
        with Image.open(path) as opened:
            converted, icc = to_srgb(opened)
            source = describe(opened, icc)
    except OSError as exc:
        raise BadInput(f"{label}: cannot read {path}: {exc}") from exc
    width, height = converted.size
    cropped = (width - width % 4, height - height % 4)
    reference = converted.crop((0, 0, cropped[0], cropped[1]))
    if reference.size != (cropped[0], cropped[1]):
        raise RuntimeError("crop did not produce the expected size")
    # Plain `Image.BICUBIC`: Pillow scales the filter support by the 1/4
    # factor, which is the antialiased bicubic the contract names. No
    # `reducing_gap` shortcut: that path treats large factors differently and
    # would stop being "bicubic" as commonly measured.
    degraded, degradation_info = degrade(reference, degradation, seed)
    control = degraded.resize(reference.size, Image.BICUBIC)
    control_psnr = psnr(reference, control)

    input_path = temp / f"{label}-d.png"
    degraded.save(input_path, "PNG")

    params = {"image": {"path": str(input_path.resolve())}}
    job_id = client.call("job.submit", {"kind": "upscale",
                                        "capabilityId": CAPABILITY,
                                        "params": params})["result"]["job_id"]
    started = time.perf_counter()
    finished = client.wait_finished(job_id, job_timeout)
    wall = round(time.perf_counter() - started, 2)
    record: dict = {"label": label, "source": source,
                    "reference": {"width": reference.width,
                                  "height": reference.height},
                    "input": {"width": degraded.width,
                              "height": degraded.height},
                    "degradation": degradation_info,
                    "seamBoundaries": {
                        "x": seam_boundaries(reference.width // SCALE),
                        "y": seam_boundaries(reference.height // SCALE)},
                    "controlBicubicPsnr": round(control_psnr, 2),
                    "wallSeconds": wall, "jobId": job_id}
    if finished.get("status") != "succeeded":
        record["error"] = f"job ended as {finished.get('status')}"
        return record

    result = client.call("job.result", {"job_id": job_id})["result"]
    payload = result.get("result") if isinstance(result.get("result"),
                                                 dict) else {}
    artifact = Path(payload["output"])
    sidecar = provenance.verify(artifact)
    with Image.open(artifact) as output:
        exact = output.size == reference.size
        record["output"] = {"width": output.width, "height": output.height}
        record["dimensionsExact"] = exact
        if exact:
            record["psnr"] = round(psnr(reference, output), 2)
            band = seam_psnr(reference, output)
            record["seamPsnr"] = None if band is None else round(band, 2)
    record["modelVersion"] = (sidecar.get("model") or {}).get("version")
    record["tiles"] = payload.get("tiles")
    record["tile"] = payload.get("tile")
    record["overlap"] = payload.get("overlap")
    record["jobSeconds"] = payload.get("seconds")
    record["device"] = payload.get("device")
    if jobs_root is not None:
        # The frozen cleanup criterion counts the render's own pair only; the
        # workdir's claim file belongs to the folder and is not a leftover.
        left = sorted(entry.name for entry in artifact.parent.iterdir()
                      if entry.name != ".lock")
        record["leftovers"] = left
    input_path.unlink(missing_ok=True)
    return record


def control_outcome(delta: float) -> str:
    """The diagnostic comparison with the bicubic-x4 control, per image."""
    if delta > 0:
        return "win"
    if delta < 0:
        return "lose"
    return "tie"


def summarize(values: list[float]) -> dict:
    """min / mean / median of measured values, or None where nothing was
    measured. `statistics.median` is used so an even count averages the two
    middle values instead of taking the upper one."""
    if not values:
        return {"minimum": None, "mean": None, "median": None}
    return {"minimum": min(values),
            "mean": round(sum(values) / len(values), 2),
            "median": round(statistics.median(values), 2)}


def judge(records: list[dict], min_psnr: float,
          control_margin: float | None) -> tuple[str, int, dict]:
    """The A1 bar decides the exit code; the control never does.

    Returns `(a1Bar, exitCode, detail)` where `a1Bar` is `met`, `missed` or
    `not-measured`. Each measured row is annotated with its own `a1` result
    and its `control` outcome (`win`/`tie`/`lose`), which is recorded and
    reported but is not an input to the exit code.
    """
    measured = [row for row in records
                if isinstance(row.get("psnr"), (int, float))]
    unmeasured = [row["label"] for row in records
                  if not isinstance(row.get("psnr"), (int, float))]
    missed = [row["label"] for row in measured if row["psnr"] < min_psnr]
    wrong_dimensions = [row["label"] for row in records
                        if row.get("dimensionsExact") is False]
    unapproved = [row["label"] for row in measured
                  if row.get("modelVersion") != APPROVED_VERSION]
    outcomes: dict[str, list[str]] = {"win": [], "tie": [], "lose": []}
    for row in measured:
        delta = row["psnr"] - row["controlBicubicPsnr"]
        row["controlDeltaDb"] = round(delta, 2)
        row["control"] = control_outcome(delta)
        row["a1"] = "missed" if row["psnr"] < min_psnr else "met"
        if control_margin is not None:
            row["clearsControlMargin"] = delta >= control_margin
        outcomes[row["control"]].append(row["label"])
    if missed:
        bar, code = "missed", 1
    elif unmeasured or wrong_dimensions or unapproved:
        bar, code = "not-measured", 2
    else:
        bar, code = "met", 0
    detail = {"missed": missed, "notMeasured": unmeasured,
              "dimensionFailures": wrong_dimensions,
              "unapprovedModel": unapproved, "outcomes": outcomes}
    return bar, code, detail


CONTROL_NOTE = {
    "bicubic": "the control cleared the 24.0 dB bar on all eight recorded "
               "pairs (minimum 32.23 dB, mean 34.15 dB), so this bar does not "
               "discriminate a learned upscaler on a bicubic-degraded corpus; "
               "quality value-add over the control is NOT PROVEN",
    "realistic": "the §8 +0.5 dB condition is recorded here as a diagnostic "
                 "only from 2026-11-18 and no longer gates; value-add over "
                 "the control is not claimed",
    "lr": "the intended adversarial degradation; the bar is the only gate "
          "and value-add over the control is not claimed",
}


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser()
    parser.add_argument("--socket", required=True)
    parser.add_argument("--jobs-root", type=Path, default=None)
    parser.add_argument("--sample", action="append", default=[],
                        metavar="LABEL=PATH",
                        help="one fixture; repeat once per image")
    parser.add_argument("--out", type=Path, required=True)
    parser.add_argument("--min-psnr", type=float, default=DEFAULT_MIN_PSNR,
                        help="the A1 bar; applied to every image, never "
                             "averaged away")
    parser.add_argument("--degradation",
                        choices=("bicubic", "realistic", "lr"),
                        default="bicubic",
                        help="bicubic: the original A1 corpus; realistic: "
                             "the §8 protocol, JPEG + noise + blur at the "
                             "reference resolution; lr: blur at the "
                             "reference resolution, downscale, then JPEG + "
                             "noise at the degraded resolution (the intended "
                             "adversarial gate)")
    parser.add_argument("--seed", type=int, default=DEFAULT_SEED,
                        help="base seed for the noise; one deterministic "
                             "seed is derived per sample")
    parser.add_argument("--control-margin", type=float, default=None,
                        help="diagnostic tie band in dB: when given, each "
                             "image records whether it clears it. Never an "
                             "exit-code input")
    parser.add_argument("--record-paths", action="store_true",
                        help="include the fixture path in the record "
                             "(off: labels and metadata only)")
    parser.add_argument("--job-timeout", type=float, default=1500.0)
    parser.add_argument("--temp-dir", type=Path,
                        default=Path(tempfile.gettempdir()) / "RetouchStudioAI",
                        help="the worker's own working directory: derived "
                             "pixels must stay inside a root it may read")
    return parser


def parse_samples(parser: argparse.ArgumentParser,
                  items: list[str]) -> list[tuple[str, Path]]:
    """Validate labels and files before anything connects to a worker."""
    samples: list[tuple[str, Path]] = []
    seen: set[str] = set()
    for item in items:
        label, separator, raw = item.partition("=")
        if not separator or not label or not raw:
            parser.error(f"--sample needs LABEL=PATH, got {item!r}")
        if label in seen:
            parser.error(f"duplicate sample label: {label}")
        seen.add(label)
        path = Path(raw).expanduser()
        if not path.is_file():
            parser.error(f"{label}: not a file: {path}")
        samples.append((label, path))
    if not samples:
        parser.error("at least one --sample LABEL=PATH is required")
    return samples


def write_record(path: Path, record: dict) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(record, indent=2), encoding="utf-8")


def measure(args, samples: list[tuple[str, Path]]) -> int:
    started = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
    try:
        client = Client(args.socket, timeout=args.job_timeout)
    except OSError as exc:
        raise NotRunnable(f"cannot connect to {args.socket}: {exc}") from exc
    records: list[dict] = []
    try:
        try:
            capabilities = client.call("capability.list")["result"]
        except OSError as exc:
            raise NotRunnable(
                f"the worker did not answer capability.list: {exc}") from exc
        state = next((item for item in capabilities["capabilities"]
                      if item["capabilityId"] == CAPABILITY), {})
        if state.get("state") != "supported":
            reason = f"{CAPABILITY} is {state.get('state', 'absent')}"
            write_record(args.out, {
                "harness": "w5-7-upscale-corpus", "started": started,
                "finished": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
                "capability": state, "a1Bar": "not-measured", "exitCode": 2,
                "reason": reason})
            print(reason)
            return 2
        try:
            verified = client.call("models.verify", {"model": MODEL})
        except OSError as exc:
            raise NotRunnable(
                f"the worker did not answer models.verify: {exc}") from exc
        if not (verified.get("result") or {}).get("ok"):
            reason = (f"{MODEL} failed verification: "
                      f"{verified.get('result') or verified.get('error')}")
            write_record(args.out, {
                "harness": "w5-7-upscale-corpus", "started": started,
                "finished": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
                "capability": state, "a1Bar": "not-measured", "exitCode": 2,
                "reason": reason})
            print(reason)
            return 2

        try:
            args.temp_dir.mkdir(parents=True, exist_ok=True)
        except OSError as exc:
            raise BadInput(f"cannot use --temp-dir {args.temp_dir}: {exc}") \
                from exc
        with tempfile.TemporaryDirectory(prefix="rs-upscale-corpus-",
                                         dir=args.temp_dir) as tmp:
            temp = Path(tmp)
            for index, (label, path) in enumerate(samples):
                # A fixed seed per position makes a rerun of the same corpus
                # reproduce the same pairs instead of resampling the noise.
                try:
                    row = run_sample(client, label, path, args.jobs_root, temp,
                                     args.job_timeout, args.degradation,
                                     args.seed + index)
                except BadInput as exc:
                    row = {"label": label, "error": str(exc)}
                    print(f"{label}: {exc}", file=sys.stderr, flush=True)
                except OSError as exc:
                    row = {"label": label,
                           "error": f"worker call failed: {exc}"}
                    if args.record_paths:
                        row["path"] = str(path)
                    records.append(row)
                    print(f"{label}: {row['error']}", file=sys.stderr,
                          flush=True)
                    break
                if args.record_paths:
                    row["path"] = str(path)
                records.append(row)
                print(f"{label}: {row.get('reference')} -> "
                      f"{row.get('output')} psnr={row.get('psnr')} "
                      f"seam={row.get('seamPsnr')} "
                      f"control={row['controlBicubicPsnr']}", flush=True)

        bar, code, detail = judge(records, args.min_psnr, args.control_margin)
        measured = [row for row in records
                    if isinstance(row.get("psnr"), (int, float))]
        versions = sorted({str(row.get("modelVersion")) for row in measured})
        model_stats = summarize([row["psnr"] for row in measured])
        control_stats = summarize([row["controlBicubicPsnr"]
                                   for row in measured])
        summary = {
            "harness": "w5-7-upscale-corpus",
            "started": started,
            "finished": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
            "capability": f"{CAPABILITY} supported",
            "model": {"id": MODEL, "versions": versions},
            "exitCode": code,
            "a1Bar": bar,
            "contract": {
                "srgbFirst": True,
                "iccConversion": "Pillow ImageCms profileToProfile, "
                                 "renderingIntent=1 (relative colorimetric)",
                "renderingIntent": RENDERING_INTENT,
                "cropMultiple": 4,
                "degradation": args.degradation,
                "degradationParameters": DEGRADATION_PARAMS[args.degradation],
                "downscale": "bicubic x4",
                "noiseSeeds": ([row.get("degradation", {}).get("seed")
                                for row in records]
                               if args.degradation in NOISE_MODES else None),
                "psnr": "8-bit gamma-encoded sRGB code values, RGB, RMS over "
                        "all channels",
                "seamBand": SEAM_BAND,
                "seamRule": "engine _axis_tiles: starts range(0, length - "
                            "256 + 1, 240), appending length - 256 when the "
                            "last span is short; boundaries are the starts "
                            "after the first, scaled x4",
                "seamThreshold": "none (diagnostic only)",
            },
            "bar": {
                "name": "A1 per-image minimum PSNR",
                "minPsnr": args.min_psnr,
                "source": "Decision A1 (owner), 2026-11-18",
                "appliedTo": "every measured image, never the mean",
                "result": bar,
                "missedImages": detail["missed"],
                "notMeasuredImages": detail["notMeasured"],
                "dimensionFailures": detail["dimensionFailures"],
                "unapprovedModel": detail["unapprovedModel"],
            },
            "control": {
                "role": "diagnostic; never an exit-code input",
                "baseline": "bicubic x4 upscale of the same degraded input",
                "outcomes": detail["outcomes"],
                "marginDb": args.control_margin,
                "marginRole": ("none recorded" if args.control_margin is None
                               else "reporting only; never an exit code"),
                "note": CONTROL_NOTE[args.degradation],
            },
            "images": records,
            "aggregate": {
                "count": len(records),
                **model_stats,
                "controlMinimum": control_stats["minimum"],
                "controlMean": control_stats["mean"],
                "controlMedian": control_stats["median"],
                "belowBar": detail["missed"],
                "controlOutcomes": detail["outcomes"],
                "notMeasured": detail["notMeasured"],
                "dimensionFailures": detail["dimensionFailures"],
            },
        }
        write_record(args.out, summary)
        print(json.dumps({**summary["aggregate"], "a1Bar": bar,
                          "exitCode": code}, indent=2))
        print(f"a1Bar: {bar} (exit {code}; record: {args.out})")
        return code
    finally:
        client.close()


def main(argv: list[str] | None = None) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)
    if args.control_margin is not None and args.control_margin < 0:
        parser.error("--control-margin must be >= 0")
    try:
        samples = parse_samples(parser, args.sample)
        return measure(args, samples)
    except NotRunnable as exc:
        print(f"not runnable: {exc}", file=sys.stderr)
        return 2
    except BadInput as exc:
        print(f"bad input: {exc}", file=sys.stderr)
        return 2
    except Exception:
        traceback.print_exc()
        return 3


if __name__ == "__main__":
    sys.exit(main())
