#!/usr/bin/env python3
"""Validate the independent exact-reference M3 upscale fixture.

The fixture is developer-runtime evidence, not packaged-app or clean-install
inference evidence. Its bytes and manifest are trust pins: validation is exact
and deliberately has no tolerance or alternate source.
"""
from __future__ import annotations

import hashlib
import json
import os
from pathlib import Path
import stat
import sys


SCHEMA = "retouchstudio.m3-reference-fixture/1"
EVIDENCE_CLASS = "developer-runtime; not packaged-app or clean-install evidence"
MODEL_ID = "swin2sr-x4"
MODEL_VERSION = "1.0.0"
MODEL_FORMAT = "pytorch"
CAPABILITY = "upscale.4x"
CATALOG_AGGREGATE = "e0da6778bbcffbb26d61fda450648998e22f66d5867924706fee6d929aa50cdf"

CHECKPOINT_FILES = [
    {
        "path": "config.json",
        "sha256": "1e986fb6d0b6de32bae01a6ccd756e5d8ae1525dcb52f7ee5b2dc7f6132d6365",
        "sizeBytes": 772,
    },
    {
        "path": "preprocessor_config.json",
        "sha256": "cbc36266fcc93d5bc1e9ca69bcc648ae9d268918ad14cd3507216740f129cc4d",
        "sizeBytes": 152,
    },
    {
        "path": "pytorch_model.bin",
        "sha256": "4a5f52a20932085557ed115f87c0ee8385e12f2719108c0dfd38c64aedea4710",
        "sizeBytes": 48460141,
    },
]

FIXTURE_FILES = {
    "manifest.json": (
        2281,
        "c412120dd54dc1338d1e78bc37c4935083aac71eb21f44d4919601afb2d28f1e",
    ),
    "source.rgb": (
        9216,
        "ee2b9d831fe93d75e157f9507861c4b8dc6ec4ec85a75dac300cf0e00cbde75f",
    ),
    "input.f32": (
        36864,
        "6e3f7701f7d5425238491d405cc25421577c5580525f1598fa7bde28a395f116",
    ),
    "reference.mps.rgb": (
        147456,
        "095bd862b7bf7ec14bb65e853cda5f5330bbdf56dfe7b3eea86b01956066fdc6",
    ),
    "reference.cpu.rgb": (
        147456,
        "ee516854965d2c5daea15b64ceb0f19fbb212509f4eeb5dc91eb7b91b7603a80",
    ),
    "bicubic.rgb": (
        147456,
        "d5a850c1a860a2632c3869eea08825ca2f505f36365e20ab2f6ab73f4692b10c",
    ),
}

EXPECTED_MANIFEST = {
    "schema": SCHEMA,
    "status": "COMPLETE",
    "evidence_class": EVIDENCE_CLASS,
    "model": {
        "id": MODEL_ID,
        "version": MODEL_VERSION,
        "format": MODEL_FORMAT,
        "capability": CAPABILITY,
    },
    "catalog_aggregate_sha256": CATALOG_AGGREGATE,
    "checkpoint": CHECKPOINT_FILES,
    "fixture": {
        "source_rgb": {
            "path": "source.rgb",
            "sha256": FIXTURE_FILES["source.rgb"][1],
            "bytes": FIXTURE_FILES["source.rgb"][0],
        },
        "input_f32": {
            "path": "input.f32",
            "sha256": FIXTURE_FILES["input.f32"][1],
            "bytes": FIXTURE_FILES["input.f32"][0],
        },
    },
    "fixture_contract": {
        "source_rgb_shape": [48, 64, 3],
        "input_f32_shape": [1, 3, 48, 64],
        "expected_output_shape": [192, 256, 3],
    },
    "outputs": {
        "mps": {
            "provider": "mps",
            "path": "reference.mps.rgb",
            "sha256": FIXTURE_FILES["reference.mps.rgb"][1],
            "bytes": FIXTURE_FILES["reference.mps.rgb"][0],
        },
        "cpu": {
            "provider": "cpu",
            "path": "reference.cpu.rgb",
            "sha256": FIXTURE_FILES["reference.cpu.rgb"][1],
            "bytes": FIXTURE_FILES["reference.cpu.rgb"][0],
        },
    },
    "bicubic": {
        "path": "bicubic.rgb",
        "sha256": FIXTURE_FILES["bicubic.rgb"][1],
        "bytes": FIXTURE_FILES["bicubic.rgb"][0],
        "resampling": "Pillow BICUBIC",
    },
    "final_tolerance": "NOT SET",
    "upstream_evidence": {
        "reference_manifest_sha256": "f7f1eb4edef5045ad6e05d0b544faf77920b6ba5b1d16f594a6e31b7dbf9ee94",
        "metrics_sha256": "4ec96ac8ea91b1ad33760dbc7d3e56516545d3563a06ddcfec6d443e9dafa27b",
        "generator_sha256": "9ff87693ede641475badb844c8673dc68bbd47bd5e74dc69819b3d73611a92f6",
    },
}


class FixtureError(Exception):
    pass


