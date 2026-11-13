# Releasing Retouch Studio

This is the checklist for turning the working tree into a public build. It is written for the current state of the project: universal (Apple silicon and Intel), ad-hoc signed, with an optional local AI helper. Release builds ship without the helper. In the current stabilization build the protocol-v2 runtime installer is disabled (`AIRuntime.package` is nil), so the AI tools report the runtime as unavailable and the app downloads no runtime. When an official protocol-v2 package is configured, the app will fetch it only after the owner approves its name, size and SHA256; model weights stay a separate download. A build with the worker bundled is still supported for offline use. The helper itself is Apple-silicon-only.

## 1. Public identity

These are the values for the first public release:

| Item | Value | Where |
|---|---|---|
| Bundle identifier | `app.retouchstudio.mac` | `Resources/Info.plist` |
| Project UTI | `app.retouchstudio.project` | `Resources/Info.plist`, `Project.swift` |
| Version / build | `1.0.0` / `1` | `Resources/Info.plist` |
| Developer | iRoham — Design and development (localized) | `Sources/RetouchStudio/Models/DeveloperProfile.swift` |
| Contact, website | blank (rows stay hidden) | `DeveloperProfile.swift` |
| Licence | MIT | `LICENSE` |

The bundle identifier appears in `Info.plist`, the UTI appears in both `Info.plist` and `Project.swift`, and the recovery path falls back to the identifier in `Recovery.swift`. Change all of them together; changing the identifier after a release changes the app's identity for macOS, saved state and the recovery file. The version in `Info.plist` is what the About window, Settings and export dialogs display at runtime.

## 2. Version stamping

The bundle version is stamped at build time, so nothing has to be committed for each release:

```bash
RETOUCH_VERSION=1.0.0 RETOUCH_BUILD=42 ./build.sh release
```

Without the overrides the values in `Resources/Info.plist` are used. Bump `CFBundleShortVersionString` for a release and `CFBundleVersion` for every uploaded build.

## 3. Pre-flight

```bash
git status                                  # expect a clean tree
./Tests/run.sh                              # Engine, Model, Runtime Process and Runtime V2 suites
cd "$RETOUCH_WORKER_ROOT" && ../.venv/bin/python -m unittest discover -s tests   # worker suite, if shipping the helper
```

The build itself runs the engine self-test (`--selftest`) and stops if it fails; details land in `build/selftest/selftest.log`.

## 4. Build and verify

```bash
RETOUCH_VERSION=1.0.0 RETOUCH_BUILD=42 RETOUCH_SKIP_WORKER=1 ./build.sh release   # light universal app
codesign --verify --deep --strict "Retouch Studio.app"
lipo -archs "Retouch Studio.app/Contents/MacOS/RetouchStudio"   # arm64 x86_64
"Retouch Studio.app/Contents/MacOS/RetouchStudio" --selftest --out /tmp/rs-selftest
```

The build runs the self-test on the executable **inside the bundle** (not the loose `build/bin` copy) natively and, on an Apple-silicon machine with Rosetta, again on the Intel slice (`build/selftest-intel/`). A failure in either stops the build. `build.sh` finishes with `codesign --verify --deep --strict` and `Tools/validate-bundle.sh`, which checks the plist keys, the architecture set, the signature kind and the bundled helper layout; a validation failure stops the build. Use `RETOUCH_ARCH=arm64` or `RETOUCH_ARCH=x86_64` only for a deliberate single-architecture build.

Check the bundle contents:

```bash
du -sh "Retouch Studio.app"                                # ~16 MB light universal; ~1.3–1.6 GB with the helper
ls "Retouch Studio.app/Contents/Resources/Worker"          # only if the helper was bundled; Apple-silicon runtime
find "Retouch Studio.app/Contents" -name '*.pyc'           # must be empty; bytecode is memory-only
```

Model weights must not appear inside the bundle. They belong in `~/Library/Application Support/RetouchStudio/AI/models` after the owner approves a download. The on-demand protocol-v2 runtime installs under `~/Library/Application Support/RetouchStudio/AI/runtimes/protocol-v2`; the installer is currently disabled because `AIRuntime.package` is nil, so this build does not install a runtime.

## 5. Signing and notarization

Without a signing identity, `build.sh` signs ad-hoc (`codesign --force --sign -`). That is enough for the build machine and for other Macs where the user approves the first launch, but it is **not** a public, warning-free distribution. The build no longer treats a failed signature as a warning: `codesign` errors and `codesign --verify --deep --strict` failures stop the build.

