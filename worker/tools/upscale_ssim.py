"""Secondary diagnostic: SSIM for an existing upscale corpus record.

This is the script that produced the SSIM columns of
`Docs/W5_UPSCALER_ACCEPTANCE.md` §10 (the 2026-11-18 `lr` run), made
reproducible. It was ephemeral at measurement time; the arithmetic below is
unchanged and only its inputs are arguments now.

Formulation, fixed before that run and never tuned: the 8-bit sRGB luma
(Rec.601 — ``0.299 R + 0.587 G + 0.114 B``, computed from the RGB pixels as
written, no linearisation), an 11x11 Gaussian window with sigma 1.5 and
K1 = 0.01, K2 = 0.03 on the 0-255 scale, a valid-area 2-D convolution
(``torch.nn.functional.conv2d``, float32, CPU) and the mean of the SSIM map.

For each image in the record it rebuilds the true reference and the bicubic
control exactly as the harness did (sRGB conversion and crop from
`upscale_corpus.py`, the record's degradation mode and seed) and reads the
job's `upscaled.png` from the jobs root. PSNR is recomputed beside the
recorded value as a cross-check.

Usage:

  python worker/tools/upscale_ssim.py --record record.json --jobs JOBS \
      --source R1=/path/a.jpg --source C1=/path/b.jpg [...] [--out out.json]

``--source`` is required for every label in the record; paths are never
committed and the tool writes nothing but the optional JSON summary.
"""

import argparse
import importlib.util
import json
import sys
from pathlib import Path

import numpy as np
import torch
import torch.nn.functional as F
from PIL import Image

FORMULATION = ("8-bit sRGB luma (Rec.601), 11x11 Gaussian sigma=1.5, "
               "K1=0.01 K2=0.03, mean over valid area")


def _harness(path: str | None):
    """Import `upscale_corpus.py` from next to this file (or from `path`)."""
    target = (Path(path) if path
              else Path(__file__).with_name("upscale_corpus.py"))
    spec = importlib.util.spec_from_file_location("upscale_corpus", target)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def gaussian_kernel(size=11, sigma=1.5):
    coords = torch.arange(size, dtype=torch.float64) - (size - 1) / 2
    g = torch.exp(-(coords ** 2) / (2 * sigma ** 2))
    g = g / g.sum()
    return g


def ssim(a, b):
    def gray(im):
        x = np.asarray(im.convert("RGB"), dtype=np.float64)
        return (0.299 * x[..., 0] + 0.587 * x[..., 1] + 0.114 * x[..., 2])

    x = torch.from_numpy(gray(a)).float()[None, None]
    y = torch.from_numpy(gray(b)).float()[None, None]
    g = gaussian_kernel().float()
    kernel = (g[:, None] * g[None, :])[None, None]

    def filt(t):
        return F.conv2d(t, kernel)

    c1, c2 = (0.01 * 255) ** 2, (0.03 * 255) ** 2
    with torch.no_grad():
        mu_x, mu_y = filt(x), filt(y)
        sigma_x = filt(x * x) - mu_x ** 2
        sigma_y = filt(y * y) - mu_y ** 2
        sigma_xy = filt(x * y) - mu_x * mu_y
        num = (2 * mu_x * mu_y + c1) * (2 * sigma_xy + c2)
        den = (mu_x ** 2 + mu_y ** 2 + c1) * (sigma_x + sigma_y + c2)
        return float((num / den).mean())


def row_for(record_image: dict, source: Path, jobs_root: Path, hc) -> dict:
    converted, _icc = hc.to_srgb(Image.open(source))
    w, h = converted.size
    reference = converted.crop((0, 0, w - w % 4, h - h % 4))
    expected = (record_image["reference"]["width"],
                record_image["reference"]["height"])
    assert (reference.width, reference.height) == expected, (
        record_image["label"], reference.size)

    degraded, _info = hc.degrade(reference,
                                 record_image["degradation"]["mode"],
                                 record_image["degradation"]["seed"])
    control = degraded.resize(reference.size, Image.Resampling.BICUBIC)

    model = Image.open(jobs_root / record_image["jobId"] / "upscaled.png")
    model.load()

    return {
        "label": record_image["label"],
        "ssimModel": round(ssim(model, reference), 6),
        "ssimControl": round(ssim(control, reference), 6),
        "psnrModelRecomputed": round(hc.psnr(reference, model), 3),
        "psnrRecorded": record_image["psnr"],
        "psnrControlRecomputed": round(hc.psnr(reference, control), 3),
        "psnrControlRecorded": record_image["controlBicubicPsnr"],
    }


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--record", required=True,
                        help="corpus record JSON written by upscale_corpus.py")
    parser.add_argument("--jobs", required=True,
                        help="jobs root that holds <jobId>/upscaled.png")
    parser.add_argument("--source", action="append", default=[],
                        metavar="LABEL=PATH",
                        help="source file for one record label (repeatable)")
    parser.add_argument("--harness", default=None,
                        help="path to upscale_corpus.py "
                             "(default: beside this file)")
    parser.add_argument("--out", default=None,
                        help="write the JSON summary here (default: stdout only)")
    args = parser.parse_args(argv)

    sources: dict[str, Path] = {}
    for item in args.source:
        label, _, path = item.partition("=")
        if not path:
            parser.error(f"--source wants LABEL=PATH, got {item!r}")
        sources[label] = Path(path)

    record = json.load(open(args.record))
    missing = [r["label"] for r in record["images"]
               if r["label"] not in sources]
    if missing:
        parser.error("no --source for: " + ", ".join(missing))

    hc = _harness(args.harness)
    rows = []
    for record_image in record["images"]:
        row = row_for(record_image, sources[record_image["label"]],
                      Path(args.jobs), hc)
        rows.append(row)
        print(json.dumps(row), flush=True)

    summary = {"formulation": FORMULATION, "rows": rows}
    if args.out:
        json.dump(summary, open(args.out, "w"), indent=1)
        print(f"wrote {args.out}", file=sys.stderr)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
