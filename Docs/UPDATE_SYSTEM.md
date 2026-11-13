# Retouch Studio Update System

Status: core implemented and tested on macOS arm64 and x86_64; **no production
feed is published**, so no end-to-end notification or install has been
exercised. Everything below is labelled by what was actually verified.

## What exists

| Layer | File | Portable? |
| --- | --- | --- |
| Manifest, version rules, host selection | `Sources/StudioCore/UpdateManifest.swift` | yes (Foundation only) |
| Ed25519 verification, file checks, atomic swap, recovery | `Sources/RetouchStudio/Core/UpdateVerification.swift` | macOS host |
| Bounded HTTPS download, user flow | `Sources/RetouchStudio/Core/UpdateController.swift` | macOS host |
| About-window entry point | `Sources/RetouchStudio/Views/InfoViews.swift` | macOS host |

The split matters: the same selection rules will serve a future Windows host,
but the installer in this release only knows a macOS `.app` bundle.

## Manifest

```json
{
  "schema": 1,
  "channel": "stable",
  "generatedAt": "2026-11-13T00:00:00Z",
  "releases": [
    {
      "version": "1.1.0",
      "build": 2,
      "publishedAt": "2026-11-13T00:00:00Z",
      "notes": "…",
      "minimumSystemVersion": "14.0",
      "artifacts": [
        {
          "platform": "macos",
          "architecture": "arm64",
          "format": "zip",
          "url": "https://…/RetouchStudio-1.1.0-arm64.zip",
          "size": 12345678,
          "sha256": "…64 hex…",
          "signature": "…base64 Ed25519…"
        }
      ]
    }
  ]
}
```

Selection rules (`UpdatePolicy.evaluate`):

- an unknown `schema` or a channel other than the requested one is refused;
- only releases strictly newer than the installed version, or the same version
  with a higher build, are candidates; the newest version wins, then the highest
  build;
- `minimumSystemVersion` (two or three components, e.g. `14.0`, `10.0.22631`)
  above the host is reported as incompatible, never silently skipped;
- artifacts must match `platform`, and `architecture` must match or be
  `universal`; `format` must be `zip`;
- URL must be HTTPS, `sha256` must be 64 hex digits, `size` must be positive,
  and `signature` must be non-empty. Anything else is reported with a reason.

### What the signature covers

`UpdatePolicy.descriptor` joins, in this fixed order:

```
retouchstudio-update-v1
version=…
build=…
platform=…
architecture=…
format=…
size=…
sha256=…        (lowercased)
url=…
```

The Ed25519 signature over those UTF-8 bytes is what `signature` carries.
Changing the URL, hash, size, version, platform or architecture invalidates it;
a manifest that points at an unsigned or altered artifact can never become an
installable plan. `minimumSystemVersion`, `notes` and `publishedAt` are outside
the signature: tampering with them can only cause a refusal or different copy,
never a different install.

## Keys

- Public key: `UpdateSignature.releasePublicKey` at
  `Sources/RetouchStudio/Core/UpdateVerification.swift:12`
  (`jMAfiu36PqtRkYbgwFWjBbKJi59q7ICX7xegXZ1gz2g=`).
- Private key: **outside the repository**, at
  `~/.config/retouchstudio/update-signing-key.txt`, mode `600`. It is never
  committed, never copied into the bundle, and never read by the app.
- Losing the private key does not weaken verification; it requires rotating the
  public key in a new release. There is no "skip signature" path.

The keypair was generated in-process with CryptoKit (`Curve25519.Signing`)
because the Command Line Tools `openssl` (LibreSSL) has no Ed25519 support here.
Only a throwaway key is used inside the tests.

## Download and install

1. `UpdateController.check()` reads `RSUpdateFeedURLs` (array) and
   `RSUpdateFeedURL` (single) from `Info.plist`. Both must be HTTPS. No feed URL
   is compiled into the binary, so moving the feed never needs an update to
   find updates. The shipped `Resources/Info.plist` defines neither key, so the
   About window honestly reports that no feed is configured.
2. The manifest must decode, be at most 1 MB, and return HTTP 200 (20 s
   timeout).
3. The selected plan's descriptor signature is verified before the update is
   offered.
4. On install the signature is verified again, then the artifact is downloaded
   by `BoundedDownload`, which:
   - flushes any redirect that leaves HTTPS,
   - cancels the transfer as soon as it writes more than the signed `size`,
   - refuses a non-200 response,
   - verifies the finished file's size and SHA-256 against the signed values.
5. Staging happens in a hidden directory beside the installed bundle, so the
   final rename stays on one volume. A read-only parent is refused with an
   actionable message instead of a half-copy.
6. `/usr/bin/ditto -x -k` unpacks the zip; the result must contain exactly one
   `.app` whose `CFBundleIdentifier` matches the running app and whose
   `CFBundleShortVersionString` matches the manifest.
7. `UpdateInstaller.swap` writes a journal (current, staged, backup paths), then
   renames the installed app to a backup and the staged app into place. On any
   failure the old bundle is restored and the journal removed.
8. On success the backup and journal are removed and the About window offers a
   relaunch.
9. `UpdateInstaller.recover` runs on every launch before the editor opens. It
   decides from what is on disk, so a crash between the renames is completed
   (new bundle present, backup present) or rolled back (new bundle missing,
   backup present) without a stored phase.

Nothing is forced: an available update is only installed when the owner presses
the button, and a refused/incompatible update is reported rather than applied.
There is also no automatic background check, by design: the app makes no
outbound request until the owner presses Check, which matches the
no-background-requests claim in `Docs/PRIVACY_AUDIT.md`. The "notification" is
the status line and button in About.

## Tests

`Tests/EngineTests.swift` (`[U]` section, run by `Tests/run.sh`) covers 34
checks: version and platform-version ordering; newest release/build selection;
up-to-date and no-downgrade decisions; missing host artifact, minimum system and
invalid artifact refusals; unknown schema; Ed25519 sign/verify with a throwaway
key; URL tampering; unreadable key; the shipped key's length; size and hash
mismatches; atomic swap; non-app refusal; three journal-recovery outcomes; and
zip unpack with a wrong-version refusal. All pass on arm64 and x86_64.

## Not verified / not implemented

- **End-to-end install from a real feed: NOT VERIFIED.** No feed is published
  and no signed release archive exists, so the network path (redirect handling,
  oversize cancellation, HTTP failure) is covered by code review only, not by an
  automated test.
- The feed must be hosted by the owner. The repository does not contain a
  publisher, server configuration or CDN.
- Windows updates are **not implemented**: the portable rules accept a
  `windows` artifact, but there is no Windows host or installer yet.
- Signature/notarization of the updated bundle is not checked by the updater;
  Gatekeeper evaluates the new bundle on first launch exactly as it does a
  fresh download. Signing is documented in `Docs/RELEASING.md`.
- Delta updates are not supported; every update is a full zip.