`build.sh` is identity-aware for the future public build:

```bash
RETOUCH_SIGN_IDENTITY="Developer ID Application: <Name> (<TEAMID>)" \
RETOUCH_ENTITLEMENTS=Resources/RetouchStudio.entitlements \
  ./build.sh release
```

With an identity it signs Hardened Runtime (`--options runtime --timestamp`), applies the entitlements file (empty today: file access and the bundled helper need no exceptions), signs the nested Mach-O files under `Contents/Resources/Worker` first, then the bundle. `Tools/validate-bundle.sh` reports the resulting signature as ad-hoc or Developer ID.

A notarized release requires an Apple Developer ID Application certificate and a `notarytool` keychain profile; neither exists in this repository or on the current machine, and no credential is stored in the repository. Once they exist, use `Tools/notarize.sh`, which refuses to run without `RETOUCH_NOTARY_PROFILE` and a Developer ID signature:

```bash
./Tools/notarize.sh "Retouch Studio.app"          # or a .dmg
```

It submits with `notarytool ... --wait`, staples and validates the result, and runs `spctl --assess`. Until then, release notes must state that the build is ad-hoc signed, light (the current build offers no runtime download; a future approved runtime package would be a separate Apple-silicon download), and opened with **right-click → Open** on first launch.

## 6. Package and publish

The two disk images are light builds. The current build offers no runtime download (`AIRuntime.package` is nil); packaging a future runtime is a separate step, enabled only when an official protocol-v2 package is approved. That archive is cut from a helper build first:

```bash
RETOUCH_ARCH=arm64 ./build.sh release                 # helper build, source available
./Tools/make-runtime.sh "Retouch Studio.app/Contents/Resources/Worker"
                                         # RetouchStudio-1.0.0-ai-runtime-arm64.zip + checksum
```

Do not publish that archive as installable until an official protocol-v2 package exists. Enabling the installer requires an `AIRuntime.Package` entry (URL, byte count and SHA256) in `Sources/RetouchStudio/Core/AIRuntime.swift`; the current build keeps `package` nil, so no runtime is offered, verified or installed. When an approved package is configured, the app verifies both size and SHA256 before installing under `~/Library/Application Support/RetouchStudio/AI/runtimes/protocol-v2`.

```bash
RETOUCH_ARCH=arm64 RETOUCH_SKIP_WORKER=1 ./build.sh release
./Tools/make-dmg.sh                                  # RetouchStudio-1.0.0-arm64.dmg

RETOUCH_ARCH=x86_64 RETOUCH_SKIP_WORKER=1 ./build.sh release
./Tools/make-dmg.sh                                  # RetouchStudio-1.0.0-x86_64.dmg

RETOUCH_ARCH=universal RETOUCH_SKIP_WORKER=1 ./build.sh release
ditto -c -k --keepParent "Retouch Studio.app" "RetouchStudio-1.0.0-universal.zip"
shasum -a 256 "RetouchStudio-1.0.0-universal.zip" > "RetouchStudio-1.0.0-universal.zip.sha256"

git tag -a v1.0.0 -m "Retouch Studio 1.0.0"
git push origin main --tags
gh release create v1.0.0 \
  "RetouchStudio-1.0.0-arm64.dmg" "RetouchStudio-1.0.0-arm64.dmg.sha256" \
  "RetouchStudio-1.0.0-x86_64.dmg" "RetouchStudio-1.0.0-x86_64.dmg.sha256" \
  "RetouchStudio-1.0.0-universal.zip" "RetouchStudio-1.0.0-universal.zip.sha256" \
  --title "Retouch Studio 1.0.0" --notes-file Docs/RELEASE_NOTES_1.0.0.md
```

Attach a runtime archive only when an approved `AIRuntime.Package` points at that exact file; an archive without that entry cannot be installed by the app. Each DMG holds the app next to an `Applications` symlink, so installing is one drag. The arm64 and x86_64 images are the same light editor, and the universal zip is a single-file alternative. `ditto` preserves the code signature and resource forks; avoid `zip` from the command line for the app bundle.

Release notes should include:

