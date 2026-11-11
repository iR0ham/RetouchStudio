#!/usr/bin/env python3
"""R1 StudioCore conformance runner.

Stdlib only. Validates canonical JSON fixtures, contract references, the
17-stage render order, and the read-only golden-corpus lock. It does not load
the RetouchStudio app, Core Image, Vision, or any engine implementation.
"""

from __future__ import annotations

import hashlib
import json
import math
import re
import sys
import unicodedata
import uuid
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
R1 = ROOT / "Tests" / "Conformance"
FIXTURES = R1 / "Fixtures"
CORPUS = ROOT / "Tests" / "Corpus"

STAGES = [
    "heal",
    "aiPatch",
    "bodySkin",
    "localSkin",
    "underEye",
    "teeth",
    "eyes",
    "makeup",
    "hair",
    "featureReshape",
    "silhouetteReshape",
    "bodySlim",
    "pose",
    "globalColor",
    "background",
    "art",
    "finalCrop",
]

ORCHESTRATION_STAGES = ["decode", *STAGES, "encode", "write"]

STAGE_OP_TYPE = {
    "heal": "heal",
    "aiPatch": "aiPatch",
    **{name: "retouchParameters" for name in STAGES[2:15]},
    "art": "stickers",
    "finalCrop": "crop",
}

OPERATION_RANK = {
    "orientation": 0,
    "heal": 1,
    "aiPatch": 2,
    "retouchParameters": 3,
    "stickers": 16,
    "crop": 17,
    "analysis": 18,
}

SINGLETON_TYPES = {"retouchParameters", "crop", "orientation", "analysis"}
KNOWN_CAPABILITIES = {"operations.v1", "masks.v1", "ai.provenance.v1"}

ERROR_CODES = {
    "OK",
    "INVALID_ARGUMENT",
    "INVALID_STATE",
    "UNSUPPORTED_VERSION",
    "UNSUPPORTED_FEATURE",
    "DECODE_FAILED",
    "UNSUPPORTED_FORMAT",
    "SOURCE_MISSING",
    "SOURCE_CHANGED",
    "SOURCE_ACCESS_DENIED",
    "ASSET_MISSING",
    "ASSET_HASH_MISMATCH",
    "VALIDATION_FAILED",
    "CANCELLED",
    "BUSY",
    "ENGINE_FAILURE",
    "AI_UNAVAILABLE",
    "IO_FAILURE",
    "DURABILITY_FAILURE",
    "INTERNAL",
}

KINDS = {"document", "export", "error", "progress", "renderPlan"}
FORMATS = {"jpeg", "png", "tiff", "heic"}
ANALYSIS_MODES = {"none", "onPhoto", "poster", "overlayOnly"}
DETERMINISM_VALUES = {"exact", "tolerance", "platform", "nondeterministic"}
PROGRESS_STATES = {"running", "cancelling", "cancelled", "completed", "failed"}
METADATA_ALLOW = {"dpi", "tiffResolution", "orientationNormalized"}
HEX64 = re.compile(r"^[0-9a-f]{64}$")
RFC3339 = re.compile(r"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}Z$")
MESSAGE_KEY = re.compile(r"^error\.[a-z0-9_]+(?:\.[a-z0-9_]+)*$")
SEMVER = re.compile(r"^\d+\.\d+\.\d+(?:[-+][0-9A-Za-z.-]+)?$")


class Problems:
    def __init__(self) -> None:
        self.items: list[tuple[str, str]] = []

    def add(self, code: str, message: str) -> None:
        assert code in ERROR_CODES, code
        self.items.append((code, message))

    def codes(self) -> set[str]:
        return {code for code, _ in self.items}


def fail(message: str) -> None:
    raise ValueError(message)


def reject_constant(token: str) -> None:
    fail(f"non-finite number is not allowed: {token}")


