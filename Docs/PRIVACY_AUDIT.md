# Retouch Studio — Network Privacy Audit

**Document type:** Phase 5 network audit (static inventory + runtime sampling)
**Build audited:** `Retouch Studio.app` assembled by `./build.sh release` on 2026-11-07 (bundle identifier `local.retouchstudio.app`, version 2.1, build 3)
**Audit date:** 2026-11-07
**Machine:** MacBook Air M3, 16 GB, macOS 26.6.2 (arm64)
**Companion documents:** [`AI_RUNTIME.md`](AI_RUNTIME.md) (install, offline use, dependencies), [`PHASE5_ACCEPTANCE.md`](PHASE5_ACCEPTANCE.md) (Phase 5 acceptance report)

This audit answers one requirement from the Phase 0 specification:

> No cloud inference. No automatic external image uploads. No hidden network requests. Explicit consent before model downloads.

The result is a measured claim, not an assertion about intent: every scenario below was executed on the shipping bundle and the sockets of the app and its helper were sampled while it ran.

> **Update for the stabilization branch (2026-11-10).** The on-demand protocol-v2 runtime installer was added after the 1.0.0 tag (`c32eb0b feat: download the local AI runtime on demand`). It is disabled in the current build because no official protocol-v2 package has been approved: `AIRuntime.package` is nil, so Settings offers no runtime download and no runtime transfer occurs. The installer code, once an approved package is configured, downloads one fixed archive with an ephemeral `URLSession` only after the model manager shows its name, size and SHA256, verifies both size and hash, and installs it under `~/Library/Application Support/RetouchStudio/AI/runtimes/protocol-v2`. The `v1.0.0` tag does not contain `AIRuntimeInstaller.swift`; the `RetouchStudio-1.0.0-ai-runtime-arm64.zip` asset on that release page is a legacy archive, not a verified protocol-v2 package. A published binary cannot be tied to a source commit from this repository alone, so this document makes no claim that a released 1.0.0 binary fetched a runtime. The static inventory in §2.1 describes the audited 2.1 build; every other conclusion below still applies to that build.

---

## 1. Scope

| Layer | Source | Runs as |
|---|---|---|
| App | `Sources/RetouchStudio/` (SwiftUI) | `Retouch Studio.app/Contents/MacOS/RetouchStudio` |
| Helper | `worker/retouch_ai_worker/` (the separate checkout the bundler copies from) | `Contents/Resources/Worker/.../Python -m retouch_ai_worker serve` |
| Downloader | `retouch_ai_worker/downloads.py` | Same interpreter, started by the app only after consent |

Image editing, masking, upscaling and export all happen in the app or in the helper. No other process is launched by the app. The helper is a child of the app and is recorded in `~/Library/Application Support/RetouchStudio/AI/helper-owner.json`.

---

## 2. Static inventory

### 2.1 The audited 2.1 app had no network API

(For the disabled stabilization-branch runtime downloader, see the update at the top of this document.)

Every framework imported by the app:

```
AppKit, Combine, CoreGraphics, CoreImage, CoreVideo, Foundation,
ImageIO, SwiftUI, UniformTypeIdentifiers, Vision
```

A search for `URLSession`, `NSURLConnection`, `NWConnection`, `CFStream`, `import Network`, `http://` and `https://` across `Sources/` and `Tests/` returns no hits. Image I/O, Vision and Core Image are local frameworks; none of them uploads.

### 2.2 The helper's only networking is the downloader

| File | Network-capable code | Purpose |
|---|---|---|
| `retouch_ai_worker/__main__.py` | `import socket` | `AF_UNIX` client for the `_call` QA command; `serve` uses the same family |
| `retouch_ai_worker/server.py` | `socketserver.ThreadingUnixStreamServer` | Local JSON-RPC over a Unix socket |
| `retouch_ai_worker/downloads.py` | `urllib.request`, `urllib.error` | Model downloads only |
| `retouch_ai_worker/catalog.py` | URL strings | Download sources for the four models; never fetched by the assistive/catalog methods |

There is no `AF_INET` anywhere in `retouch_ai_worker/`. The same search for `requests`, `httpx`, `urlopen`, `http.client` and `HTTPSConnection` matches only the two `urllib` imports in `downloads.py`.

Models are loaded from local paths. The Swin2SR loader uses `from_pretrained(<local directory>)`, not a hub identifier, so a job cannot reach the network through Transformers.

### 2.3 Downloads are consent-gated and verified

`downloads.py` documents and enforces the flow:

1. `models.plan` returns a manifest (file list, sizes, SHA256) plus its hash.
2. The app shows the exact manifest in a sheet — file count, total size, license — and the consent text states that this is the only step that uses the internet.
3. The downloader is launched with `--yes` and the approved `--consent-hash`. If the catalog changed after the sheet was shown, the hash no longer matches and nothing is downloaded.
4. Each file is written under `<root>/.staging/...`, hashed, and only moved into place when the SHA256 matches. A partial download can never be treated as an installed model.

`ConsentStore` records the approved manifest and a timestamp in `~/Library/Application Support/RetouchStudio/AI/download-consent.json`.

---

## 3. Runtime sampling

### 3.1 Method

Two process IDs were sampled — the app and the helper that it started:

```bash
# every 0.2 s, for the length of each scenario
lsof -nP -a -p <app-pid>,<helper-pid> -iTCP -iUDP
```

`lsof` reports every TCP/UDP endpoint owned by the process, including listening sockets and established connections. Each sample below is the deduplicated set of lines collected over the whole window. The sampler script is reproduced in §5.

The app was launched directly with `RETOUCH_AI_MODELS=/path/to/models` so the helper had real weights for the edit scenario.

### 3.2 Results