- what changed, and the minimum macOS version (14.0);
- that the build is ad-hoc signed, with first-launch instructions;
- that the editor runs on Intel while the AI tools require Apple silicon and a runtime that the current build does not offer;
- that the current build offers no runtime download; a future approved protocol-v2 runtime would be about 390 MB and fetched only after its size and SHA256 are shown, and models are always downloaded separately;
- the SHA256 of every archive;
- a link to `PRIVACY_AUDIT.md` for the network claim.

## 6.5 Signed update feed (prepared, not published)

No feed is published for 1.0.0 and the shipped `Info.plist` contains no
`RSUpdateFeedURL*` key, so the About window reports that no feed is configured
and performs no request. When a feed is ready:

1. Build the release, then the zip the manifest will name:
   `ditto -c -k --keepParent "Retouch Studio.app" RetouchStudio-<version>-<arch>.zip`.
2. Compute the size and SHA-256 of that zip and write one `UpdateArtifact` per
   platform/architecture (`platform` `macos`, `architecture` `arm64`, `x86_64`
   or `universal`, `format` `zip`, HTTPS `url`).
3. Sign the descriptor with the release private key kept outside the repository
   (`~/.config/retouchstudio/update-signing-key.txt`, base64 of 32 raw bytes,
   mode 600). The descriptor function and the key check ship in the app, so a
   signing helper can link `StudioCore` and use the same code path:

   ```swift
   import CryptoKit
   import Foundation
   import StudioCore

   let artifact = UpdateArtifact(platform: "macos", architecture: "arm64",
                                 url: "https://…/RetouchStudio-1.1.0-arm64.zip",
                                 size: 12345678, sha256: "<64 hex>",
                                 signature: "")
   let release = UpdateRelease(version: "1.1.0", build: 2,
                               minimumSystemVersion: "14.0",
                               artifacts: [artifact])
   let descriptor = UpdatePolicy.descriptor(release: release, artifact: artifact)
   let raw = Data(base64Encoded: try String(contentsOfFile: "…/update-signing-key.txt",
                                            encoding: .utf8)
                   .trimmingCharacters(in: .whitespacesAndNewlines))!
   let key = try Curve25519.Signing.PrivateKey(rawRepresentation: raw)
   let signature = try key.signature(for: Data(descriptor.utf8))
       .base64EncodedString()
   ```

   Put the signature into the manifest's `signature` field. A manifest whose
   signature was produced over a different URL, hash, size or version is refused
   by every client.
4. Host the manifest at an HTTPS URL no larger than 1 MB and set it in a build's
   `Info.plist` (`RSUpdateFeedURL` or `RSUpdateFeedURLs`). Changing the feed
   later needs a new signed build, but no code change.
5. Test on a second machine: point it at an older build, confirm the About
   window offers the release, install, relaunch, and confirm the version. Also
   interrupt the download and quit the app mid-swap to exercise the rollback and
   journal recovery described in `Docs/UPDATE_SYSTEM.md`. These live checks have
   **not** been performed yet.

## 7. Post-publish checks

- Download the DMG from the release page, verify its checksum, mount it, drag the app to Applications and launch it from a different account or folder. Repeat once with the zip.
- Open a photo, run one Auto Retouch, export, and reopen the saved `.retouch` project.
- In the current build, confirm **Settings → Manage Models…** offers no runtime download and the AI tools report the runtime as unavailable. When an approved protocol-v2 package is configured, approve its download, watch the SHA256 check and install, then confirm the helper answers and a model downloads and runs one AI job. Repeat the idle socket check described in `PRIVACY_AUDIT.md` §5.
- Confirm the About window and Settings show the stamped version.

## 8. Known limitations to repeat in the release notes

1. Ad-hoc signature, no notarization — Gatekeeper asks once on other Macs.
2. No clean-machine install has been tested on a second physical Mac.
3. The current build offers no AI runtime download. A future approved protocol-v2 runtime would be an optional ~390 MB Apple-silicon download (about 1.3 GB unpacked); models add tens of megabytes to several gigabytes on top. Intel has no AI.
4. Windows: the shared StudioCore module builds and passes its tests on the native `windows-2025` CI runner, and a light C#/WPF editor in `Windows/` builds and opens its window there, but there is no Windows installer, published artifact, AI support or macOS parity in this codebase. Linux is unimplemented and stays on the long-term roadmap after a verified Windows release candidate.
5. The worker source lives outside this repository; a build from a fresh clone without it produces a light app whose AI tools report that the runtime is unavailable.
6. Downloaded models range from tens of megabytes to several gigabytes under Application Support; removing the app and that folder is the documented uninstall.