def json_equal(actual: object, expected: object) -> bool:
    """Compare JSON values without treating booleans as integers."""
    if type(actual) is not type(expected):
        return False
    if isinstance(expected, dict):
        return set(actual) == set(expected) and all(
            json_equal(actual[key], expected[key]) for key in expected
        )
    if isinstance(expected, list):
        return len(actual) == len(expected) and all(
            json_equal(left, right) for left, right in zip(actual, expected)
        )
    return actual == expected


def read_regular(
    path: Path,
    label: str,
    expected_size: int | None = None,
    expected_sha256: str | None = None,
) -> bytes:
    try:
        mode = path.lstat().st_mode
    except FileNotFoundError as error:
        raise FixtureError(f"{label} is missing: {path}") from error
    except OSError as error:
        raise FixtureError(f"{label} cannot be inspected safely: {error}") from error
    if stat.S_ISLNK(mode):
        raise FixtureError(f"{label} must be a regular non-symlink file: {path.name}")
    if not stat.S_ISREG(mode):
        raise FixtureError(f"{label} must be a regular non-symlink file: {path.name}")

    flags = os.O_RDONLY | os.O_NOFOLLOW | os.O_CLOEXEC
    try:
        descriptor = os.open(path, flags)
    except OSError as error:
        raise FixtureError(f"{label} cannot be opened safely: {error}") from error
    try:
        opened = os.fstat(descriptor)
        if not stat.S_ISREG(opened.st_mode):
            raise FixtureError(f"{label} must be a regular non-symlink file: {path.name}")
        if expected_size is not None and opened.st_size != expected_size:
            raise FixtureError(
                f"{label} size mismatch for {path.name}: "
                f"expected {expected_size}, found {opened.st_size}"
            )
        hasher = hashlib.sha256()
        chunks = []
        while True:
            chunk = os.read(descriptor, 4 << 20)
            if not chunk:
                break
            hasher.update(chunk)
            chunks.append(chunk)
    finally:
        os.close(descriptor)
    checksum = hasher.hexdigest()
    if expected_sha256 is not None and checksum != expected_sha256:
        raise FixtureError(
            f"{label} SHA-256 mismatch for {path.name}: "
            f"expected {expected_sha256}, found {checksum}"
        )
    return b"".join(chunks)


def validate_manifest(payload: object) -> None:
    if not json_equal(payload, EXPECTED_MANIFEST):
        differing = []
        if isinstance(payload, dict):
            differing = sorted(
                key
                for key in set(payload) | set(EXPECTED_MANIFEST)
                if not json_equal(payload.get(key), EXPECTED_MANIFEST.get(key))
            )
        detail = f" ({', '.join(differing)})" if differing else ""
        raise FixtureError(
            "M3 reference fixture manifest.json is malformed or internally inconsistent"
            + detail
        )


def validate_catalog(path: Path) -> None:
    raw = read_regular(path, "M3 reference catalog")
    try:
        payload = json.loads(raw.decode("utf-8"))
    except (UnicodeError, json.JSONDecodeError) as error:
        raise FixtureError("M3 reference catalog is not valid JSON") from error
    if not isinstance(payload, dict) or payload.get("schema") != "retouchstudio.model-catalog/1":
        raise FixtureError("M3 reference catalog has an unknown schema")
    entries = payload.get("entries")
    if not isinstance(entries, list):
        raise FixtureError("M3 reference catalog has no model entry list")
    matches = [
        entry
        for entry in entries
        if isinstance(entry, dict) and entry.get("id") == MODEL_ID
    ]
    if len(matches) != 1:
        raise FixtureError(
            f"M3 reference catalog must contain exactly one {MODEL_ID} entry"
        )
    entry = matches[0]
    expected_scalars = {
        "id": MODEL_ID,
        "version": MODEL_VERSION,
        "format": MODEL_FORMAT,
        "capabilities": [CAPABILITY],
        "sha256": CATALOG_AGGREGATE,
        "sizeBytes": sum(record["sizeBytes"] for record in CHECKPOINT_FILES),
        "deterministic": True,
        "preprocess": {"id": "swin2sr-tile-rgb8", "version": "1"},
    }
    for key, expected in expected_scalars.items():
        if not json_equal(entry.get(key), expected):
            raise FixtureError(
                f"M3 reference catalog {MODEL_ID} field {key} disagrees with the fixture"
            )
    if "unverifiableReason" in entry:
        raise FixtureError(
            f"M3 reference catalog {MODEL_ID} still carries an unverifiableReason"
        )

    files = entry.get("files")
    if not isinstance(files, list):
        raise FixtureError(f"M3 reference catalog {MODEL_ID} has no checkpoint file list")
    projected = []
    for record in files:
        if not isinstance(record, dict) or not all(
            key in record for key in ("path", "sha256", "sizeBytes")
        ):
            raise FixtureError(
                f"M3 reference catalog {MODEL_ID} has a malformed checkpoint record"
            )
        projected.append({key: record[key] for key in ("path", "sha256", "sizeBytes")})
    if not json_equal(projected, CHECKPOINT_FILES):
        raise FixtureError(
            f"M3 reference catalog {MODEL_ID} checkpoint pins disagree with the fixture"
        )


