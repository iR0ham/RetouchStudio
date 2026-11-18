"""Decision A1 quality corpus: per-image PSNR for `upscale.4x`, measured only.

The owner approved the installed `swin2sr-x4 1.0.0` and fixed one bar: the
per-image minimum PSNR over the corpus must be >= 24.0 dB, and the model must
beat a bicubic-x4 control on the same pairs. This tool measures that bar and
nothing else; it does not download, install, adopt or convert anything.

Measurement contract (fixed by the decision, restated here so a reader never
has to guess):

  1. read the source, convert it to sRGB using its embedded ICC profile;
  2. crop to a multiple of 4 (`width - width % 4`, from the top-left corner);
  3. bicubic-antialias downscale by 4 -> the degraded input `D`;
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
        --out /tmp/rs-a1/out/upscale-corpus.json

Exit codes: 0 the per-image minimum met the bar and every pair beat its
control; 1 the bar was missed; 2 the capability is not `supported`, so nothing
was measured and nothing is claimed.
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
from PIL import Image, ImageCms  # noqa: E402

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


def run_sample(client: Client, label: str, path: Path, jobs_root: Path,
               temp: Path, job_timeout: float) -> dict:
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
    degraded = reference.resize((reference.width // SCALE,
                                 reference.height // SCALE), Image.BICUBIC)
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
            for item in args.sample:
                label, _, raw = item.partition("=")
                path = Path(raw).expanduser()
                if not path.is_file():
                    raise SystemExit(f"{label}: not a file: {path}")
                row = run_sample(client, label, path, args.jobs_root, temp,
                                 args.job_timeout)
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
    control_losses = [row["label"] for row in judged
                      if row["psnr"] <= row["controlBicubicPsnr"]]
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
            "srgbFirst": True, "cropMultiple": 4, "downscale": "bicubic x4",
            "psnr": "8-bit gamma-encoded sRGB code values, RGB, RMS over all "
                    "channels",
            "seamBand": SEAM_BAND, "seamStep": TILE_STEP * SCALE,
            "seamThreshold": "none (diagnostic only)",
        },
        "gate": {"minPsnr": args.min_psnr,
                 "appliedTo": "every image, not the mean",
                 "control": "the model must beat bicubic x4 on the same pair",
                 "source": "Decision A1, owner-approved 2026-11-18"},
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
