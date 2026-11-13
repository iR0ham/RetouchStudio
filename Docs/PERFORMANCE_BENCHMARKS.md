# Performance Benchmarks — 1.0 (macOS)

**Status:** measured on the host below, at commit `0403e59` plus the benchmark
harness and the Vision input change described here. This is an observation
report, not a gate: the harness is deliberately outside `Tests/run.sh`, and no
test fails on a timing. Windows numbers are not included; none have been
produced. See [Not measured](#not-measured) before quoting any figure.

## Host and build

| | |
|---|---|
| Machine | Apple M3, 16 GB unified memory |
| OS | macOS 27.2 (build 26B123) |
| Toolchain | Swift 6.4.2 Command Line Tools, `swiftc -O`, arm64 |
| Image stack | Core Image with `extendedLinearSRGB` working space, GPU path (`useSoftwareRenderer: false`), intermediate caching on |
| Render path | `ExportService.render` → `ExportService.writeResult`, JPEG/PNG via ImageIO |

## What is measured

`./Tests/run-benchmarks.sh` builds the app sources and `StudioCore`, then runs
`Tests/Benchmarks.swift` as a command-line process. Inputs, in order:

1. synthetic 12 MP (4000×3000) JPEG, quality 0.9;
2. synthetic 24 MP (6000×4000) JPEG, quality 0.9;
3. synthetic 48 MP (8000×6000) JPEG, quality 0.9;
4. synthetic 12 MP 16-bit PNG (rendered through `.RGBA16`);
5. up to three real JPEGs from `RETOUCH_BENCH_REAL_DIR`.

Synthetic frames are deterministic (fixed noise seed) and contain no face, so
the analysis and mask stages are only reported for real photos. Real photos are
private, are never copied into the repository, and are labelled by their file
name here; they live in `~/Documents/image test` on the author's machine.

Stages:

- **load** — decode, orientation bake, preview render, face detection,
  preview-scale masks, zero-adjustment preview render (`ImageProcessor.load`),
  median of 3 runs after one untimed warm-up load;
- **preview** — `process` with the benchmark adjustments plus a preview-scale
  render, median of 3;
- **analysis** — 512 px analysis buffer plus `SmartAnalyzer.analyze`, median of 3
  (faces present only);
- **masks** — full-resolution `buildMasks` at the export mask dimension
  (4096), median of 3 (faces present only);
- **export** — full-resolution `ExportService.render` plus `writeResult`,
  median of 2;
- **batch4** — four sequential render+write cycles, one observation.

The benchmark adjustments are the same for every input: smooth 40, texture 50,
tone 30, eye brighten/sharpen 20/10, teeth 15, face width 5, exposure 6,
contrast 8, vibrance 6, JPEG quality 0.92, privacy stripping on, no stamps, no
AI upscale.

Results are written to `build/benchmarks/latest.json` (git-ignored).

## Results

Resident memory is the process RSS immediately after the third load of that
input. The harness clears the Core Image cache between images, because the app
holds one document at a time.

| input | size | depth | faces | load | preview | analysis | masks | export | batch4 | RSS after load |
|---|---|---|---|---|---|---|---|---|---|---|
| 12mp | 4000×3000 | 8 | 0 | 0.022 s | 0.003 s | — | — | 0.079 s | 0.299 s | 234 MB |
| 24mp | 6000×4000 | 8 | 0 | 0.040 s | 0.003 s | — | — | 0.061 s | 0.233 s | 239 MB |
| 48mp | 8000×6000 | 8 | 0 | 0.075 s | 0.005 s | — | — | 0.114 s | 0.423 s | 296 MB |
| 12mp-16bit | 4000×3000 | 16 | 0 | 0.376 s | 0.004 s | — | — | 1.998 s | 7.848 s | 686 MB |
| IMG_7196 | 12 MP | 8 | 1 | 0.065 s | 0.023 s | 0.031 s | 0.266 s | 0.557 s | 1.836 s | 1417 MB |
| IMG_7198 | 12 MP | 8 | 1 | 0.065 s | 0.022 s | 0.034 s | 0.259 s | 0.438 s | 1.727 s | 2485 MB |
| IMG_7203 | 12 MP | 8 | 1 | 0.066 s | 0.024 s | 0.039 s | 0.297 s | 0.427 s | 1.702 s | 2538 MB |

Peak RSS reported at the end of the run: 3576 MB. That number is a high-water
mark across seven documents in one process and is discussed below; it is not
the cost of one document.

### What the numbers say

- **Load is network-free and fast.** A 48 MP JPEG opens in 75 ms; the preview
  render is 3–25 ms, so slider feedback is dominated by the preview pipeline,
  not decoding.
- **Mask building is the first-edit cost.** On a 12 MP portrait, building the
  full-resolution mask set takes 0.26–0.30 s, roughly eight times the analysis
  pass and a dozen preview renders. This runs on export, not on every
  slider move, and the preview-scale set (1024) is what the editor uses.
- **JPEG export is sub-second** on 12 MP portraits (0.43–0.56 s) and 61–114 ms
  on synthetic frames.
- **The 16-bit path is the outlier.** Load is 9× and export roughly 4–5× the
  8-bit cost at the same dimensions, and a four-item 16-bit batch takes 7.8 s.
  16-bit PNG is a deliberate precision feature, not the default; this is the
  honest price.
- **Batch cost scales linearly**: four exports in one process cost about 3.3–3.9
  single exports, because the mask set is rebuilt per item.

## Memory findings

The probe modes exist because the first run showed resident memory climbing
linearly with every document. Each mode was run as its own process on the
24 MP synthetic frame (no faces):

| probe | pattern | result |
|---|---|---|
| `decode` | ImageIO decode only, 8 cycles | flat at 121 MB |
| `render` | decode once, 8 full exports | +1.4 MB per cycle (203 MB after 8) |
| `vision` | 8 × face detection on one `CGImage` preview | **+10.6 MB per call** (192 → 267 MB) |
| `vision-buffer` | 8 × the same request on one `CVPixelBuffer` | **flat at 193 MB** |
| `1` (before fix) | 8 × full load + export | +10.7 MB per cycle |
| `1` (after fix) | 8 × full load + export | +16 MB per cycle, still linear |
| `clear` (after fix) | as above, `clearCaches()` after every cycle | baseline drops, slope unchanged |
| `load` at preview 512 / 1024 / 2048 | 8 × load, no export | identical slope at every preview size |

**Fixed:** `FaceAnalyzer` used to hand Vision a `CGImage`. On this OS each
handler retained roughly one preview-sized surface per call. The analyzer now
draws the preview into a reused BGRA `CVPixelBuffer` and feeds that to Vision.
The face counts on the three real portraits are unchanged (one face each).

**Not fixed, not attributed:** the full load path still grows by about 16 MB per
document in this command-line probe. The growth is independent of preview size,
survives `clearCaches()`, and does not appear in decode-only or render-only
loops, so it is not the Core Image intermediate cache and not our retained
`LoadResult`. Whether the GUI app exhibits the same growth over a long session
is **NOT VERIFIED**; the app holds one document and one mask set at a time, and
replacing the document releases those objects. The 2.5 GB RSS in the table is
therefore a cumulative high-water mark of a synthetic seven-document process,
not a per-photo figure. Attributing the residual needs Instruments or `heap`
against a live app session, which has not been run.

## Not measured

- **Windows** load/export/AI timings — no Windows runner has executed this
  harness, and no figure here applies to Windows.
- **AI runtime execution** — the bundled runtime is not installed in this
  environment; upscale, background removal, generative fill and scene analysis
  timings are **NOT VERIFIED**.
- **Cold and warm app startup** — the harness measures engine stages, not the
  SwiftUI process launch.
- **GPU utilization and energy** — only wall-clock time and RSS are recorded.
- **8 GB machines, Rosetta, HEIC output, XMP round-trip exports, 48 MP real
  portraits, and batch UI overhead** — none were exercised here.
- **Performance on very large face counts** — every real photo used has one
  face.

## Reproduce

```bash
./Tests/run-benchmarks.sh                                   # arm64 host
RETOUCH_ARCH=x86_64 ./Tests/run-benchmarks.sh               # Rosetta
RETOUCH_BENCH_REAL_DIR="$HOME/Pictures" ./Tests/run-benchmarks.sh
RETOUCH_BENCH_MEMORY_PROBE=1 ./Tests/run-benchmarks.sh      # repeated load+export
RETOUCH_BENCH_MEMORY_PROBE=clear ./Tests/run-benchmarks.sh  # plus cache clear
RETOUCH_BENCH_MEMORY_PROBE=load ./Tests/run-benchmarks.sh   # load only
RETOUCH_BENCH_MEMORY_PROBE=render ./Tests/run-benchmarks.sh # decode once, export only
RETOUCH_BENCH_MEMORY_PROBE=decode ./Tests/run-benchmarks.sh # ImageIO only
RETOUCH_BENCH_MEMORY_PROBE=vision ./Tests/run-benchmarks.sh # CGImage detection
RETOUCH_BENCH_MEMORY_PROBE=vision-buffer ./Tests/run-benchmarks.sh
RETOUCH_BENCH_PREVIEW=1024 RETOUCH_BENCH_MEMORY_PROBE=load ./Tests/run-benchmarks.sh
```

Timings depend on host load, thermal state and the GPU; compare only runs from
the same machine and session, and never regenerate golden-corpus baselines to
make this harness look better.
