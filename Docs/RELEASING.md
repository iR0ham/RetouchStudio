# Releasing Retouch Studio

This is the checklist for turning the working tree into a public build. It is written for the current state of the project: universal (Apple silicon and Intel), ad-hoc signed, with an optional local AI helper. Release builds ship without the helper: the app downloads its runtime (about 390 MB) only when the owner asks, then downloads model weights separately. A build with the worker bundled is still supported for offline use. The helper itself is Apple-silicon-only.

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
./Tests/run.sh                              # engine + model suites
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

The build runs the self-test natively and, on an Apple-silicon machine with Rosetta, again on the Intel slice (`build/selftest-intel/`). A failure in either stops the build. Use `RETOUCH_ARCH=arm64` or `RETOUCH_ARCH=x86_64` only for a deliberate single-architecture build.

Check the bundle contents:

```bash
du -sh "Retouch Studio.app"                                # ~16 MB light universal; ~1.3–1.6 GB with the helper
ls "Retouch Studio.app/Contents/Resources/Worker"          # only if the helper was bundled; Apple-silicon runtime
find "Retouch Studio.app/Contents" -name '*.pyc'           # must be empty; bytecode is memory-only
```

Model weights must not appear inside the bundle. They belong in `~/Library/Application Support/RetouchStudio/AI/models` after the owner approves a download. The on-demand protocol-v2 runtime installs under `~/Library/Application Support/RetouchStudio/AI/runtimes/protocol-v2`; the installer is currently disabled because `AIRuntime.package` is nil, so this build does not install a runtime.

## 5. Signing and notarization

`build.sh` signs ad-hoc (`codesign --sign -`). That is enough for the build machine and for other Macs where the user approves the first launch, but it is **not** a public, warning-free distribution.

A notarized release requires an Apple Developer ID Application certificate and a `notarytool` submission; neither exists in this repository or on the current machine. The future flow is:

```bash
codesign --force --deep --options runtime --timestamp \
  --sign "Developer ID Application: <Name> (<TEAMID>)" "Retouch Studio.app"
ditto -c -k --keepParent "Retouch Studio.app" RetouchStudio.zip
xcrun notarytool submit RetouchStudio.zip --keychain-profile <profile> --wait
xcrun stapler staple "Retouch Studio.app"
```

Until then, release notes must state that the build is ad-hoc signed, light (the AI runtime is a separate download on Apple silicon), and opened with **right-click → Open** on first launch.

## 6. Package and publish

The two disk images are light builds, because the AI helper is downloaded on demand. The runtime archive is cut from a helper build first:

```bash
RETOUCH_ARCH=arm64 ./build.sh release                 # helper build, source available
./Tools/make-runtime.sh "Retouch Studio.app/Contents/Resources/Worker"
                                         # RetouchStudio-1.0.0-ai-runtime-arm64.zip + checksum
```

Copy the printed byte count and SHA256 into `Sources/RetouchStudio/Core/AIRuntime.swift` (`RUNTIME_BYTES`, `RUNTIME_SHA256`) and rebuild before cutting the images; the app refuses an archive whose size or hash differs.

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
  "RetouchStudio-1.0.0-ai-runtime-arm64.zip" "RetouchStudio-1.0.0-ai-runtime-arm64.zip.sha256" \
  --title "Retouch Studio 1.0.0" --notes-file Docs/RELEASE_NOTES_1.0.0.md
```

Each DMG holds the app next to an `Applications` symlink, so installing is one drag. The arm64 and x86_64 images are the same light editor; the runtime archive is an Apple-silicon-only extra fetched by the app after consent, and the universal zip is a single-file alternative. `ditto` preserves the code signature and resource forks; avoid `zip` from the command line for the app bundle.

Release notes should include:

- what changed, and the minimum macOS version (14.0);
- that the build is ad-hoc signed, with first-launch instructions;
- that the editor runs on Intel while the AI tools require Apple silicon and a downloaded runtime;
- that the runtime is about 390 MB, downloaded from the release page after its size and SHA256 are shown, and that models are downloaded separately;
- the SHA256 of every archive;
- a link to `PRIVACY_AUDIT.md` for the network claim.

## 7. Post-publish checks

- Download the DMG from the release page, verify its checksum, mount it, drag the app to Applications and launch it from a different account or folder. Repeat once with the zip.
- Open a photo, run one Auto Retouch, export, and reopen the saved `.retouch` project.
- Approve the runtime download from **Settings → Manage Models…**, watch it verify the SHA256 and install, then confirm the helper answers and a model downloads and runs one AI job. Repeat the idle socket check described in `PRIVACY_AUDIT.md` §5.
- Confirm the About window and Settings show the stamped version.

## 8. Known limitations to repeat in the release notes

1. Ad-hoc signature, no notarization — Gatekeeper asks once on other Macs.
2. No clean-machine install has been tested on a second physical Mac.
3. The AI runtime is an optional ~390 MB download on Apple silicon (about 1.3 GB unpacked); models add tens of megabytes to several gigabytes on top. Intel has no AI.
4. Windows and Linux are not supported by this codebase.
5. The worker source lives outside this repository; a build from a fresh clone without it produces a light app whose AI tools offer the runtime download.
6. Downloaded models range from tens of megabytes to several gigabytes under Application Support; removing the app and that folder is the documented uninstall.