def verify_source(root: Path, catalog: Path) -> None:
    try:
        mode = root.lstat().st_mode
    except FileNotFoundError as error:
        raise FixtureError(f"M3 reference fixture directory is missing: {root}") from error
    except OSError as error:
        raise FixtureError(f"M3 reference fixture directory cannot be inspected: {error}") from error
    if stat.S_ISLNK(mode):
        raise FixtureError(
            f"M3 reference fixture directory must not be a symbolic link: {root}"
        )
    if not stat.S_ISDIR(mode):
        raise FixtureError(f"M3 reference fixture root is not a directory: {root}")

    try:
        with os.scandir(root) as iterator:
            names = sorted(entry.name for entry in iterator)
    except OSError as error:
        raise FixtureError(f"M3 reference fixture directory cannot be read: {error}") from error
    expected_names = sorted(FIXTURE_FILES)
    missing = sorted(set(expected_names) - set(names))
    unexpected = sorted(set(names) - set(expected_names))
    if missing:
        raise FixtureError(
            "M3 reference fixture is missing required file(s): " + ", ".join(missing)
        )
    if unexpected:
        raise FixtureError(
            "M3 reference fixture has unexpected entry or entries: " + ", ".join(unexpected)
        )

    contents = {}
    for name in expected_names:
        size, checksum = FIXTURE_FILES[name]
        contents[name] = read_regular(
            root / name,
            "M3 reference fixture file",
            size,
            checksum,
        )
    try:
        manifest = json.loads(contents["manifest.json"].decode("utf-8"))
    except (UnicodeError, json.JSONDecodeError) as error:
        raise FixtureError("M3 reference fixture manifest.json is not valid JSON") from error
    validate_manifest(manifest)
    validate_catalog(catalog)


def verify_bundle(app: Path) -> None:
    try:
        app_mode = app.lstat().st_mode
    except FileNotFoundError as error:
        raise FixtureError(f"M3 reference fixture bundle root is missing: {app}") from error
    except OSError as error:
        raise FixtureError(f"M3 reference fixture bundle root cannot be inspected: {error}") from error
    if stat.S_ISLNK(app_mode) or not stat.S_ISDIR(app_mode):
        raise FixtureError("M3 reference fixture bundle root must be a real directory")

    canonical = app / "Contents/Resources/Tests/Fixtures/upscale-m3"
    current = app
    for part in ("Contents", "Resources", "Tests", "Fixtures", "upscale-m3"):
        current = current / part
        try:
            mode = current.lstat().st_mode
        except FileNotFoundError as error:
            raise FixtureError(
                "M3 reference fixture is missing at canonical bundle location: "
                "Contents/Resources/Tests/Fixtures/upscale-m3"
            ) from error
        except OSError as error:
            raise FixtureError(
                f"M3 reference fixture canonical ancestor cannot be inspected: {error}"
            ) from error
        if stat.S_ISLNK(mode):
            raise FixtureError(
                "M3 reference fixture canonical ancestor must not be a symbolic link: "
                + current.relative_to(app).as_posix()
            )
        if not stat.S_ISDIR(mode):
            raise FixtureError(
                "M3 reference fixture canonical ancestor is not a directory: "
                + current.relative_to(app).as_posix()
            )

    app_real = Path(os.path.realpath(app))
    canonical_real = Path(os.path.realpath(canonical))
    try:
        canonical_real.relative_to(app_real)
    except ValueError as error:
        raise FixtureError(
            "M3 reference fixture canonical location escapes the app bundle"
        ) from error

    resources = app / "Contents/Resources"
    alternates = []
    for base, directories, files in os.walk(resources, followlinks=False):
        directories.sort()
        files.sort()
        for name in directories + files:
            if name not in ("upscale-m3", "upscale-m3-manifest.json"):
                continue
            candidate = Path(base) / name
            if os.path.abspath(candidate) != os.path.abspath(canonical):
                alternates.append(candidate.relative_to(app).as_posix())
    if alternates:
        raise FixtureError(
            "M3 reference fixture has alternate or ambiguous bundle location(s): "
            + ", ".join(sorted(alternates))
        )

    verify_source(canonical, resources / "model-catalog.json")


def main() -> int:
    arguments = sys.argv[1:]
    if len(arguments) == 3 and arguments[0] == "verify-source":
        verify_source(Path(arguments[1]).absolute(), Path(arguments[2]).absolute())
        print("M3 reference fixture verified: 6 exact files; catalog binding verified")
        return 0
    if len(arguments) == 2 and arguments[0] == "verify-bundle":
        verify_bundle(Path(arguments[1]).absolute())
        print("M3 reference fixture bundle verified: canonical location only")
        return 0
    print(
        "usage: validate-m3-fixture.py verify-source <fixture-directory> <model-catalog.json>\n"
        "       validate-m3-fixture.py verify-bundle <bundle>",
        file=sys.stderr,
    )
    return 2


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (FixtureError, OSError) as error:
        print(str(error), file=sys.stderr)
        raise SystemExit(1)