def no_duplicate_keys(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            fail(f"duplicate object key: {key!r}")
        result[key] = value
    return result


def check_number_tokens(text: str) -> None:
    """Reject exponent notation and negative zero in raw JSON."""
    i = 0
    in_string = False
    escaped = False
    while i < len(text):
        ch = text[i]
        if in_string:
            if escaped:
                escaped = False
            elif ch == "\\":
                escaped = True
            elif ch == '"':
                in_string = False
            i += 1
            continue
        if ch == '"':
            in_string = True
            i += 1
            continue
        if ch == "-" or ch.isdigit():
            start = i
            i += 1
            while i < len(text) and text[i] in "0123456789.eE+-":
                i += 1
            token = text[start:i]
            if "e" in token or "E" in token:
                fail(f"exponent notation is not canonical: {token}")
            if token in {"-0", "-0.0"}:
                fail("negative zero is not canonical")
            continue
        i += 1


def load_json(path: Path):
    raw = path.read_bytes()
    if raw.startswith(b"\xef\xbb\xbf"):
        fail(f"{path.relative_to(ROOT)}: UTF-8 BOM is not allowed")
    try:
        text = raw.decode("utf-8")
    except UnicodeDecodeError as exc:
        fail(f"{path.relative_to(ROOT)}: invalid UTF-8: {exc}")
    check_number_tokens(text)
    try:
        obj = json.loads(
            text,
            object_pairs_hook=no_duplicate_keys,
            parse_constant=reject_constant,
        )
    except json.JSONDecodeError as exc:
        fail(f"{path.relative_to(ROOT)}: invalid JSON: {exc}")
    return raw, text, obj


def canonical_text(obj, pretty: bool) -> str:
    if pretty:
        return json.dumps(
            obj, ensure_ascii=False, allow_nan=False, indent=2, sort_keys=True
        )
    return json.dumps(
        obj,
        ensure_ascii=False,
        allow_nan=False,
        sort_keys=True,
        separators=(",", ":"),
    )


def check_canonical(path: Path, raw: bytes, obj) -> bytes:
    expected = (canonical_text(obj, pretty=True) + "\n").encode("utf-8")
    if raw != expected:
        fail(f"{path.relative_to(ROOT)}: bytes do not match canonical pretty form")
    return canonical_text(obj, pretty=False).encode("utf-8")


def sha256_hex(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def is_int(value) -> bool:
    return isinstance(value, int) and not isinstance(value, bool)


def is_number(value) -> bool:
    return (
        isinstance(value, (int, float))
        and not isinstance(value, bool)
        and math.isfinite(value)
    )


def is_uint(value) -> bool:
    return is_int(value) and value >= 0


def is_uuid(value) -> bool:
    if not isinstance(value, str):
        return False
    try:
        parsed = uuid.UUID(value)
    except (ValueError, AttributeError, TypeError):
        return False
    return str(parsed) == value


def is_rfc3339(value) -> bool:
    return isinstance(value, str) and bool(RFC3339.fullmatch(value))


def is_hex64(value) -> bool:
    return isinstance(value, str) and bool(HEX64.fullmatch(value))


def require_dict(value, problems: Problems, label: str, code="INVALID_ARGUMENT"):
    if not isinstance(value, dict):
        problems.add(code, f"{label}: expected object")
        return None
    return value


def require_list(value, problems: Problems, label: str, code="INVALID_ARGUMENT"):
    if not isinstance(value, list):
        problems.add(code, f"{label}: expected array")
        return None
    return value


def need(condition: bool, problems: Problems, code: str, message: str) -> bool:
    if not condition:
        problems.add(code, message)
        return False
    return True


def check_nfc(value, problems: Problems, label: str) -> None:
    if isinstance(value, str) and unicodedata.normalize("NFC", value) != value:
        problems.add("INVALID_ARGUMENT", f"{label}: string is not NFC")


def check_fraction(value, problems: Problems, label: str) -> None:
    if not is_number(value) or not (0.0 <= float(value) <= 1.0):
        problems.add("VALIDATION_FAILED", f"{label}: expected 0...1")


def check_point(value, problems: Problems, label: str) -> None:
    obj = require_dict(value, problems, label, "VALIDATION_FAILED")
    if obj is None:
        return
    for axis in ("x", "y"):
        if not is_number(obj.get(axis)) or not (0.0 <= float(obj[axis]) <= 1.0):
            problems.add("VALIDATION_FAILED", f"{label}.{axis}: expected 0...1")
    if "space" in obj and obj["space"] != "source_normalized":
        problems.add("VALIDATION_FAILED", f"{label}.space: unsupported space")


def check_rect(value, problems: Problems, label: str) -> None:
    obj = require_dict(value, problems, label, "VALIDATION_FAILED")
    if obj is None:
        return
    for key in ("x", "y", "width", "height"):
        if not is_number(obj.get(key)):
            problems.add("VALIDATION_FAILED", f"{label}.{key}: expected number")
            return
    x, y = float(obj["x"]), float(obj["y"])
    w, h = float(obj["width"]), float(obj["height"])
    if not (0.0 <= x <= 1.0 and 0.0 <= y <= 1.0):
        problems.add("VALIDATION_FAILED", f"{label}: origin outside 0...1")
    if w <= 0.0 or h <= 0.0:
        problems.add("VALIDATION_FAILED", f"{label}: size must be positive")
    if x + w > 1.0 + 1e-9 or y + h > 1.0 + 1e-9:
        problems.add("VALIDATION_FAILED", f"{label}: rectangle exceeds 0...1")
    if "space" in obj and obj["space"] != "source_normalized":
        problems.add("VALIDATION_FAILED", f"{label}.space: unsupported space")


def check_hsv(value, problems: Problems, label: str) -> None:
    obj = require_dict(value, problems, label, "VALIDATION_FAILED")
    if obj is None:
        return
    if not is_number(obj.get("h")) or not (0.0 <= float(obj["h"]) <= 360.0):
        problems.add("VALIDATION_FAILED", f"{label}.h: expected 0...360")
    for key in ("s", "v"):
        if not is_number(obj.get(key)) or not (0.0 <= float(obj[key]) <= 1.0):
            problems.add("VALIDATION_FAILED", f"{label}.{key}: expected 0...1")


def check_orientation(value, problems: Problems, label: str) -> None:
    obj = require_dict(value, problems, label, "VALIDATION_FAILED")
    if obj is None:
        return
    q = obj.get("quarterTurns")
    if not is_int(q) or q not in (0, 1, 2, 3):
        problems.add("VALIDATION_FAILED", f"{label}.quarterTurns: expected 0...3")
    if not isinstance(obj.get("flipped"), bool):
        problems.add("VALIDATION_FAILED", f"{label}.flipped: expected boolean")
    if not is_number(obj.get("angle")):
        problems.add("VALIDATION_FAILED", f"{label}.angle: expected number")


def check_asset_ref(value, problems: Problems, label: str) -> str | None:
    obj = require_dict(value, problems, label, "VALIDATION_FAILED")
    if obj is None:
        return None
    if not is_uuid(obj.get("assetId")):
        problems.add("VALIDATION_FAILED", f"{label}.assetId: expected UUID")
    if not is_hex64(obj.get("sha256")):
        problems.add("VALIDATION_FAILED", f"{label}.sha256: expected lowercase SHA-256")
    return obj.get("assetId")


def check_color_space(value, problems: Problems, label: str) -> None:
    obj = require_dict(value, problems, label, "VALIDATION_FAILED")
    if obj is None:
        return
    name = obj.get("name")
    if not isinstance(name, str) or not name:
        problems.add("VALIDATION_FAILED", f"{label}.name: expected non-empty string")
    if "iccHash" in obj and obj["iccHash"] is not None:
        if not isinstance(obj["iccHash"], str) or not obj["iccHash"].startswith("sha256:"):
            problems.add("VALIDATION_FAILED", f"{label}.iccHash: expected sha256:... or null")


PARAM_FIELDS = {
    "smooth",
    "blemish",
    "wrinkle",
    "skinToneEvens",
    "darkCircles",
    "skinBrighten",
    "texturePreserve",
    "teethWhiten",
    "eyeBrighten",
    "eyeSharpen",
    "eyeSize",
    "noseSize",
    "noseTip",
    "lipSize",
    "cheekSize",
    "jawWidth",
    "chinLength",
    "faceWidth",
    "faceLength",
    "exposure",
    "contrast",
    "blacks",
    "whites",
    "saturation",
    "vibrance",
    "warmth",
    "clarity",
    "vignette",
    "lookStrength",
    "grain",
    "lipTint",
    "blush",
    "browDefine",
    "eyeshadow",
    "eyeliner",
    "skinFinish",
    "shine",
    "irisEnhance",
    "lashDarken",
    "lipGloss",
    "splitTone",
    "bodySmooth",
    "bodyTone",
    "bodySlim",
    "backgroundBlur",
    "backgroundTone",
    "backgroundSaturation",
    "bodyWaist",
    "bodyArms",
    "bodyLegs",
    "hairColor",
    "hairTint",
    "hairShine",
    "hairVolume",
    "contour",
    "curveShadows",
    "curveMidtones",
    "curveHighlights",
    "lensTint",
    "teethAlign",
    "backgroundFill",
    "backgroundImageAmount",
}

COLOR_PARAM_FIELDS = {
    "lipColor",
    "blushColor",
    "browColor",
    "shadowColor",
    "linerColor",
    "contourColor",
    "lensColor",
    "backgroundFillColor",
}

HSL_FIELDS = {"hslHue", "hslSaturation", "hslLuminance"}
STRING_PARAM_FIELDS = {"lookID", "backgroundImage", "backgroundImageName"}


def check_params(value, problems: Problems, label: str) -> None:
    obj = require_dict(value, problems, label, "VALIDATION_FAILED")
    if obj is None:
        return
    for key, item in obj.items():
        if key in {"schema"}:
            continue
        if key in HSL_FIELDS:
            if not isinstance(item, list) or len(item) != 12:
                problems.add("VALIDATION_FAILED", f"{label}.{key}: expected 12 bands")
            elif not all(is_number(v) for v in item):
                problems.add("VALIDATION_FAILED", f"{label}.{key}: non-numeric band")
            continue
        if key in COLOR_PARAM_FIELDS:
            check_hsv(item, problems, f"{label}.{key}")
            continue
        if key in STRING_PARAM_FIELDS:
            if not isinstance(item, str):
                problems.add("VALIDATION_FAILED", f"{label}.{key}: expected string")
            continue
        if key in PARAM_FIELDS:
            if not is_number(item) or not (-100.0 <= float(item) <= 100.0):
                problems.add("VALIDATION_FAILED", f"{label}.{key}: expected -100...100")
            continue
        # Unknown optional fields are preserved, not rejected.


def check_heal_spot(value, problems: Problems, label: str, plan_style: bool) -> None:
    obj = require_dict(value, problems, label, "VALIDATION_FAILED")
    if obj is None:
        return
    if plan_style:
        for axis in ("x", "y"):
            if not is_number(obj.get(axis)) or not (0.0 <= float(obj[axis]) <= 1.0):
                problems.add("VALIDATION_FAILED", f"{label}.{axis}: expected 0...1")
    else:
        check_point(obj.get("center"), problems, f"{label}.center")
    radius = obj.get("radius")
    if not is_number(radius) or float(radius) <= 0.0:
        problems.add("VALIDATION_FAILED", f"{label}.radius: expected positive number")


def check_sticker(value, problems: Problems, label: str) -> None:
    obj = require_dict(value, problems, label, "VALIDATION_FAILED")
    if obj is None:
        return
    if not is_uuid(obj.get("id")):
        problems.add("VALIDATION_FAILED", f"{label}.id: expected UUID")
    if obj.get("kind") not in {
        "star",
        "heart",
        "sparkle",
        "flower",
        "butterfly",
        "lightning",
    }:
        problems.add("VALIDATION_FAILED", f"{label}.kind: unknown sticker kind")
    check_point(obj.get("center"), problems, f"{label}.center")
    if not is_number(obj.get("size")) or float(obj["size"]) <= 0.0:
        problems.add("VALIDATION_FAILED", f"{label}.size: expected positive number")
    if not is_number(obj.get("rotation")):
        problems.add("VALIDATION_FAILED", f"{label}.rotation: expected number")
    check_fraction(obj.get("opacity"), problems, f"{label}.opacity")
    check_hsv(obj.get("color"), problems, f"{label}.color")


def check_analysis_settings(value, problems: Problems, label: str) -> None:
    obj = require_dict(value, problems, label, "VALIDATION_FAILED")
    if obj is None:
        return
    for key in ("isEnabled", "showsMesh", "showsFaceOutline", "glow"):
        if not isinstance(obj.get(key), bool):
            problems.add("VALIDATION_FAILED", f"{label}.{key}: expected boolean")
    regions = obj.get("regions")
    if not isinstance(regions, list) or not all(isinstance(v, str) for v in regions):
        problems.add("VALIDATION_FAILED", f"{label}.regions: expected string array")
    for key in ("endpoints", "anchors"):
        mapping = obj.get(key)
        if not isinstance(mapping, dict):
            problems.add("VALIDATION_FAILED", f"{label}.{key}: expected object")
        else:
            for name, point in mapping.items():
                check_nfc(name, problems, f"{label}.{key} key")
                check_point(point, problems, f"{label}.{key}.{name}")
    for key in ("lineOpacity", "lineWeight", "marginPercent"):
        if not is_number(obj.get(key)):
            problems.add("VALIDATION_FAILED", f"{label}.{key}: expected number")
    if not isinstance(obj.get("tint"), str):
        problems.add("VALIDATION_FAILED", f"{label}.tint: expected string")
    if obj.get("exportMode") not in {"onPhoto", "poster", "overlayOnly"}:
        problems.add("VALIDATION_FAILED", f"{label}.exportMode: unknown mode")


def check_operation(value, problems: Problems, label: str) -> str | None:
    obj = require_dict(value, problems, label, "VALIDATION_FAILED")
    if obj is None:
        return None
    if not is_uuid(obj.get("id")):
        problems.add("VALIDATION_FAILED", f"{label}.id: expected UUID")
    op_type = obj.get("type")
    if op_type not in OPERATION_RANK:
        problems.add("VALIDATION_FAILED", f"{label}.type: unknown operation type")
        return None
    if obj.get("schema") != 1:
        problems.add("VALIDATION_FAILED", f"{label}.schema: expected 1")

    if op_type == "retouchParameters":
        check_params(obj.get("params"), problems, f"{label}.params")
    elif op_type == "heal":
        spots = require_list(obj.get("spots"), problems, f"{label}.spots", "VALIDATION_FAILED")
        if spots is not None:
            if not spots:
                problems.add("VALIDATION_FAILED", f"{label}.spots: expected at least one")
            for index, spot in enumerate(spots):
                check_heal_spot(spot, problems, f"{label}.spots[{index}]", plan_style=False)
    elif op_type == "aiPatch":
        if not is_uuid(obj.get("editId")):
            problems.add("VALIDATION_FAILED", f"{label}.editId: expected UUID")
        check_asset_ref(obj.get("patch"), problems, f"{label}.patch")
        check_asset_ref(obj.get("alpha"), problems, f"{label}.alpha")
        check_rect(obj.get("box"), problems, f"{label}.box")
        check_orientation(obj.get("orientation"), problems, f"{label}.orientation")
        pixels = require_dict(obj.get("imagePixels"), problems, f"{label}.imagePixels", "VALIDATION_FAILED")
        if pixels is not None:
            for key in ("width", "height"):
                if not is_uint(pixels.get(key)) or pixels[key] == 0:
                    problems.add("VALIDATION_FAILED", f"{label}.imagePixels.{key}: expected positive uint")
        provenance = require_dict(obj.get("provenance"), problems, f"{label}.provenance", "VALIDATION_FAILED")
        if provenance is not None:
            for key in ("modelId", "modelVersion", "engine", "prompt", "preset"):
                if not isinstance(provenance.get(key), str):
                    problems.add("VALIDATION_FAILED", f"{label}.provenance.{key}: expected string")
            if not is_int(provenance.get("seed")):
                problems.add("VALIDATION_FAILED", f"{label}.provenance.seed: expected integer")
            if not is_number(provenance.get("seconds")) or float(provenance["seconds"]) < 0:
                problems.add("VALIDATION_FAILED", f"{label}.provenance.seconds: expected non-negative")
            if not is_int(provenance.get("workerProtocol")):
                problems.add("VALIDATION_FAILED", f"{label}.provenance.workerProtocol: expected integer")
            if not is_rfc3339(provenance.get("startedAt")):
                problems.add("VALIDATION_FAILED", f"{label}.provenance.startedAt: expected RFC3339")
    elif op_type == "stickers":
        items = require_list(obj.get("items"), problems, f"{label}.items", "VALIDATION_FAILED")
        if items is not None:
            for index, item in enumerate(items):
                check_sticker(item, problems, f"{label}.items[{index}]")
    elif op_type == "analysis":
        check_analysis_settings(obj.get("settings"), problems, f"{label}.settings")
        if obj.get("snapshot") is not None:
            problems.add("VALIDATION_FAILED", f"{label}.snapshot: R1 fixtures keep snapshots null")
    elif op_type == "crop":
        check_rect(obj.get("rect"), problems, f"{label}.rect")
    elif op_type == "orientation":
        check_orientation(obj, problems, label)
    return op_type


def check_source(value, problems: Problems, corpus_hashes: dict[str, str]) -> None:
    obj = require_dict(value, problems, "source", "VALIDATION_FAILED")
    if obj is None:
        return
    if not is_uuid(obj.get("assetId")):
        problems.add("VALIDATION_FAILED", "source.assetId: expected UUID")
    name = obj.get("fileName")
    if not isinstance(name, str) or not name:
        problems.add("VALIDATION_FAILED", "source.fileName: expected non-empty string")
    check_nfc(name, problems, "source.fileName")
    relative = obj.get("relativePath")
    if relative is not None:
        if not isinstance(relative, str) or not relative:
            problems.add("VALIDATION_FAILED", "source.relativePath: expected string or null")
        else:
            check_nfc(relative, problems, "source.relativePath")
            if relative.startswith("/") or "\\" in relative:
                problems.add("VALIDATION_FAILED", "source.relativePath: must be portable")
            if ".." in relative.split("/") and not obj.get("external"):
                problems.add("VALIDATION_FAILED", "source.relativePath: escapes package")
    for key in ("external", "embedded", "orientationNormalized"):
        if not isinstance(obj.get(key), bool):
            problems.add("VALIDATION_FAILED", f"source.{key}: expected boolean")
    if not is_uint(obj.get("bytes")) or obj["bytes"] == 0:
        problems.add("VALIDATION_FAILED", "source.bytes: expected positive uint")
    identity = require_dict(obj.get("quickIdentity"), problems, "source.quickIdentity", "VALIDATION_FAILED")
    if identity is not None:
        if not is_uint(identity.get("size")) or identity["size"] == 0:
            problems.add("VALIDATION_FAILED", "source.quickIdentity.size: expected positive uint")
        if identity.get("modifiedAt") is not None and not is_rfc3339(identity["modifiedAt"]):
            problems.add("VALIDATION_FAILED", "source.quickIdentity.modifiedAt: expected RFC3339 or null")
    content = obj.get("contentHash")
    if content is not None:
        content = require_dict(content, problems, "source.contentHash", "VALIDATION_FAILED")
        if content is not None:
            if content.get("algorithm") != "sha256" or not is_hex64(content.get("hex")):
                problems.add("VALIDATION_FAILED", "source.contentHash: expected sha256 hex")
            elif isinstance(name, str) and name in corpus_hashes:
                if content["hex"] != corpus_hashes[name]:
                    problems.add("VALIDATION_FAILED", "source.contentHash: does not match corpus fixture")
    for key in ("pixelWidth", "pixelHeight"):
        if not is_uint(obj.get(key)) or obj[key] == 0:
            problems.add("VALIDATION_FAILED", f"source.{key}: expected positive uint")
    check_color_space(obj.get("colorSpace"), problems, "source.colorSpace")


def check_assets(value, problems: Problems) -> dict[str, dict]:
    table = require_dict(value, problems, "document.assets", "VALIDATION_FAILED")
    result: dict[str, dict] = {}
    if table is None:
        return result
    if table.get("schema") != 1:
        problems.add("VALIDATION_FAILED", "document.assets.schema: expected 1")
    assets = require_list(table.get("assets"), problems, "document.assets.assets", "VALIDATION_FAILED")
    if assets is None:
        return result
    paths = set()
    for index, asset in enumerate(assets):
        label = f"document.assets.assets[{index}]"
        obj = require_dict(asset, problems, label, "VALIDATION_FAILED")
        if obj is None:
            continue
        asset_id = obj.get("assetId")
        if not is_uuid(asset_id):
            problems.add("VALIDATION_FAILED", f"{label}.assetId: expected UUID")
        elif asset_id in result:
            problems.add("VALIDATION_FAILED", f"{label}.assetId: duplicate")
        if not isinstance(obj.get("kind"), str) or not obj["kind"]:
            problems.add("VALIDATION_FAILED", f"{label}.kind: expected string")
        if not isinstance(obj.get("mediaType"), str) or not obj["mediaType"]:
            problems.add("VALIDATION_FAILED", f"{label}.mediaType: expected string")
        if not is_uint(obj.get("bytes")):
            problems.add("VALIDATION_FAILED", f"{label}.bytes: expected uint")
        if not is_hex64(obj.get("sha256")):
            problems.add("VALIDATION_FAILED", f"{label}.sha256: expected lowercase SHA-256")
        path = obj.get("path")
        if not isinstance(path, str) or not path or path.startswith("/") or ".." in path.split("/"):
            problems.add("VALIDATION_FAILED", f"{label}.path: expected portable relative path")
        elif path in paths:
            problems.add("VALIDATION_FAILED", f"{label}.path: duplicate")
        else:
            paths.add(path)
        if isinstance(asset_id, str):
            result[asset_id] = obj
    return result


def check_metadata(value, problems: Problems) -> None:
    obj = require_dict(value, problems, "document.metadata", "VALIDATION_FAILED")
    if obj is None:
        return
    if obj.get("title") is not None and not isinstance(obj["title"], str):
        problems.add("VALIDATION_FAILED", "document.metadata.title: expected string or null")
    if not is_rfc3339(obj.get("createdAt")):
        problems.add("VALIDATION_FAILED", "document.metadata.createdAt: expected RFC3339")
    if not is_rfc3339(obj.get("modifiedAt")):
        problems.add("VALIDATION_FAILED", "document.metadata.modifiedAt: expected RFC3339")
    for key in ("appVersion", "coreVersion"):
        if not isinstance(obj.get(key), str) or not obj[key]:
            problems.add("VALIDATION_FAILED", f"document.metadata.{key}: expected string")
    if not isinstance(obj.get("unknown"), dict):
        problems.add("VALIDATION_FAILED", "document.metadata.unknown: expected object")


def check_operation_list(value, problems: Problems):
    obj = require_dict(value, problems, "document.operations", "VALIDATION_FAILED")
    if obj is None:
        return [], {}
    if obj.get("schema") != 1:
        problems.add("VALIDATION_FAILED", "document.operations.schema: expected 1")
    if obj.get("coordinateSpace") != "source_normalized":
        problems.add("VALIDATION_FAILED", "document.operations.coordinateSpace: expected source_normalized")
    operations = require_list(obj.get("operations"), problems, "document.operations.operations", "VALIDATION_FAILED")
    if operations is None:
        return [], {}

    ids: dict[str, str] = {}
    counts: dict[str, int] = {}
    last_rank = -1
    for index, op in enumerate(operations):
        label = f"document.operations.operations[{index}]"
        op_type = check_operation(op, problems, label)
        if op_type is None:
            continue
        counts[op_type] = counts.get(op_type, 0) + 1
        op_id = op.get("id")
        if isinstance(op_id, str):
            if op_id in ids:
                problems.add("VALIDATION_FAILED", f"{label}.id: duplicate operation id")
            else:
                ids[op_id] = op_type
        rank = OPERATION_RANK[op_type]
        if rank < last_rank:
            problems.add(
                "VALIDATION_FAILED",
                f"{label}: operation type {op_type} is stored after a later stage",
            )
        last_rank = max(last_rank, rank)

    for op_type in SINGLETON_TYPES:
        if counts.get(op_type, 0) > 1:
            problems.add(
                "VALIDATION_FAILED",
                f"document.operations: duplicate singleton {op_type}",
            )
    return operations, ids


def check_document(obj, problems: Problems, corpus_hashes: dict[str, str]):
    if obj.get("schema") != 1:
        problems.add("INVALID_ARGUMENT", "document fixture schema: expected 1")
    doc = require_dict(obj.get("document"), problems, "document", "INVALID_ARGUMENT")
    if doc is None:
        return None
    if not is_uuid(doc.get("id")):
        problems.add("VALIDATION_FAILED", "document.id: expected UUID")
    if not is_uint(doc.get("revision")):
        problems.add("VALIDATION_FAILED", "document.revision: expected uint")
    if doc.get("selectedFace") is not None and not is_int(doc["selectedFace"]):
        problems.add("VALIDATION_FAILED", "document.selectedFace: expected int or null")
    for key in ("capabilities", "requires"):
        values = doc.get(key)
        if not isinstance(values, list) or not all(isinstance(v, str) for v in values):
            problems.add("VALIDATION_FAILED", f"document.{key}: expected string array")
    requires = doc.get("requires")
    if isinstance(requires, list):
        for capability in requires:
            if capability not in KNOWN_CAPABILITIES:
                problems.add(
                    "UNSUPPORTED_FEATURE",
                    f"document.requires: unknown required capability {capability!r}",
                )
    check_source(doc.get("source"), problems, corpus_hashes)
    assets = check_assets(doc.get("assets"), problems)
    operations, ids = check_operation_list(doc.get("operations"), problems)
    check_metadata(doc.get("metadata"), problems)

    for index, op in enumerate(operations):
        if not isinstance(op, dict) or op.get("type") != "aiPatch":
            continue
        for key in ("patch", "alpha"):
            ref = op.get(key)
            if not isinstance(ref, dict):
                continue
            asset_id = ref.get("assetId")
            if asset_id not in assets:
                problems.add(
                    "ASSET_MISSING",
                    f"document.operations[{index}].{key}: asset {asset_id!r} is not in the table",
                )
            elif assets[asset_id].get("sha256") != ref.get("sha256"):
                problems.add(
                    "ASSET_HASH_MISMATCH",
                    f"document.operations[{index}].{key}: hash differs from the asset table",
                )
    return {"document": doc, "operations": ids, "assets": assets}


def check_export(obj, problems: Problems):
    if obj.get("schema") != 1:
        problems.add("INVALID_ARGUMENT", "export fixture schema: expected 1")
    plan = require_dict(obj.get("exportPlan"), problems, "exportPlan", "INVALID_ARGUMENT")
    if plan is None:
        return
    if not is_uint(plan.get("documentRevision")):
        problems.add("VALIDATION_FAILED", "exportPlan.documentRevision: expected uint")
    intent = require_dict(plan.get("intent"), problems, "exportPlan.intent", "VALIDATION_FAILED")
    if intent is not None:
        if intent.get("format") not in FORMATS:
            problems.add("VALIDATION_FAILED", "exportPlan.intent.format: unsupported")
        check_fraction(intent.get("quality"), problems, "exportPlan.intent.quality")
        max_edge = intent.get("maxLongEdge")
        if max_edge is not None and not is_uint(max_edge):
            problems.add("VALIDATION_FAILED", "exportPlan.intent.maxLongEdge: expected null or uint")
        for key in ("aiUpscale", "stripLocationMetadata"):
            if not isinstance(intent.get(key), bool):
                problems.add("VALIDATION_FAILED", f"exportPlan.intent.{key}: expected boolean")
        if intent.get("analysisMode") not in ANALYSIS_MODES:
            problems.add("VALIDATION_FAILED", "exportPlan.intent.analysisMode: unsupported")
        if intent.get("watermark") is not None and not isinstance(intent["watermark"], dict):
            problems.add("VALIDATION_FAILED", "exportPlan.intent.watermark: expected object or null")
        if intent.get("backgroundColor") is not None:
            check_hsv(intent["backgroundColor"], problems, "exportPlan.intent.backgroundColor")
    name = plan.get("outputName")
    if not isinstance(name, str) or not name or "/" in name or "\\" in name:
        problems.add("VALIDATION_FAILED", "exportPlan.outputName: expected file name")
    else:
        check_nfc(name, problems, "exportPlan.outputName")
    proposed = plan.get("proposedURL")
    if not isinstance(proposed, str) or not proposed or proposed.startswith("/") or "://" in proposed or "\\" in proposed or ".." in proposed.split("/"):
        problems.add("VALIDATION_FAILED", "exportPlan.proposedURL: expected portable relative path")
    policy = require_dict(plan.get("metadataPolicy"), problems, "exportPlan.metadataPolicy", "VALIDATION_FAILED")
    if policy is not None:
        if policy.get("mode") not in {"privacyStrip", "preserveAll"}:
            problems.add("VALIDATION_FAILED", "exportPlan.metadataPolicy.mode: unsupported")
        allow = policy.get("allow")
        if not isinstance(allow, list) or not all(isinstance(v, str) for v in allow):
            problems.add("VALIDATION_FAILED", "exportPlan.metadataPolicy.allow: expected string array")
        elif not set(allow).issubset(METADATA_ALLOW):
            problems.add("VALIDATION_FAILED", "exportPlan.metadataPolicy.allow: unknown entry")
        elif policy.get("mode") == "privacyStrip" and allow != sorted(allow):
            problems.add("VALIDATION_FAILED", "exportPlan.metadataPolicy.allow: must be sorted")
    protection = require_dict(plan.get("sourceProtection"), problems, "exportPlan.sourceProtection", "VALIDATION_FAILED")
    if protection is not None and protection.get("refuseIfDestinationIsSource") is not True:
        problems.add("VALIDATION_FAILED", "exportPlan.sourceProtection: source refusal must be true")
    requires = require_dict(plan.get("requiresEngine"), problems, "exportPlan.requiresEngine", "VALIDATION_FAILED")
    if requires is not None:
        if not isinstance(requires.get("minVersion"), str) or not SEMVER.fullmatch(requires["minVersion"]):
            problems.add("VALIDATION_FAILED", "exportPlan.requiresEngine.minVersion: expected semver")
        features = requires.get("features")
        if not isinstance(features, list) or not all(isinstance(v, str) for v in features):
            problems.add("VALIDATION_FAILED", "exportPlan.requiresEngine.features: expected string array")


def check_error(obj, problems: Problems):
    if obj.get("schema") != 1:
        problems.add("INVALID_ARGUMENT", "error fixture schema: expected 1")
    error = require_dict(obj.get("error"), problems, "error", "INVALID_ARGUMENT")
    if error is None:
        return
    if error.get("code") not in ERROR_CODES:
        problems.add("VALIDATION_FAILED", "error.code: unknown taxonomy code")
    key = error.get("messageKey")
    if not isinstance(key, str) or not MESSAGE_KEY.fullmatch(key):
        problems.add("VALIDATION_FAILED", "error.messageKey: expected error.* key")
    if not isinstance(error.get("detail"), dict):
        problems.add("VALIDATION_FAILED", "error.detail: expected object")
    if "debug" in error and not isinstance(error["debug"], str):
        problems.add("VALIDATION_FAILED", "error.debug: expected string")


def check_progress(obj, problems: Problems):
    if obj.get("schema") != 1:
        problems.add("INVALID_ARGUMENT", "progress fixture schema: expected 1")
    progress = require_dict(obj.get("progress"), problems, "progress", "INVALID_ARGUMENT")
    if progress is None:
        return
    if not is_uuid(progress.get("operationId")):
        problems.add("VALIDATION_FAILED", "progress.operationId: expected UUID")
    if progress.get("state") not in PROGRESS_STATES:
        problems.add("VALIDATION_FAILED", "progress.state: unsupported")
    stage = progress.get("stage")
    if stage not in ORCHESTRATION_STAGES:
        problems.add("VALIDATION_FAILED", "progress.stage: unknown stage")
    index = progress.get("stageIndex")
    if not is_int(index) or not (0 <= index < len(ORCHESTRATION_STAGES)):
        problems.add("VALIDATION_FAILED", "progress.stageIndex: out of range")
    elif ORCHESTRATION_STAGES[index] != stage:
        problems.add("VALIDATION_FAILED", "progress.stageIndex: does not match stage")
    check_fraction(progress.get("fraction"), problems, "progress.fraction")
    done, total = progress.get("unitsDone"), progress.get("unitsTotal")
    if not is_uint(done) or not is_uint(total):
        problems.add("VALIDATION_FAILED", "progress units: expected uint")
    elif done > total:
        problems.add("VALIDATION_FAILED", "progress.unitsDone: exceeds total")
    cancel = require_dict(progress.get("cancellation"), problems, "progress.cancellation", "VALIDATION_FAILED")
    if cancel is not None:
        if cancel.get("state") not in {"none", "requested", "acknowledged"}:
            problems.add("VALIDATION_FAILED", "progress.cancellation.state: unsupported")
        requested = cancel.get("requestedAt")
        acknowledged = cancel.get("acknowledgedAt")
        if requested is not None and not is_rfc3339(requested):
            problems.add("VALIDATION_FAILED", "progress.cancellation.requestedAt: expected RFC3339")
        if acknowledged is not None and not is_rfc3339(acknowledged):
            problems.add("VALIDATION_FAILED", "progress.cancellation.acknowledgedAt: expected RFC3339")
        if isinstance(requested, str) and isinstance(acknowledged, str) and acknowledged < requested:
            problems.add("VALIDATION_FAILED", "progress.cancellation: acknowledged before requested")
        if progress.get("state") == "cancelled" and cancel.get("state") != "acknowledged":
            problems.add("VALIDATION_FAILED", "progress.cancellation: cancelled state must be acknowledged")


def check_mask(value, problems: Problems, label: str, assets: dict[str, dict]) -> None:
    obj = require_dict(value, problems, label, "VALIDATION_FAILED")
    if obj is None:
        return
    if not isinstance(obj.get("name"), str) or not obj["name"]:
        problems.add("VALIDATION_FAILED", f"{label}.name: expected string")
    for key in ("width", "height", "bytesPerRow"):
        if not is_uint(obj.get(key)) or obj[key] == 0:
            problems.add("VALIDATION_FAILED", f"{label}.{key}: expected positive uint")
    if is_uint(obj.get("width")) and is_uint(obj.get("bytesPerRow")):
        if obj["bytesPerRow"] < obj["width"]:
            problems.add("VALIDATION_FAILED", f"{label}.bytesPerRow: smaller than width")
    if obj.get("format") != "gray8":
        problems.add("VALIDATION_FAILED", f"{label}.format: expected gray8")
    if obj.get("space") != "mask_raster":
        problems.add("VALIDATION_FAILED", f"{label}.space: expected mask_raster")
    check_point(obj.get("origin"), problems, f"{label}.origin")
    if obj.get("coverage") is not None:
        check_fraction(obj["coverage"], problems, f"{label}.coverage")
    if obj.get("gate") is not None:
        check_fraction(obj["gate"], problems, f"{label}.gate")
    if not is_number(obj.get("feather")) or float(obj["feather"]) < 0.0:
        problems.add("VALIDATION_FAILED", f"{label}.feather: expected non-negative")
    asset_id = obj.get("asset")
    if asset_id not in assets:
        problems.add("ASSET_MISSING", f"{label}.asset: not present in the document asset table")
    elif obj.get("sha256") is not None and assets[asset_id].get("sha256") != obj["sha256"]:
        problems.add("ASSET_HASH_MISMATCH", f"{label}.sha256: differs from asset table")


def check_render_plan(obj, problems: Problems, document_state, index_entry):
    if obj.get("schema") != 1:
        problems.add("INVALID_ARGUMENT", "render plan schema: expected 1")
    source = require_dict(obj.get("source"), problems, "plan.source", "VALIDATION_FAILED")
    if source is not None:
        for key in ("width", "height"):
            if not is_uint(source.get(key)) or source[key] == 0:
                problems.add("VALIDATION_FAILED", f"plan.source.{key}: expected positive uint")
        check_color_space(source.get("colorSpace"), problems, "plan.source.colorSpace")
    if not is_uint(obj.get("documentRevision")):
        problems.add("VALIDATION_FAILED", "plan.documentRevision: expected uint")
    check_orientation(obj.get("orientation"), problems, "plan.orientation")
    crop = obj.get("crop")
    if crop is not None:
        check_rect(crop, problems, "plan.crop")
    parameters = obj.get("parameters")
    if parameters is not None:
        parameters = require_dict(parameters, problems, "plan.parameters", "VALIDATION_FAILED")
        if parameters is not None:
            if parameters.get("schema") != 1:
                problems.add("VALIDATION_FAILED", "plan.parameters.schema: expected 1")
            check_params(parameters, problems, "plan.parameters")

    for index, spot in enumerate(obj.get("heal") if isinstance(obj.get("heal"), list) else []):
        check_heal_spot(spot, problems, f"plan.heal[{index}]", plan_style=True)
    if not isinstance(obj.get("heal"), list):
        problems.add("VALIDATION_FAILED", "plan.heal: expected array")

    ai_patches = obj.get("aiPatches")
    if not isinstance(ai_patches, list):
        problems.add("VALIDATION_FAILED", "plan.aiPatches: expected array")
    else:
        for index, patch in enumerate(ai_patches):
            label = f"plan.aiPatches[{index}]"
            item = require_dict(patch, problems, label, "VALIDATION_FAILED")
            if item is None:
                continue
            if not is_uuid(item.get("patchAsset")):
                problems.add("VALIDATION_FAILED", f"{label}.patchAsset: expected UUID")
            if not is_uuid(item.get("alphaAsset")):
                problems.add("VALIDATION_FAILED", f"{label}.alphaAsset: expected UUID")
            check_rect(item.get("box"), problems, f"{label}.box")
            check_orientation(item.get("orientation"), problems, f"{label}.orientation")

    stickers = obj.get("stickers")
    if not isinstance(stickers, list):
        problems.add("VALIDATION_FAILED", "plan.stickers: expected array")
    else:
        for index, sticker in enumerate(stickers):
            check_sticker(sticker, problems, f"plan.stickers[{index}]")

    if obj.get("analysis") is not None:
        check_analysis_settings(obj.get("analysis"), problems, "plan.analysis")

    target = require_dict(obj.get("target"), problems, "plan.target", "VALIDATION_FAILED")
    if target is not None:
        if target.get("kind") not in {"preview", "export"}:
            problems.add("VALIDATION_FAILED", "plan.target.kind: unsupported")
        if not is_uint(target.get("maxLongEdge")):
            problems.add("VALIDATION_FAILED", "plan.target.maxLongEdge: expected uint")

    determinism = require_dict(obj.get("determinism"), problems, "plan.determinism", "VALIDATION_FAILED")
    if determinism is not None:
        for key in ("heal", "color", "vision", "ai"):
            if determinism.get(key) not in DETERMINISM_VALUES:
                problems.add("VALIDATION_FAILED", f"plan.determinism.{key}: unsupported label")

    engine = require_dict(obj.get("engine"), problems, "plan.engine", "VALIDATION_FAILED")
    if engine is not None:
        for key in ("name", "version"):
            if not isinstance(engine.get(key), str) or not engine[key]:
                problems.add("VALIDATION_FAILED", f"plan.engine.{key}: expected string")

    masks = obj.get("masks")
    assets = document_state["assets"] if document_state else {}
    if not isinstance(masks, list):
        problems.add("VALIDATION_FAILED", "plan.masks: expected array")
    else:
        names = set()
        for index, mask in enumerate(masks):
            check_mask(mask, problems, f"plan.masks[{index}]", assets)
            if isinstance(mask, dict) and isinstance(mask.get("name"), str):
                if mask["name"] in names:
                    problems.add("VALIDATION_FAILED", f"plan.masks[{index}].name: duplicate")
                names.add(mask["name"])

    stages = obj.get("stages")
    if not isinstance(stages, list):
        problems.add("INVALID_ARGUMENT", "plan.stages: missing or not an array")
        stages = []
    if len(stages) != len(STAGES):
        problems.add("INVALID_ARGUMENT", f"plan.stages: expected {len(STAGES)} entries")
    for index, expected in enumerate(STAGES):
        if index >= len(stages):
            break
        label = f"plan.stages[{index}]"
        stage = require_dict(stages[index], problems, label, "VALIDATION_FAILED")
        if stage is None:
            continue
        if stage.get("index") != index + 1:
            problems.add("VALIDATION_FAILED", f"{label}.index: expected {index + 1}")
        if stage.get("stage") != expected:
            problems.add("VALIDATION_FAILED", f"{label}.stage: expected {expected}")
        if not isinstance(stage.get("enabled"), bool):
            problems.add("VALIDATION_FAILED", f"{label}.enabled: expected boolean")
        operation_ids = stage.get("operationIds")
        if not isinstance(operation_ids, list) or not all(is_uuid(v) for v in operation_ids):
            problems.add("VALIDATION_FAILED", f"{label}.operationIds: expected UUID array")
            operation_ids = []
        if stage.get("enabled") is True and not operation_ids:
            problems.add("VALIDATION_FAILED", f"{label}: enabled stage has no operation")
        if stage.get("enabled") is False and operation_ids:
            problems.add("VALIDATION_FAILED", f"{label}: disabled stage has operations")

    if document_state is None:
        return
    doc = document_state["document"]
    doc_source = doc.get("source", {})
    if isinstance(source, dict) and isinstance(doc_source, dict):
        if source.get("width") != doc_source.get("pixelWidth") or source.get("height") != doc_source.get("pixelHeight"):
            problems.add("VALIDATION_FAILED", "plan.source: dimensions differ from document source")
        plan_cs = source.get("colorSpace", {}).get("name")
        doc_cs = doc_source.get("colorSpace", {}).get("name")
        if plan_cs != doc_cs:
            problems.add("VALIDATION_FAILED", "plan.source.colorSpace: differs from document source")
    if obj.get("documentRevision") != doc.get("revision"):
        problems.add("VALIDATION_FAILED", "plan.documentRevision: differs from document revision")

    operation_types = document_state["operations"]
    for index, stage in enumerate(stages):
        if not isinstance(stage, dict):
            continue
        allowed = STAGE_OP_TYPE.get(stage.get("stage"))
        for op_id in stage.get("operationIds", []) if isinstance(stage.get("operationIds"), list) else []:
            if op_id not in operation_types:
                problems.add("INVALID_ARGUMENT", f"plan.stages[{index}]: unknown operation id {op_id}")
            elif operation_types[op_id] != allowed:
                problems.add("VALIDATION_FAILED", f"plan.stages[{index}]: operation type is not allowed")

    doc_ops = doc.get("operations", {}).get("operations", [])
    doc_crop = next((op for op in doc_ops if isinstance(op, dict) and op.get("type") == "crop"), None)
    final_stage = stages[-1] if stages and isinstance(stages[-1], dict) else {}
    if crop is None:
        if final_stage.get("enabled") is not False or final_stage.get("operationIds"):
            problems.add("VALIDATION_FAILED", "plan.stages[16]: crop is absent but finalCrop is active")
    else:
        if doc_crop is None:
            problems.add("VALIDATION_FAILED", "plan.crop: document has no crop operation")
        elif final_stage.get("operationIds") != [doc_crop.get("id")]:
            problems.add("VALIDATION_FAILED", "plan.stages[16]: does not reference the document crop")

    doc_orientation = next((op for op in doc_ops if isinstance(op, dict) and op.get("type") == "orientation"), None)
    if doc_orientation is None:
        expected_orientation = {"angle": 0, "flipped": False, "quarterTurns": 0}
    else:
        expected_orientation = {
            "angle": doc_orientation.get("angle"),
            "flipped": doc_orientation.get("flipped"),
            "quarterTurns": doc_orientation.get("quarterTurns"),
        }
    if obj.get("orientation") != expected_orientation:
        problems.add("VALIDATION_FAILED", "plan.orientation: differs from document orientation")

    doc_params = next((op for op in doc_ops if isinstance(op, dict) and op.get("type") == "retouchParameters"), None)
    expected_params = {"schema": 1}
    if doc_params is not None:
        expected_params.update(doc_params.get("params", {}))
    if obj.get("parameters") != expected_params:
        problems.add("VALIDATION_FAILED", "plan.parameters: differs from document retouch parameters")

    patch_ids = {
        op.get("id")
        for op in doc_ops
        if isinstance(op, dict) and op.get("type") == "aiPatch"
    }
    for index, patch in enumerate(ai_patches if isinstance(ai_patches, list) else []):
        if not isinstance(patch, dict):
            continue
        for key in ("patchAsset", "alphaAsset"):
            if patch.get(key) not in assets:
                problems.add("ASSET_MISSING", f"plan.aiPatches[{index}].{key}: not in asset table")
    listed_patches = {
        op_id
        for stage in stages
        if isinstance(stage, dict) and stage.get("stage") == "aiPatch"
        for op_id in (stage.get("operationIds") or [])
    }
    if listed_patches != patch_ids:
        problems.add("VALIDATION_FAILED", "plan.stages[1]: AI patch ids differ from document")

    if index_entry.get("corpusFixtures"):
        for corpus_id in index_entry["corpusFixtures"]:
            if corpus_id not in CORPUS_IDS:
                problems.add("VALIDATION_FAILED", f"corpusFixtures: unknown corpus id {corpus_id}")


def validate_fixture(kind: str, obj, problems: Problems, corpus_hashes, documents, index_entry):
    if kind == "document":
        state = check_document(obj, problems, corpus_hashes)
        if state is not None:
            documents[index_entry["id"]] = state
    elif kind == "export":
        check_export(obj, problems)
    elif kind == "error":
        check_error(obj, problems)
    elif kind == "progress":
        check_progress(obj, problems)
    elif kind == "renderPlan":
        reference = index_entry.get("documentFixture")
        state = documents.get(reference) if reference else None
        if reference and state is None:
            problems.add("INVALID_ARGUMENT", f"documentFixture {reference!r} is not a loaded document")
        check_render_plan(obj, problems, state, index_entry)
    else:
        problems.add("INVALID_ARGUMENT", f"unknown fixture kind {kind!r}")


CORPUS_IDS: set[str] = set()


def verify_corpus() -> tuple[dict[str, str], dict]:
    manifest_path = CORPUS / "Fixtures" / "MANIFEST.json"
    baselines_path = CORPUS / "baselines.json"
    lock_path = FIXTURES / "corpus-lock.json"
    for path in (manifest_path, baselines_path, lock_path):
        if not path.is_file():
            fail(f"missing corpus file: {path.relative_to(ROOT)}")

    _, _, manifest = load_json(manifest_path)
    _, _, baselines = load_json(baselines_path)
    lock_raw, _, lock = load_json(lock_path)
    check_canonical(lock_path, lock_raw, lock)
    if lock.get("schema") != 1:
        fail("corpus-lock.json: schema must be 1")

    manifest_sha = sha256_hex(manifest_path.read_bytes())
    baselines_sha = sha256_hex(baselines_path.read_bytes())
    if manifest_sha != lock.get("manifestSha256"):
        fail("corpus manifest hash differs from corpus-lock.json")
    if baselines_sha != lock.get("baselinesSha256"):
        fail("corpus baselines hash differs from corpus-lock.json")

    fixtures = manifest.get("fixtures")
    if not isinstance(fixtures, list):
        fail("corpus manifest: fixtures must be an array")
    ids = [item.get("id") for item in fixtures if isinstance(item, dict)]
    if len(ids) != len(set(ids)):
        fail("corpus manifest: duplicate fixture ids")
    if lock.get("counts", {}).get("corpusFixtures") != len(fixtures):
        fail("corpus fixture count differs from lock")

    hashes: dict[str, str] = {}
    for item in fixtures:
        if not isinstance(item, dict):
            fail("corpus manifest: fixture entry is not an object")
        fixture_id = item.get("id")
        file_name = item.get("file")
        expected = item.get("sha256")
        if not isinstance(fixture_id, str) or not isinstance(file_name, str):
            fail("corpus manifest: fixture id/file missing")
        path = CORPUS / "Fixtures" / file_name
        if not path.is_file():
            fail(f"corpus fixture missing: {file_name}")
        actual = sha256_hex(path.read_bytes())
        if actual != expected:
            fail(f"corpus fixture hash mismatch: {fixture_id}")
        hashes[file_name] = actual
        CORPUS_IDS.add(fixture_id)

    cases = baselines.get("cases")
    if not isinstance(cases, list):
        fail("corpus baselines: cases must be an array")
    case_ids = [case.get("id") for case in cases if isinstance(case, dict)]
    if len(case_ids) != len(set(case_ids)):
        fail("corpus baselines: duplicate case ids")
    if lock.get("counts", {}).get("baselineCases") != len(cases):
        fail("corpus case count differs from lock")
    fixture_ids = set(ids)
    for case in cases:
        if not isinstance(case, dict) or case.get("fixture") not in fixture_ids:
            fail("corpus baselines: case references an unknown fixture")

    reference_cases = sorted(
        case.get("id") for case in cases if isinstance(case, dict) and case.get("reference")
    )
    lock_references = lock.get("referenceFiles")
    if not isinstance(lock_references, list):
        fail("corpus lock: referenceFiles must be an array")
    lock_reference_ids = [item.get("caseId") for item in lock_references if isinstance(item, dict)]
    if reference_cases != sorted(lock_reference_ids):
        fail("corpus lock: reference case set differs from baselines")
    for item in lock_references:
        if not isinstance(item, dict):
            fail("corpus lock: reference entry is not an object")
        case_id = item.get("caseId")
        file_name = item.get("file")
        expected = item.get("sha256")
        path = CORPUS / "References" / file_name
        if not path.is_file():
            fail(f"corpus reference missing: {file_name}")
        if sha256_hex(path.read_bytes()) != expected:
            fail(f"corpus reference hash mismatch: {case_id}")

    export_files = sorted(
        path
        for path in (CORPUS / "Exports").iterdir()
        if path.is_file() and not path.name.startswith(".")
    )
    lock_exports = lock.get("exports")
    if not isinstance(lock_exports, list):
        fail("corpus lock: exports must be an array")
    lock_export_files = sorted(item.get("file") for item in lock_exports if isinstance(item, dict))
    if [path.name for path in export_files] != lock_export_files:
        fail("corpus export file set differs from lock")
    for item in lock_exports:
        if not isinstance(item, dict):
            fail("corpus lock: export entry is not an object")
        # Export bytes are not reproducible across encoder runs; baselines.json
        # records their structure and dimensions, not hashes.
        if not isinstance(item.get("file"), str) or not item["file"]:
            fail("corpus lock: export entry is missing a file name")

    methodology = ROOT / "Docs" / "IMAGE_COMPARISON_METHODOLOGY.md"
    if not methodology.is_file():
        fail("comparison methodology document is missing")
    if lock.get("comparisonMethodology") != "Docs/IMAGE_COMPARISON_METHODOLOGY.md":
        fail("corpus lock: comparison methodology path differs")
    return hashes, {
        "fixtures": len(fixtures),
        "cases": len(cases),
        "references": len(reference_cases),
        "exports": len(export_files),
    }


def verify_fixture_index(corpus_hashes: dict[str, str]) -> tuple[int, int]:
    index_path = FIXTURES / "index.json"
    if not index_path.is_file():
        fail(f"missing fixture index: {index_path.relative_to(ROOT)}")
    raw, _, index = load_json(index_path)
    check_canonical(index_path, raw, index)
    if index.get("schema") != 1:
        fail("fixture index: schema must be 1")
    entries = index.get("fixtures")
    if not isinstance(entries, list):
        fail("fixture index: fixtures must be an array")

    ids: set[str] = set()
    paths: set[str] = set()
    entries_by_id: dict[str, dict] = {}
    for position, entry in enumerate(entries):
        if not isinstance(entry, dict):
            fail(f"fixture index[{position}]: entry is not an object")
        fixture_id = entry.get("id")
        if not isinstance(fixture_id, str) or not fixture_id:
            fail(f"fixture index[{position}]: id missing")
        if fixture_id in ids:
            fail(f"fixture index: duplicate fixture id {fixture_id}")
        ids.add(fixture_id)
        entries_by_id[fixture_id] = entry
        kind = entry.get("kind")
        if kind not in KINDS:
            fail(f"fixture {fixture_id}: unknown kind")
        path_text = entry.get("path")
        if (
            not isinstance(path_text, str)
            or path_text.startswith("/")
            or "\\" in path_text
            or ".." in path_text.split("/")
            or path_text in paths
        ):
            fail(f"fixture {fixture_id}: invalid or duplicate path")
        paths.add(path_text)
        if entry.get("schemaVersion") != 1:
            fail(f"fixture {fixture_id}: schemaVersion must be 1")
        expect = entry.get("expect")
        if expect not in {"valid", "invalid"}:
            fail(f"fixture {fixture_id}: expect must be valid or invalid")
        if expect == "invalid" and entry.get("expectedCode") not in ERROR_CODES:
            fail(f"fixture {fixture_id}: invalid fixture needs a taxonomy expectedCode")
        if expect == "valid" and "expectedCode" in entry:
            fail(f"fixture {fixture_id}: valid fixture must not declare expectedCode")
        if kind == "renderPlan" and entry.get("documentFixture") not in entries_by_id:
            # The referenced entry may appear later; checked after the loop.
            pass
        if kind != "renderPlan" and "documentFixture" in entry:
            fail(f"fixture {fixture_id}: only render plans declare documentFixture")
        corpus_refs = entry.get("corpusFixtures", [])
        if not isinstance(corpus_refs, list) or not all(isinstance(v, str) for v in corpus_refs):
            fail(f"fixture {fixture_id}: corpusFixtures must be a string array")
        for corpus_id in corpus_refs:
            if corpus_id not in CORPUS_IDS:
                fail(f"fixture {fixture_id}: unknown corpus fixture {corpus_id}")

    if [entry["id"] for entry in entries] != sorted(ids):
        fail("fixture index: entries must be sorted by id")

    documents: dict[str, dict] = {}
    valid = 0
    invalid = 0
    for entry in entries:
        fixture_id = entry["id"]
        path = FIXTURES / entry["path"]
        if not path.is_file():
            fail(f"fixture {fixture_id}: file missing")
        raw, _, obj = load_json(path)
        compact = check_canonical(path, raw, obj)
        digest = sha256_hex(compact)
        if digest != entry.get("sha256"):
            fail(f"fixture {fixture_id}: sha256 differs from index")
        schema = obj.get("schema") if isinstance(obj, dict) else None
        if schema != entry["schemaVersion"]:
            fail(f"fixture {fixture_id}: schema does not match index")

        problems = Problems()
        if entry["kind"] == "renderPlan":
            reference = entry.get("documentFixture")
            if reference not in documents:
                fail(f"fixture {fixture_id}: referenced document {reference!r} is not valid/loaded")
        validate_fixture(entry["kind"], obj, problems, corpus_hashes, documents, entry)

        if entry["expect"] == "valid":
            valid += 1
            if problems.items:
                code, message = problems.items[0]
                fail(f"fixture {fixture_id}: expected valid, got {code}: {message}")
        else:
            invalid += 1
            if not problems.items:
                fail(f"fixture {fixture_id}: expected invalid, but no problem was found")
            if entry["expectedCode"] not in problems.codes():
                found = ", ".join(sorted(problems.codes()))
                fail(
                    f"fixture {fixture_id}: expected {entry['expectedCode']}, found {found}"
                )
    return valid, invalid


def main() -> int:
    try:
        corpus_hashes, corpus_counts = verify_corpus()
        valid, invalid = verify_fixture_index(corpus_hashes)
    except ValueError as exc:
        print(f"R1 conformance: FAIL\n  {exc}", file=sys.stderr)
        return 1

    print("R1 conformance: PASS")
    print(
        f"  fixtures: {valid + invalid} ({valid} valid, {invalid} invalid)"
    )
    print(
        "  corpus lock: "
        f"{corpus_counts['fixtures']} fixtures, "
        f"{corpus_counts['cases']} cases, "
        f"{corpus_counts['references']} references, "
        f"{corpus_counts['exports']} exports"
    )
    print("  canonical JSON: UTF-8, sorted keys, 2-space pretty form, SHA-256 verified")
    print("  render plans: 17 stages in canonical order")
    return 0


if __name__ == "__main__":
    sys.exit(main())
