"""Decision A1 quality corpus: per-image PSNR for `upscale.4x`, measured only.

The owner approved the installed `swin2sr-x4 1.0.0` and fixed one bar: the
per-image minimum PSNR over the corpus must be >= 24.0 dB. This tool measures
that bar and nothing else; it does not download, install, adopt or convert
anything.

Two degradations are selectable. `bicubic` is the corpus the first A1 run
measured: on it a bicubic-x4 control is nearly the inverse of the degradation,
so the project manager withdrew "must beat the control" as a gate on
2026-11-18 and kept it as a diagnostic. `realistic` is the replacement
adversarial gate fixed the same day: JPEG q=70 (4:2:0), Gaussian noise
sigma = 5 code values out of 255, Gaussian blur radius 1.2 -- all at the
reference resolution -- then a bicubic downscale by 4. On that degradation the
model must clear 24.0 dB *and* beat the bicubic-x4 control by at least
+0.5 dB per image. Both numbers are applied per image, never to the mean.

Measurement contract (restated here so a reader never has to guess):

  1. read the source, convert it to sRGB using its embedded ICC profile;
  2. crop to a multiple of 4 (`width - width % 4`, from the top-left corner);
  3. degrade by a factor of 4 with the selected protocol -> `D`;
  4. hand `D` to the real 4x capability over the worker socket -> `D4`;
  5. PSNR(D4, cropped sRGB reference) on 8-bit, gamma-encoded sRGB code
     values, RGB, RMS over all channels (the same metric as `psnr()` in
     `worker/tools/upscale_acceptance.py`);
  6. repeat 5 on a bicubic-x4 upscale of `D` for the control.

`D` is written to a temporary directory and deleted again: derived pixels are
private, and nothing of the owner's photo leaves memory. Only metadata and
numbers are recorded; a fixture path is recorded only with `--record-paths`.

Seam bands (+/- 32 px around the internal tile boundaries the engine blends,
every 960 output pixels because the step is 256 - 16 = 240 input pixels) are
recorded as diagnostics. No threshold is applied to them: the frozen record
sets none today, and this tool does not invent one.

Tiles the engine refuses are not retried or resized: an output above the
40 MP ceiling is a contract error, not something a harness may paper over.

Usage (worker already listening; the model must already be adopted):

    <runtime>/bin/python worker/tools/upscale_corpus.py \
        --socket /tmp/rs-a1/worker.sock \
        --jobs-root /tmp/rs-a1/jobs \
        --sample C1=/path/to/fixture-1.jpg \
        --sample C2=/path/to/fixture-2.jpg \
        --degradation realistic \
        --out /tmp/rs-a1/out/upscale-corpus.json

Exit codes: 0 the per-image minimum met the bar and every pair cleared the
control gate (strictly beating it, or by the margin when one applies); 1 the
bar or the control gate was missed; 2 the capability is not `supported`, so
nothing was measured and nothing is claimed.
"""
from __future__ import annotations

import argparse
import io
import json
import math
import sys
import tempfile
import time
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
# Tile step the engine runs with: tile 256, overlap tile // 16 = 16. Restated
# rather than imported so this tool never pulls the engine (and torch) in.
TILE_STEP = 240
SCALE = 4
SEAM_BAND = 32
DEFAULT_MIN_PSNR = 24.0

# The 2026-11-18 replacement gate. The three numbers and the order are the
# project manager's decision, not this tool's invention: JPEG, then noise,
# then blur at the reference resolution, then the bicubic downscale.
JPEG_QUALITY = 70
JPEG_SUBSAMPLING = 2  # 4:2:0, stated so libjpeg defaults cannot drift
NOISE_SIGMA = 5.0     # 8-bit code values out of 255
BLUR_RADIUS = 1.2
CONTROL_MARGIN = 0.5  # dB the model must beat the control by, per image
DEFAULT_SEED = 20261118


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
            image.convert("RGB"), source, target, renderingIntent=0,
            outputMode="RGB")
        return converted, description or "unnamed ICC"
    except (ImageCms.PyCMSError, OSError, ValueError) as exc:
        raise SystemExit(f"cannot convert this fixture to sRGB: {exc}")


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


def seam_psnr(reference: Image.Image, output: Image.Image,
              band: int = SEAM_BAND, step: int = TILE_STEP * SCALE) -> float | None:
    """PSNR over the pixels within `band` of an internal tile boundary.

    Boundaries live at every multiple of `step` in the output; the outer
    edges are not seams, so a 1-tile render has no band and returns None.
    """
    width, height = reference.size
    a = np.asarray(reference.convert("RGB"), dtype=np.float64)
    b = np.asarray(output.convert("RGB"), dtype=np.float64)
    mask = np.zeros((height, width), dtype=bool)
    for x in range(step, width, step):
        mask[:, max(0, x - band):min(width, x + band)] = True
    for y in range(step, height, step):
        mask[max(0, y - band):min(height, y + band), :] = True
    if not mask.any():
        return None
    diff = (a - b) ** 2
    mse = diff[mask].mean()
    if mse == 0:
        return float("inf")
    return 10.0 * math.log10(255.0 ** 2 / mse)


