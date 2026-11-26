# Retouch Studio — Network Privacy Audit

**Document type:** Phase 5 network audit (static inventory + runtime sampling)
**Build audited:** `Retouch Studio.app` assembled by `./build.sh release` on 2026-11-07 (bundle identifier `local.retouchstudio.app`, version 2.1, build 3)
**Audit date:** 2026-11-07
**Machine:** MacBook Air M3, 16 GB, macOS 26.6.2 (arm64)
**Companion documents:** [`AI_RUNTIME.md`](AI_RUNTIME.md) (install, offline use, dependencies), [`PHASE5_ACCEPTANCE.md`](PHASE5_ACCEPTANCE.md) (Phase 5 acceptance report)

This audit answers one requirement from the Phase 0 specification:

> No cloud inference. No automatic external image uploads. No hidden network requests. Explicit consent before model downloads.

The result is a measured claim, not an assertion about intent: every scenario below was executed on the shipping bundle and the sockets of the app and its helper were sampled while it ran.

> **Update for the stabilization branch (2026-11-10).** The on-demand protocol-v2 runtime installer was added after the 1.0.0 tag (`c32eb0b feat: download the local AI runtime on demand`). It is disabled in the current build because no official protocol-v2 package has been approved: `AIRuntime.package` is nil, so Settings offers no runtime download and no runtime transfer occurs. The installer code, once an approved package is configured, downloads one fixed archive with an ephemeral `URLSession` only after a sheet shows its name, its size and a 16-character SHA256 prefix; it then verifies the full size and hash and installs it under `~/Library/Application Support/RetouchStudio/AI/runtimes/protocol-v2`. The `v1.0.0` tag does not contain `AIRuntimeInstaller.swift`; the `RetouchStudio-1.0.0-ai-runtime-arm64.zip` asset on that release page is a legacy archive, not a verified protocol-v2 package. A published binary cannot be tied to a source commit from this repository alone, so this document makes no claim that a released 1.0.0 binary fetched a runtime. The static inventory in §2.1 describes the audited 2.1 build; every other conclusion below still applies to that build.

---

## 1. Scope

| Layer | Source | Runs as |
|---|---|---|
| App | `Sources/RetouchStudio/` (SwiftUI) | `Retouch Studio.app/Contents/MacOS/RetouchStudio` |
| Helper | `worker/retouch_ai_worker/` (tracked in this repository; see the note under this table) | `Contents/Resources/Worker/.../Python -m retouch_ai_worker serve` |
| Downloader | `retouch_ai_worker/downloads.py` | Same interpreter, started by the app only after consent |

This row read "(the separate checkout the bundler copies from)" until
2026-11-18; that was wrong, not stale-by-degree — the package is tracked in this
repository at `worker/retouch_ai_worker/` and `Tools/bundle-worker.sh:16` copies
from `$REPO_ROOT/worker` unless told otherwise. Nothing about the privacy
conclusion changes: the same helper, the same boundary, one fewer source a
reviewer would have to trust by name. See `AI_11_ARCHITECTURE.md` §17.

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
2. The app shows a sheet with the file count, total size and license — not a per-file list or SHA256 — and the consent text states that this is the only step that uses the internet. The approved manifest hash is passed to the downloader, not displayed.
3. The downloader is launched with `--yes` and the approved `--consent-hash`. If the catalog changed after the sheet was shown, the hash no longer matches and nothing is downloaded.
4. Each file is written under `<root>/.staging/...`, hashed when the catalog provides a SHA256, and moved into place only when it matches. The SAM 2.1 tiny entry has no SHA256, so that file is moved without a checksum check. A partial download can never be treated as an installed model.

   **Closed 2026-11-18, kept as written.** That sentence was true when this
   audit ran. SAM 2.1 tiny's checkpoint gained a recorded size and SHA-256 in
   PR #83, so it is now hashed before the move like every other pinned file —
   and nothing fetches it, because the entry's `unverifiableReason` refuses the
   download for the separate reason that no locked package can load those
   weights ([`AI_RUNTIME.md`](AI_RUNTIME.md) §6.2).

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