| # | Scenario | Window | Process IDs | Unique TCP/UDP endpoints |
|---|---|---|---|---|
| A | Launch and idle (helper self-test completed) | 10 s | app + helper | **0** (0 samples) |
| B | Real 4× upscale job through the helper | 25 s | app + helper | **0** (0 samples) |
| C | Explicit, consented model download | 47 samples | downloader | **2**, both TCP/443 (see §3.3) |

Scenario B executed a real Swin2SR job on the bundled runtime: health returned `ok`, the job reached `succeeded`, output size `[256, 256]` at 4×, device `mps`, compute time 0.55 s. Model loading includes PyTorch, Transformers and ONNX Runtime — all of them resolved files locally.

Scenario C downloaded `migan_pipeline_v2.onnx` (28,079,181 bytes) into an isolated temporary HOME so the real installed model set was untouched. It produced the only network traffic in the entire audit.

### 3.3 The two connections, identified

Raw lines from the final run:

```
Python  21839  ...  IPv4  ...  TCP 10.0.0.2:59052->52.222.136.117:443 (ESTABLISHED)
Python  21839  ...  IPv4  ...  TCP 10.0.0.2:59055->15.237.164.118:443 (ESTABLISHED)
```

- `52.222.136.117` resolves to `server-52-222-136-117...cloudfront.net`, and `dig +short huggingface.co` returns the same address range (`52.222.136.38/.89/.92/.117`). This is the HTTPS endpoint for the `migan` source in `catalog.py`.
- `15.237.164.118` resolves to an EC2 host in `eu-west-3`, the CloudFront origin. It carries the redirect/transfer, not a second service.

An earlier run of the same scenario produced the same pair of CDN addresses (`52.222.136.89`, `15.236.34.207`). No other endpoint appeared in either run.

### 3.4 A finding that came out of this audit

The first live launch after signing invalidated the bundle signature: Python wrote 378 `__pycache__` directories into `Contents/Resources/Worker`, adding files that the seal never covered. `codesign --verify` reported “a sealed resource is missing or invalid”.

That is not a network leak, but it breaks the integrity guarantee the signature is supposed to provide, so it was fixed before this document was finalised:

- the bundled launch environment now sets `PYTHONDONTWRITEBYTECODE=1` (`Sources/RetouchStudio/Core/AIWorker.swift`), so bytecode stays in memory;
- `Tools/bundle-worker.sh` deletes any `__pycache__`/`*.pyc` left inside a cached runtime before reusing it.

After the fix, the signature verified cleanly **after** an idle launch, **after** the upscale job, and **after** the download, with zero `__pycache__` directories in the bundle.

---

## 4. Limitations of this audit

1. **Sampling, not packet capture.** `lsof` polled every 0.2 s can miss a connection shorter than one polling interval. The static inventory in §2 is the compensating evidence: there is no network API for such a connection to use outside `downloads.py`.
2. **DNS is not attributed to the process.** Resolution goes through the system resolver (`mDNSResponder`), so UDP/53 does not appear against the app's PID. DNS lookups occur only for the download URL, in the same window as the two connections above.
3. **Own machine only.** This was measured on the Mac the app was built on. The claim it supports is about the shipping code paths, which are identical elsewhere; a clean-machine install test is listed as a release follow-up in `PHASE5_ACCEPTANCE.md`.
4. **No privileged tracing.** `tcpdump`/DTrace were not used; running them would require root and add little for a code base with no outbound API outside the downloader.

---

## 5. Reproduction

```bash
# Build and launch
./build.sh release
RETOUCH_AI_MODELS="/path/to/models" \
  "Retouch Studio.app/Contents/MacOS/RetouchStudio" &

APP=$(pgrep -x RetouchStudio | head -1)
HELPER=$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["workerPID"])' \
  "$HOME/Library/Application Support/RetouchStudio/AI/helper-owner.json")

# Sample sockets (idle, or while a job runs)
END=$((SECONDS+10))
while [ "$SECONDS" -lt "$END" ]; do
  lsof -nP -a -p "$APP,$HELPER" -iTCP -iUDP 2>/dev/null | tail -n +2
  sleep 0.2
done | sort -u

# Consented download in an isolated HOME (nothing real is touched)
mkdir -p /tmp/rs-audit-home
W="Retouch Studio.app/Contents/Resources/Worker"
env -i HOME=/tmp/rs-audit-home PATH=/usr/bin:/bin \
  PYTHONHOME="$PWD/$W/Python.framework/Versions/3.13" \
  PYTHONPATH="$PWD/$W:$PWD/$W/site-packages" PYTHONNOUSERSITE=1 \
  "$W/bin/python3" -m retouch_ai_worker models download migan --yes
```

The downloader prints a JSON progress object on stderr for every chunk; the last object reports `received == total == 28079181`.

---

## 6. Verdict

| Requirement | Result |
|---|---|
| No cloud inference | **Pass** — inference runs in the local helper; zero sockets during a real job |
| No automatic external image uploads | **Pass** — no upload API exists in app or helper; images never leave the machine |
| No hidden network requests | **Pass** — zero sockets in idle and edit windows; the only traffic in the audit was the explicitly approved download |
| Explicit consent before model downloads | **Pass** — manifest hash shown and required; checksum verified; staged and atomic |
| Offline after installation | **Pass** — edit, upscale and export need no network (scenario B) |

The only outbound connections the audited 2.1 build can make are the HTTPS transfers of a model download that the owner approved, after the exact manifest was displayed. The stabilization branch adds a runtime-download code path, but it is disabled (`AIRuntime.package` is nil) and makes no transfer in the current build; an enabled approved package would add one equally explicit, SHA256-verified transfer from a single fixed release URL.