def describe(image: Image.Image, description: str) -> dict:
    return {"width": image.width, "height": image.height,
            "mode": image.mode, "icc": description}


def degrade(reference: Image.Image, mode: str, seed: int) -> tuple[Image.Image, dict]:
    """Produce the protocol input `D` for one reference.

    `bicubic` is the original A1 corpus. `realistic` is the 2026-11-18
    replacement: JPEG, noise and blur at the reference resolution, then the
    same bicubic downscale. The noise is seeded, so a rerun on the same image
    and seed measures the same pair.
    """
    size = (reference.width // SCALE, reference.height // SCALE)
    if mode == "bicubic":
        return (reference.resize(size, Image.BICUBIC),
                {"mode": "bicubic", "order": "bicubic x4 downscale only"})
    if mode != "realistic":
        raise SystemExit(f"unknown degradation: {mode}")
    buffer = io.BytesIO()
    reference.save(buffer, "JPEG", quality=JPEG_QUALITY,
                   subsampling=JPEG_SUBSAMPLING)
    buffer.seek(0)
    with Image.open(buffer) as compressed:
        compressed.load()
        degraded = compressed.convert("RGB")
    rng = np.random.default_rng(seed)
    pixels = np.asarray(degraded, dtype=np.float64)
    pixels += rng.normal(0.0, NOISE_SIGMA, pixels.shape)
    degraded = Image.fromarray(np.rint(np.clip(pixels, 0.0, 255.0)).astype(np.uint8),
                               "RGB")
    degraded = degraded.filter(ImageFilter.GaussianBlur(radius=BLUR_RADIUS))
    return (degraded.resize(size, Image.BICUBIC),
            {"mode": "realistic", "jpegQuality": JPEG_QUALITY,
             "jpegSubsampling": "4:2:0", "noiseSigmaCodeValues": NOISE_SIGMA,
             "blurRadius": BLUR_RADIUS, "seed": seed,
             "order": "jpeg, noise and blur at reference resolution, then "
                      "bicubic x4 downscale"})


def run_sample(client: Client, label: str, path: Path, jobs_root: Path,
               temp: Path, job_timeout: float, degradation: str,
               seed: int) -> dict:
    with Image.open(path) as opened:
        converted, icc = to_srgb(opened)
        source = describe(opened, icc)
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


def main() -> int:
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
    parser.add_argument("--degradation", choices=("bicubic", "realistic"),
                        default="bicubic",
                        help="bicubic: the original A1 corpus; realistic: "
                             "JPEG q=70 + noise + blur, the 2026-11-18 "
                             "replacement gate")
    parser.add_argument("--seed", type=int, default=DEFAULT_SEED,
                        help="base seed for the realistic noise; one "
                             "deterministic seed is derived per sample")
    parser.add_argument("--control-margin", type=float, default=None,
                        help="dB the model must beat the control by; "
                             "defaults to 0.5 for realistic and 'must beat' "
                             "(0 with a strict comparison) for bicubic")
    parser.add_argument("--record-paths", action="store_true",
                        help="include the fixture path in the record "
                             "(off: labels and metadata only)")
    parser.add_argument("--job-timeout", type=float, default=1500.0)
    parser.add_argument("--temp-dir", type=Path,
                        default=Path(tempfile.gettempdir()) / "RetouchStudioAI",
                        help="the worker's own working directory: derived "
                             "pixels must stay inside a root it may read")
    args = parser.parse_args()
    if not args.sample:
        parser.error("at least one --sample LABEL=PATH is required")

    records: list[dict] = []
    started = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
    client = Client(args.socket, timeout=args.job_timeout)
    exit_code = 0
    try:
        capabilities = client.call("capability.list")["result"]
        state = next((item for item in capabilities["capabilities"]
                      if item["capabilityId"] == CAPABILITY), {})
        if state.get("state") != "supported":
            record = {"harness": "w5-7-upscale-corpus", "started": started,
                      "capability": state, "verdict": "not-runnable",
                      "reason": f"{CAPABILITY} is "
                                f"{state.get('state', 'absent')}"}
            args.out.parent.mkdir(parents=True, exist_ok=True)
            args.out.write_text(json.dumps(record, indent=2), encoding="utf-8")
            print(record["reason"])
            return 2
        verified = client.call("models.verify", {"model": MODEL})
        if not (verified.get("result") or {}).get("ok"):
            record = {"harness": "w5-7-upscale-corpus", "started": started,
                      "capability": state, "verdict": "not-runnable",
                      "reason": f"{MODEL} failed verification: "
                                f"{verified.get('result') or verified.get('error')}"}
            args.out.parent.mkdir(parents=True, exist_ok=True)
            args.out.write_text(json.dumps(record, indent=2), encoding="utf-8")
            print(record["reason"])
            return 2

        args.temp_dir.mkdir(parents=True, exist_ok=True)
        with tempfile.TemporaryDirectory(prefix="rs-upscale-corpus-",
                                         dir=args.temp_dir) as tmp:
            temp = Path(tmp)
            for index, item in enumerate(args.sample):
                label, _, raw = item.partition("=")
                path = Path(raw).expanduser()
                if not path.is_file():
                    raise SystemExit(f"{label}: not a file: {path}")
                # A fixed seed per position makes a rerun of the same corpus
                # reproduce the same pairs instead of resampling the noise.
                row = run_sample(client, label, path, args.jobs_root, temp,
                                 args.job_timeout, args.degradation,
                                 args.seed + index)
                if args.record_paths:
                    row["path"] = str(path)
                records.append(row)
                print(f"{label}: {row.get('reference')} -> "
                      f"{row.get('output')} psnr={row.get('psnr')} "
                      f"seam={row.get('seamPsnr')} "
                      f"control={row['controlBicubicPsnr']}", flush=True)
    finally:
        client.close()

    judged = [row for row in records if isinstance(row.get("psnr"), (int, float))]
    failures = [row["label"] for row in records if row not in judged]
    below = [row["label"] for row in judged if row["psnr"] < args.min_psnr]
    margin = (args.control_margin if args.control_margin is not None
              else (CONTROL_MARGIN if args.degradation == "realistic" else 0.0))
    # A margin of 0 keeps the original, strict "must beat the control" wording;
    # a positive margin is the replacement gate's "beat it by at least".
    control_losses = [
        row["label"] for row in judged
        if (row["psnr"] - row["controlBicubicPsnr"]) < margin
        or (margin <= 0 and row["psnr"] <= row["controlBicubicPsnr"])]
    below_dimensions = [row["label"] for row in records
                        if row.get("dimensionsExact") is False]
    versions = sorted({str(row.get("modelVersion")) for row in judged})
    verdict = ("pass" if judged and not failures and not below
               and not control_losses and not below_dimensions
               and versions == ["1.0.0"] else "fail")
    if verdict == "fail":
        exit_code = 1
    summary = {
        "harness": "w5-7-upscale-corpus",
        "started": started,
        "finished": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        "capability": f"{CAPABILITY} supported",
        "model": {"id": MODEL, "versions": versions},
        "contract": {
            "srgbFirst": True, "cropMultiple": 4,
            "degradation": args.degradation,
            "downscale": "bicubic x4",
            "noiseSeeds": ([row.get("degradation", {}).get("seed")
                            for row in records]
                           if args.degradation == "realistic" else None),
            "psnr": "8-bit gamma-encoded sRGB code values, RGB, RMS over all "
                    "channels",
            "seamBand": SEAM_BAND, "seamStep": TILE_STEP * SCALE,
            "seamThreshold": "none (diagnostic only)",
        },
        "gate": {"minPsnr": args.min_psnr,
                 "appliedTo": "every image, not the mean",
                 "control": ("the model must beat bicubic x4 on the same pair"
                             if margin <= 0 else
                             f"the model must beat bicubic x4 on the same "
                             f"pair by >= {margin} dB"),
                 "controlMargin": margin,
                 "source": ("Decision A1, owner-approved 2026-11-18; "
                            "bicubic-control gate withdrawn and replaced by "
                            "the realistic-degradation gate by the project "
                            "manager 2026-11-18" if args.degradation ==
                            "realistic" else
                            "Decision A1, owner-approved 2026-11-18")},
        "images": records,
        "aggregate": {
            "count": len(records),
            "minimum": min((row["psnr"] for row in judged), default=None),
            "mean": round(sum(row["psnr"] for row in judged) / len(judged), 2)
                    if judged else None,
            "median": round(sorted(row["psnr"] for row in judged)[len(judged) // 2], 2)
                      if judged else None,
            "belowBar": below,
            "controlLosses": control_losses,
            "notMeasured": failures,
            "dimensionFailures": below_dimensions,
        },
        "verdict": verdict,
    }
    args.out.parent.mkdir(parents=True, exist_ok=True)
    args.out.write_text(json.dumps(summary, indent=2), encoding="utf-8")
    print(json.dumps(summary["aggregate"], indent=2))
    print(f"verdict: {verdict} (record: {args.out})")
    return exit_code


if __name__ == "__main__":
    sys.exit(main())