**Dated correction, 2026-11-24 (append-only; the measurement above is kept as the record of what was
observed on its date).** Everything in §3.2–§3.3 was correct on the date it was measured: at that time the
TLS connection for a catalogue download terminated at a `huggingface.co` address backed by CloudFront, and
the two addresses above are what the sampler saw. The topology has since changed, and this document must be
read with that change in mind:

- **The recorded endpoint was accurate when written.** It is not retracted here, and nothing about the
  consent gate, the size-and-SHA-256 check, or "no other endpoint appeared" is being restated.
- **As of 2026-11-23 the chain terminates at a different host.** A header-only probe of the ten catalogue
  file URLs ([`W5_SCOPE_AUDIT_2.0.0.md`](W5_SCOPE_AUDIT_2.0.0.md) §12.2) shows that
  `huggingface.co/…/resolve/main/…` now answers `HTTP 302` to `us.aws.cdn.hf.co` for binary assets and
  `HTTP 307` to a `huggingface.co` cache path for config JSON. Nine of the ten redirect; the tenth
  (`sam2.1_hiera_tiny.pt` on `dl.fbaipublicfiles.com`) answered `200`. So a fetch that succeeds today ends
  on a CDN host that §3.3 does not name, and the privacy statement's "single source host per file" framing
  no longer describes the network the design would use.
- **Today the app refuses those hops, so no model download completes.** `ModelStore` answers every
  redirect with a refusal (and the Windows side sets `AllowAutoRedirect = false`), which means the traffic
  described in scenario C cannot occur at all in the current build — the download fails before a byte is
  transferred or hashed. That is defect **R1** in [`W5_SCOPE_AUDIT_2.0.0.md`](W5_SCOPE_AUDIT_2.0.0.md) §7.4.
  The consequence for this document is narrow: the audit's *traffic* conclusion gets stronger, not weaker,
  because the audited outbound transfer is currently unreachable.
- **What the intended fix would change about this statement — NOT IMPLEMENTED.** The proposed remediation
  (R1) replaces the unconditional refusal with a **host-and-path-class allow-list**: a redirect is followed
  only toward an explicitly declared host *and* path class recorded beside the catalogue entry, integrity
  stays gated by the pinned `SHA-256` and byte size rather than by the hop count, and the consent sheet
  discloses the **terminal destination** alongside the size and licence it already shows. If and when that
  lands, §3.3 gains a second permitted terminal host class, and the sentence "the only outbound connections
  … are the HTTPS transfers of a model download that the owner approved" (§6) keeps its meaning but its
  host set widens from one origin to a declared allow-list. **This is a proposal in the audit, not
  behaviour in any shipped or built code: NOT IMPLEMENTED.** Until it is implemented and re-sampled, no
  released build makes a CDN connection.
- **The audit's other privacy conclusions are unchanged.** No telemetry, no analytics, no crash-reporting
  service, no background request, no cloud inference, no image upload: none of these moved. This was
  re-checked against the current tree on 2026-11-24 by grepping `Sources/`, `Windows/` and `Tools/` for
  telemetry/analytics/crash-reporting vendors and for hard-coded remote hosts. The result was zero
  telemetry or analytics call sites; the only remote hosts in first-party code are the model-download URLs
  in `Resources/model-catalog.json` (`huggingface.co`, `dl.fbaipublicfiles.com`), the documentation URLs
  they point at, `https://www.python.org/ftp/python/` in `Tools/bundle-worker.sh` (a build-time interpreter
  fetch, not app code), loopback `http://127.0.0.1` (the worker socket), XML namespace URIs that are
  identifiers and never fetched, and `https://example.com` in test fixtures. `Tools/build-windows.ps1` sets
  `DOTNET_CLI_TELEMETRY_OPTOUT=1`, which opts *out* of the .NET CLI's own telemetry at build time and is
  not app behaviour. The static inventory in §2 and the verdict table in §6 therefore still stand.

### 3.4 A finding that came out of this audit

The first live launch after signing invalidated the bundle signature: Python wrote 378 `__pycache__` directories into `Contents/Resources/Worker`, adding files that the seal never covered. `codesign --verify` reported “a sealed resource is missing or invalid”.

That is not a network leak, but it breaks the integrity guarantee the signature is supposed to provide, so it was fixed before this document was finalised:

