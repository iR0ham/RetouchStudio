# Windows Implementation Path

**Status:** architecture audit and preparation. There is no Windows
application, renderer, installer or release. The `StudioCore` build, its C ABI
test and the conformance gate were executed on a native `windows-2025` runner on
2026-11-13 (see [CI_GATES.md](CI_GATES.md#verified-runs)); every Windows
application or runtime claim beyond that is **NOT VERIFIED**. macOS remains the
only shipping product.

**Date:** 2026-11-13
**Basis:** repository at `037db3a` (`main` after PR #5 and PR #7 merged; tree
identical to `16a4ab9`).

## 1. What is already reusable, unchanged

`Sources/StudioCore` imports Foundation only (boundary gate: 260 checks) and
already owns everything that is decided before pixels exist:

| Surface | Type or protocol | Location |
| --- | --- | --- |
| The saved document and edit state | `DocumentState`, `HealSpot`, `Sticker`, `AIEdit`, `AnalysisSettings`, `DocumentOrientation` | `Sources/StudioCore/DocumentValue.swift:332`, `:14`, `:36`, `:283`, `:113`, `:194` |
| Undo/redo rules | `DocumentHistory<State>` | `Sources/StudioCore/DocumentHistory.swift:19` |
| Project bytes, versions, unknown fields | `ProjectCodec`, `RetouchProject`, `ProjectWriteContext` | `Sources/StudioCore/ProjectCodec.swift:73`, `ProjectDocument.swift:10`, `ProjectCodec.swift:468` |
| Host file access | `ProjectByteStore`, `ProjectSourceAccess`, `ProjectBookmarkStore` | `Sources/StudioCore/ProjectIO.swift:12`, `ProjectPlatform.swift:12`, `ProjectPlatform.swift:17` |
| Export decisions | `RenderRequest`, `RenderPlan`, `DocumentRenderPipeline` | `Sources/StudioCore/RenderContract.swift:137`, `:209`, `:312` |
| Export and batch policy | `RenderPolicy`, `BatchRenderPolicy` | `Sources/StudioCore/RenderPolicy.swift:44`, `BatchRenderPolicy.swift:10` |
| Recovery ordering | recovery rules | `Sources/StudioCore/RecoveryRules.swift` |
| Update selection and signing descriptor | `UpdateManifest`, `UpdatePolicy` | `Sources/StudioCore/UpdateManifest.swift:7`, `:145` |

The host-side project adapters are small and almost portable already:
`FileProjectByteStore` and `FileProjectSourceAccess` use `Data`/`FileManager`
(`Sources/RetouchStudio/Models/ProjectAdapters.swift:37`, `:17`). Only
`URLBookmarkStore` (`:23`) and the exported `UTType` (`:12`) are macOS-specific.
A Windows adapter is three short protocol implementations: `FileManager`-based
byte store, path-existence check, and a bookmark store that returns `nil`
(the project also stores the absolute `imagePath`).

App-layer models that already import only Foundation and StudioCore and can be
compiled on Windows without edits: `Adjustments`, `AppSettings`,
`DocumentRestoration`, `DocumentSession`, `Localization`, `PersianL10n`,
`Recovery`, `RecoveryPolicy`, `TutorialCopy`, `UserPreset`, `DeveloperProfile`,
`Digits`, `ModelActivity`, `ModelManager`, `SliderHints`, `StatusToken`,
`ToolMode`. Everything under `Views/`, `EditorModel`, and the `Core/` engines
imports at least one Apple framework.

`Tests/run-studiocore-windows.ps1` already scans the module for platform
imports, builds it with a native Swift toolchain and runs `StudioCoreTests`.
It has never been executed on Windows, so it proves preparation, not support.

## 2. macOS-only surface and its Windows replacement

| Concern | macOS implementation | Windows requirement |
| --- | --- | --- |
| Application shell | `App.swift` (`@main`, `AppDelegate`, `NSApplication`), 24 SwiftUI views | A new shell. No SwiftUI on Windows. |
| Document coordination | `EditorModel.swift` (AppKit, Combine, SwiftUI, ImageIO, UTType) | A host view model; reuse `DocumentSession` and StudioCore values. |
| Decode and encode | ImageIO (`CGImageSource`, `CGImageDestination`) in `ImageProcessor.loadCGImageWithColorSpace` and `ExportService` | Windows Imaging Component (WIC). |
| Pixel pipeline | Core Image in `ImageProcessor.process`, `MacDocumentRenderer`, `SkinEngine`, `MakeupEngine`, `SceneEngine`, `LookEngine`, `FeatureReshaper`, `ArtRenderer`, `AnalysisRenderer` | Direct2D effects plus custom CPU kernels, or an equivalent free renderer. This is the largest parity risk. |
| Face landmarks | Vision `VNDetectFaceLandmarksRequest` in `FaceAnalyzer` | `Windows.Media.FaceAnalysis` returns boxes, not a landmark mesh. A 478-point mesh needs an ONNX/WinML model. |
| Masks | Core Graphics bitmap contexts and Core Image in `MaskBuilder` | Direct2D geometry and bitmap targets. |
| Watermark text | Core Text in `Watermark.swift` | DirectWrite. |
| Colour management | named `extendedLinearSRGB` Core Image context, ICC through ImageIO | WIC colour contexts; the portable decisions are already in `RenderColorSpace`. |
| Project storage | Application Support paths, security-scoped bookmarks | `%LOCALAPPDATA%` / `%APPDATA%`; path-based resolution; the ports above. |
| AI worker | POSIX spawn and kill in `ChildProcess`, `.app` helper layout in `AIWorker` | `CreateProcess` plus a job object; a Windows Python runtime and model provider. |
| Updates | CryptoKit Ed25519, URLSession, `ditto`, `NSWorkspace` in `UpdateVerification` / `UpdateController` | `UpdatePolicy` is portable; the Windows host needs Ed25519 (CNG or .NET), HTTPS download, zip extraction, atomic replace and relaunch. |
| Packaging | `.app`, DMG, codesign | A zip or installer plus SHA-256. No paid signing requirement. |

The pixel engine is not shareable: Core Image is an Apple framework. Any
Windows release must implement the same 17-stage contract natively. The
render-plan fixtures (`Tests/Conformance/Fixtures/canonical/render-plan-*.json`)
define the stage order and are the acceptance contract for a Windows renderer.

## 3. Minimum Windows host

1. **Shell** — one window, open/export dialogs, top bar, tool list, inspector,
   canvas with before/after, progress and cancellation. A light editor first;
   no AI, analysis or stamps until the core path is correct.
2. **Image host** — decode with WIC, read EXIF orientation and ICC, produce the
   source description (`RenderSourceDescription`).
3. **Renderer** — implement `DocumentRenderPipeline` against the portable plan:
   crop, orientation, global tone/colour, skin and local retouch, masks,
   watermark, encode. Report `RenderProgress` and the portable `RenderError`
   cases, including source-is-destination protection.
4. **Analysis and masks** — decide the parity level explicitly. A bounding-box
   face detector is enough for Auto Retouch; feature masks (eyes, teeth, lips,
   skin) need landmarks or geometric masks. Do not claim macOS parity without
   measurement.
5. **Project host** — `ProjectByteStore`, `ProjectSourceAccess`,
   `ProjectBookmarkStore` implementations over `FileManager`; `ProjectStore`
   then reads and writes the same v3/v4 bytes.
6. **Export** — WIC encode to JPEG/PNG/TIFF, privacy metadata whitelist,
   SHA-256-verified destination protection, batch naming from
   `BatchRenderPolicy`.
7. **Settings and recovery** — `%LOCALAPPDATA%` paths; reuse `RecoveryRules`
   ordering. No registry writes.
8. **Updater** — consume the existing manifest through `UpdatePolicy`; verify
   Ed25519 and SHA-256; atomic directory swap with a journal.
9. **CI** — run the portability runner and real tests on `windows-2025`;
   publish one x64 artifact (Intel and AMD both run x64).

## 4. Stack decision

| Option | UI effort | Core reuse | Verdict |
| --- | --- | --- | --- |
| Swift + Win32/WinAppSDK | Very high: SwiftUI does not exist on Windows; every view and the canvas become raw Win32/COM interop | Direct link to StudioCore | Viable only if a single language is a hard constraint |
| C#/.NET + WinUI 3 shell, Swift-built StudioCore behind a small C ABI | Low: mature XAML UI, WIC/Direct2D access, free and open source | Document, project, history, render-plan and policy stay in StudioCore | **Recommended**, conditional on the C ABI |
| Qt/C++ or Rust shell | High: full rewrite and a second ecosystem | Would need a new codec | Rejected — novelty, not a repository constraint |

The recommended split keeps the shared rules in one place and lets each host
own pixels, which is exactly the existing macOS seam (`MacDocumentRenderer` is
the only Core Image implementation of `DocumentRenderPipeline`).

### W2 stack deviation (2026-11-13)

The shell is **C# on WPF**, not WinUI 3. The split above still holds — C#/.NET
host, StudioCore behind the C ABI — and only the UI framework changed:

- WPF ships inside the .NET SDK. WinUI 3 would add the Windows App SDK
  bootstrapper, an MSIX or unpackaged-deployment story and a NuGet dependency
  chain, none of which a free, zipped, unsigned build wants.
- The host needs a window, a toolbar, a slider panel and an image surface. WPF
  covers all four without a package manager, and `BitmapSource.Create` accepts
  the BGRA8 buffer the pipeline already produces.
- WinUI 3 remains the better choice if the Windows host grows into a
  macOS-parity editor; that is a UI rewrite, not a core one.

The W2 host lives in `Windows/` and is described in
[`../Windows/README.md`](../Windows/README.md).

**Do not start by implementing the draft image-engine ABI**
(`Tests/Conformance/ABI/studioscore_image_engine.h`). It would force a Windows
Core Image equivalent in Swift. A smaller ABI is enough:

- `sc_project_read(bytes) -> canonical JSON | error`
- `sc_project_write(json, context) -> bytes | error`
- `sc_render_plan(request JSON, source description JSON) -> plan JSON | error`
- `sc_history_new / sc_history_commit / sc_history_undo / sc_history_redo`

All four are JSON-in/JSON-out over the existing canonical forms, so they can be
tested on macOS today and on Windows CI later without a UI or a renderer. The
Swift side stays Foundation-only; the shell is responsible for pixels.

## 5. Component milestones and exit criteria

| Step | Deliverable | Exit criterion |
| --- | --- | --- |
| W0 | Windows CI job in the workflow | **Met 2026-11-13:** `Windows StudioCore` green on `windows-2025` (Swift 6.4.2) |
| W1 | StudioCore C ABI v0 (project + plan + history) | Same fixtures pass on macOS and Windows; ABI smoke test compiled by conformance. macOS green; **Windows met 2026-11-13**: `ABI TESTS: PASS (86 checks)` on `windows-2025` |
| W2 | C# host: WIC decode/encode, crop, orientation, global adjustments | Byte-level contract tests against render-plan fixtures; visual deltas recorded, not assumed |
| W3 | Face analysis and masks | Auto Retouch output measured against the macOS corpus; parity level documented |
| W4 | Shell and light-editor workflow | Open, edit, undo, save project, export on a real Windows runner |
| W5 | Packaging and updater | One x64 zip plus SHA-256; updater installs a signed manifest build |
| W6 | Release | Native Windows runtime tests and artifacts published to GitHub Releases |

No step may be labelled supported before its native runner run is green.

### W1 status (2026-11-13)

A first version of the ABI exists and is proven on macOS:

| Piece | File |
| --- | --- |
| Public contract and ownership rules | `Sources/StudioCoreABI/include/studioscore_core.h` |
| Swift implementation | `Sources/StudioCoreABI/{ABISupport,ProjectABI,RenderPlanABI,HistoryABI}.swift` |
| C11 behaviour test | `Tests/ABI/abi_tests.c` + `Tests/ABI/Fixtures/*.json` |
| Build and run | `Tests/run-abi.sh` (called by `Tests/run.sh`) |
| Header-only conformance smoke | `Tests/Conformance/ABI/core_smoke.c` (compiled by `Tests/Conformance/run-conformance.sh`) |

Decisions worth keeping:

- **JSON in, JSON out.** Every payload is a byte slice; there is no Swift type
  in the contract. History states are compared byte for byte, so a host must
  pass the canonical v4 document bytes from `sc_project_read`. A v3 file
  written by `sc_project_write` is not a safe history state because v3 encodes
  analysis regions as an unordered set.
- **`@_cdecl` cannot expose a Swift struct.** Every out-parameter is `void *`
  and the entry point binds it to `ScCoreBytes`; the two-machine-word layout is
  asserted from C (`_Static_assert` in both the smoke test and `abi_tests.c`).
- **One module, two headers.** `studioscore_core.h` is implemented;
  `studioscore_image_engine.h` remains a draft. They share no names, so a
  translation unit may include either, never both.
- **Fixtures match the codec encoder exactly**, including escaping `/`, so a
  save is compared byte for byte with the file that was read.

macOS evidence: `./Tests/run-abi.sh arm64` and `./Tests/run-abi.sh x86_64`
both report `ABI TESTS: PASS (86 checks)`. The C test covers v3 and v4-unknown
round trips, unknown-field preservation through an edit, too-new and invalid
input refusals, the render plan compared with a pinned fixture, the full
history sequence (including the 100-step limit) and the buffer ownership
contract. Merged on `main` as PR #10 (`4e51856`); the full macOS suite and
`Tests/Conformance/run-conformance.sh` were re-run on that commit with the same
verdicts.

The `Platform-neutral Conformance` job compiles `core_smoke.c` with `cc` on
`ubuntu-24.04`, so the header and its layout asserts are known to survive a
non-Apple C toolchain. That is a portability signal only; it is not Windows
compilation.

Windows: `Tests/run-studiocore-windows.ps1` built the same library and ran the
same C test with the toolchain's `clang` on `windows-2025` on 2026-11-13:
`StudioCore: 260 checks passed`, `ABI TESTS: PASS (86 checks)`,
`StudioCore Windows portability check: PASS`. W1's Windows exit criterion is
therefore met. The Windows application milestones W2–W6 are untouched and
**NOT VERIFIED**.

## 6. Distribution

| Target | Build | Artifact |
| --- | --- | --- |
| macOS Apple Silicon | arm64 on `macos-15` | arm64 DMG + SHA-256 |
| macOS Intel | x86_64 cross-build, Rosetta self-test | x86_64 DMG + SHA-256 |
| Windows Intel | x64 on `windows-2025` | one x64 zip + SHA-256 |
| Windows AMD | the same x64 binary | same artifact |

"x64" is the instruction set; Intel and AMD both execute it. There is no
separate AMD build, and no Windows ARM64 target is in scope. Builds are
unsigned by default and published with checksums; no paid certificate or
notarization is required.

## 7. Risks

1. **Pixel parity.** The 17 stages must be reimplemented; Direct2D and Core
   Image differ. The corpus defines acceptance, not byte equality.
2. **Landmarks.** Vision's mesh has no direct Windows equivalent. An ONNX model
   adds size and licence review; a box-only mode reduces features.
3. **AI runtime.** The worker is Python and its Windows provider, wheels and
   model behaviour are **NOT VERIFIED**. A Windows build can ship as a light
   editor with AI reported unavailable, exactly as the Intel macOS slice does.
4. **Signing.** Unsigned binaries trigger SmartScreen; free signing services
   would be a new dependency and are not assumed.
5. **C ABI stability.** The ABI is new surface with its own versioning and
   ownership rules; it must be tested independently of any UI.
6. **Limited Windows evidence.** The core build, C ABI test and conformance gate
   ran green on `windows-2025` on 2026-11-13. Any renderer, UI, packaging and
   runtime behaviour beyond that, including `Tools/package-windows.ps1`, remains
   **NOT VERIFIED**.
