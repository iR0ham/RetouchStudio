# Releasing Retouch Studio

This is the checklist for turning the working tree into a public build. It is written for the current state of the project: universal (Apple silicon and Intel), ad-hoc signed, with an optional local AI helper and downloaded model weights. The helper itself is Apple-silicon-only.

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
RETOUCH_VERSION=1.0.0 RETOUCH_BUILD=42 ./build.sh release   # universal by default
codesign --verify --deep --strict "Retouch Studio.app"
lipo -archs "Retouch Studio.app/Contents/MacOS/RetouchStudio"   # arm64 x86_64
"Retouch Studio.app/Contents/MacOS/RetouchStudio" --selftest --out /tmp/rs-selftest
```

The build runs the self-test natively and, on an Apple-silicon machine with Rosetta, again on the Intel slice (`build/selftest-intel/`). A failure in either stops the build. Use `RETOUCH_ARCH=arm64` or `RETOUCH_ARCH=x86_64` only for a deliberate single-architecture build.

Check the bundle contents:

```bash
du -sh "Retouch Studio.app"                                # ~1.3–1.6 GB with the helper, ~30 MB without
ls "Retouch Studio.app/Contents/Resources/Worker"          # only if the helper was bundled; Apple-silicon runtime
find "Retouch Studio.app/Contents" -name '*.pyc'           # must be empty; bytecode is memory-only
```

Model weights must not appear inside the bundle. They belong in `~/Library/Application Support/RetouchStudio/AI/models` after the owner approves a download.

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

Until then, release notes must state that the build is ad-hoc signed, universal (AI needs Apple silicon), and opened with **right-click → Open** on first launch.

## 6. Package and publish

```bash
./Tools/make-dmg.sh                                  # DMG + checksum
ditto -c -k --keepParent "Retouch Studio.app" "RetouchStudio-1.0.0-universal.zip"
shasum -a 256 "RetouchStudio-1.0.0-universal.zip" > "RetouchStudio-1.0.0-universal.zip.sha256"

git tag -a v1.0.0 -m "Retouch Studio 1.0.0"
git push origin main --tags
gh release create v1.0.0 \
  "RetouchStudio-1.0.0-universal.dmg" "RetouchStudio-1.0.0-universal.dmg.sha256" \
  "RetouchStudio-1.0.0-universal.zip" "RetouchStudio-1.0.0-universal.zip.sha256" \
  --title "Retouch Studio 1.0.0" --notes-file Docs/RELEASE_NOTES_1.0.0.md
```

The DMG is the primary download: it holds the universal app next to an `Applications` symlink, so both Apple-silicon and Intel users drag one icon to install. The zip is kept as a plain alternative. `ditto` preserves the code signature and resource forks; avoid `zip` from the command line for the app bundle.

Release notes should include:

- what changed, and the minimum macOS version (14.0);
- that the build is universal and ad-hoc signed, with first-launch instructions;
- that the editor runs on Intel while the AI tools require Apple silicon;
- whether the AI helper is bundled and that models are downloaded separately;
- the SHA256 of the archive;
- a link to `PRIVACY_AUDIT.md` for the no-cloud claim.

## 7. Post-publish checks

- Download the DMG from the release page, verify its checksum, mount it, drag the app to Applications and launch it from a different account or folder. Repeat once with the zip.
- Open a photo, run one Auto Retouch, export, and reopen the saved `.retouch` project.
- If the helper is bundled: approve/download a model, run one AI job, and repeat the idle socket check described in `PRIVACY_AUDIT.md` §5.
- Confirm the About window and Settings show the stamped version.

## 8. Known limitations to repeat in the release notes

1. Ad-hoc signature, no notarization — Gatekeeper asks once on other Macs.
2. No clean-machine install has been tested on a second physical Mac.
3. The helper adds ~1.3–1.6 GB before any model download and is Apple-silicon-only; on Intel the editor works and AI is unavailable.
4. Windows and Linux are not supported by this codebase.
5. The worker source lives outside this repository; a build from a fresh clone without it produces an app whose AI tools report the helper as missing.
6. Downloaded models range from tens of megabytes to several gigabytes under Application Support; removing the app and that folder is the documented uninstall.