- the bundled launch environment now sets `PYTHONDONTWRITEBYTECODE=1` (`Sources/RetouchStudio/Core/AIWorker.swift`), so bytecode stays in memory;
- `Tools/bundle-worker.sh` deletes any `__pycache__`/`*.pyc` left inside a cached runtime before reusing it.

After the fix, the signature verified cleanly **after** an idle launch, **after** the upscale job, and **after** the download, with zero `__pycache__` directories in the bundle.

> **Dated addendum, 2026-11-26 (append-only; the record above is kept as written).** Two
> qualifications to the first bullet. (1) The tree now sets `PYTHONDONTWRITEBYTECODE=1` at
> two shipped sites, not one: besides the `AIWorker.swift` bundled-root branch (`:585-588`
> at `d4ada2ac`, applied after the inherited environment is copied at `:578`),
> `Sources/RetouchStudio/Core/AIRuntimeValidation.swift:210` sets it unconditionally inside
> `environment(for root:)` (`:202-221` at the same revision), so a validation-driven launch
> cannot start a Worker without it. (2) Both sites are environment configuration only. A
> `git grep -E 'codesign|SecCode|SecStaticCode|CSFlag'` restricted to `Sources/` at
> `d4ada2ac` returns no matches, so no shipped code path verifies the bundle seal or detects
> tampering at runtime: this fix prevents the 2026-11-07 residue class from recurring, and
> seal verification against other in-bundle writes remains an offline-gate responsibility
> (see `CI_GATES.md` and the signature-probe records cited in `POST_RELEASE_ROADMAP.md`
> item I10), not app behaviour.

---

## 4. Limitations of this audit

1. **Sampling, not packet capture.** `lsof` polled every 0.2 s can miss a connection shorter than one polling interval. The static inventory in §2 was the compensating evidence *for that build*: it had no network API in the app itself, only `downloads.py` in the worker. The stabilization tree has since grown `URLSession` call sites in four files — `AIRuntimeInstaller`, `UpdateController`, `UpdateVerification`, `ModelStore`; `ModelManager` and `AIRuntimeInstallPhase` only name the type in comments — each consent- or user-initiated. The **runtime and update paths are unreachable in the shipping configuration** (`AIRuntime.package` is nil; `Info.plist` declares no feed). **Model-weight downloads are reachable** from the model manager for a catalog entry that is `.ready` and whose catalog version is not installed, and only after the per-model consent alert that names files, size and licences. The current inventory and its gates are in [TECHNICAL_AUDIT.md §8.1](TECHNICAL_AUDIT.md).
2. **DNS is not attributed to the process.** Resolution goes through the system resolver (`mDNSResponder`), so UDP/53 does not appear against the app's PID. DNS lookups occur only for the download URL, in the same window as the two connections above.
3. **Own machine only.** This was measured on the Mac the app was built on. The claim it supports is about the shipping code paths, which are identical elsewhere; a clean-machine install test is listed as a release follow-up in `PHASE5_ACCEPTANCE.md`.
4. **No privileged tracing.** `tcpdump`/DTrace were not used; running them would require root and add little for a build whose only outbound calls came from the downloader.

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
| Explicit consent before model downloads | **Pass** — consent sheet shown and the approved manifest hash required; checksums verified where the catalog provides one (SAM 2.1 tiny has none); staged and atomic |
| Offline after installation | **Pass** — edit, upscale and export need no network (scenario B) |

**Addendum 2026-11-18.** This table's consent row and §4's item 4 both say SAM
2.1 tiny has no checksum. That is what the catalog held while the audit ran. PR
#83 pinned that checkpoint's measured size and SHA-256, so the parenthetical no
longer describes the shipped catalog and the file is hashed before its move. The
consent path is unchanged and no SAM download is offered: the entry refuses it
because nothing in `worker/requirements.lock` can load those weights
([`AI_RUNTIME.md`](AI_RUNTIME.md) §6.2).

The only outbound connections the audited 2.1 build can make are the HTTPS transfers of a model download that the owner approved, after a sheet showing the file count, total size and license was accepted. The stabilization branch adds a runtime-download code path, but it is disabled (`AIRuntime.package` is nil) and makes no transfer in the current build; an enabled approved package would add one equally explicit, SHA256-verified transfer from a single fixed release URL.
