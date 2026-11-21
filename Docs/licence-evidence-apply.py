#!/usr/bin/env python3
"""Adds the recorded weights-licence evidence to Resources/model-catalog.json.

Every value here is transcribed from /private/tmp/rs-model-licences/MODEL_LICENSES.md
(sections 0.1, 2.1, 3.1, 6, 7.1 and Appendix A). All reads are dated 2026-11-21.
The script only ever adds keys: it asserts that no pre-existing key changes.
"""
import json
import pathlib
import collections

ROOT = pathlib.Path(__file__).resolve().parent.parent
CATALOG = ROOT / "Resources" / "model-catalog.json"

READ_ON = "2026-11-21"

EVIDENCE = collections.OrderedDict([
    ("flux2-klein-4b-q4", collections.OrderedDict([
        ("licenseUrl", "https://huggingface.co/mflux-community/flux2-klein-4b-mflux-q4"),
        ("readOn", READ_ON),
        ("explicit", True),
        ("commercialOk", True),
        ("noticeText",
         "Apache-2.0. Redistributing or mirroring these weights requires a copy of the "
         "Apache-2.0 licence, the retained copyright and licence notices, a statement of "
         "changes, and any NOTICE text from the source repository."),
        ("verdict", "usable"),
        ("verdictReason",
         "The FLUX.2-klein-4B card states the weights are open for commercial use under "
         "Apache-2.0, so the grant is explicit rather than inferred from a repository tag."),
        ("datasetNote", None),
    ])),
    ("sam2.1-hiera-tiny", collections.OrderedDict([
        ("licenseUrl", "https://huggingface.co/facebook/sam2.1-hiera-tiny"),
        ("readOn", READ_ON),
        ("explicit", True),
        ("commercialOk", True),
        ("noticeText",
         "Apache-2.0. Redistributing or mirroring this checkpoint requires a copy of the "
         "Apache-2.0 licence, the retained copyright and licence notices, a statement of "
         "changes, and any NOTICE text from facebookresearch/sam2."),
        ("verdict", "usable"),
        ("verdictReason",
         "The SAM 2 README explicitly licenses the model checkpoints under Apache-2.0, "
         "separately from the repository licence."),
        # The dossier records the SAM 2 training set as NOT CONFIRMED, so no
        # residual-risk statement is asserted here.
        ("datasetNote", None),
    ])),
    ("swin2sr-x4", collections.OrderedDict([
        ("licenseUrl", "https://huggingface.co/caidas/swin2SR-realworld-sr-x4-64-bsrgan-psnr"),
        ("readOn", READ_ON),
        ("explicit", False),
        ("commercialOk", True),
        ("noticeText",
         "Apache-2.0. Redistributing or mirroring pytorch_model.bin requires a copy of the "
         "Apache-2.0 licence, the retained copyright notices, a statement of changes, and "
         "any NOTICE text; the upstream code licence carries \u201cCopyright [2021] [SwinIR "
         "Authors]\u201d."),
        ("verdict", "usable-with-conditions"),
        ("verdictReason",
         "The only weights statement is the repository-level license:apache-2.0 tag on the "
         "Hugging Face repo whose sole payload is the checkpoint, so the grant is inferred "
         "rather than authored about the weights."),
        ("datasetNote",
         "Swin2SR's own training set is not confirmed; DIV2K, the usual corpus in this "
         "family, is made available for academic research purposes only, which is a "
         "residual dataset risk and not a term of the recorded weight grant."),
    ])),
    ("migan", collections.OrderedDict([
        ("licenseUrl",
         "https://raw.githubusercontent.com/Picsart-AI-Research/MI-GAN/main/LICENSE-WEIGHTS"),
        ("readOn", READ_ON),
        ("explicit", True),
        ("commercialOk", True),
        ("noticeText",
         "MIT. Redistributing or mirroring this ONNX requires the copyright line and the "
         "full permission notice from LICENSE-WEIGHTS (Picsart AI Research, 2024)."),
        ("verdict", "usable"),
        ("verdictReason",
         "The authors ship a dedicated MIT LICENSE-WEIGHTS next to the MIT code licence, "
         "and the ONNX is their own pipeline export."),
        # Places2 terms could not be fetched (dossier section 9 item 1), so the
        # dataset position stays unconfirmed instead of being stamped with a claim.
        ("datasetNote", None),
    ])),
])


def main() -> int:
    before_text = CATALOG.read_text(encoding="utf-8")
    catalog = json.loads(before_text, object_pairs_hook=collections.OrderedDict)

    def snapshot(node, prefix=""):
        out = {}
        if isinstance(node, dict):
            for k, v in node.items():
                out.update(snapshot(v, f"{prefix}/{k}"))
        elif isinstance(node, list):
            for i, v in enumerate(node):
                out.update(snapshot(v, f"{prefix}[{i}]"))
        else:
            out[prefix] = node
        return out

    old = snapshot(catalog)

    ids = [e["id"] for e in catalog["entries"]]
    missing = [i for i in ids if i not in EVIDENCE]
    extra = [i for i in EVIDENCE if i not in ids]
    assert not missing, f"no evidence drafted for {missing}"
    assert not extra, f"evidence drafted for unknown entries {extra}"

    # The edit is textual on purpose: re-dumping the whole file would rewrite
    # every entry's closing brace to add a comma and re-order nothing else, so a
    # reviewer could not see that this gate only ever adds keys. Each entry's
    # last recorded key is located and the evidence block appended after it.
    text = before_text
    for entry_id, evidence in EVIDENCE.items():
        body = collections.OrderedDict(
            (k, v) for k, v in evidence.items() if v is not None)
        # The inner object is dumped at depth 1 (member indent 6, its keys at
        # 8) to match the file, then hung off the previous last key with a
        # comma. Dumping it bare and wrapping avoids fiddling with brace lines.
        inner = json.dumps(body, indent=2, ensure_ascii=False).splitlines()
        # inner[0] is "{" and inner[-1] is "}"; drop both and write our own.
        shape = ["      \"weightsEvidence\": {"]
        shape += ["      " + ln for ln in inner[1:-1]]
        shape.append("      }")
        block = ",\n" + "\n".join(shape)
        start = text.index(f'"id": "{entry_id}"')
        end = text.index("\n    }", start)
        (last_key, last_value), = entry_last_key(text, entry_id)
        # Re-parse the entry body and confirm the insertion point really is the
        # entry's final recorded key, so the block can only ever be appended.
        reparsed = json.loads("{" + text[start:end] + "\n}")
        assert list(reparsed)[-1] == last_key, (entry_id, list(reparsed)[-3:])
        assert reparsed[last_key] == last_value, entry_id
        text = text[:end] + block + text[end:]

    CATALOG.write_text(text, encoding="utf-8")

    new_catalog = json.loads(CATALOG.read_text(encoding="utf-8"),
                             object_pairs_hook=collections.OrderedDict)
    after = snapshot(new_catalog)
    changed = {k: (v, after[k]) for k, v in old.items() if after.get(k) != v}
    assert not changed, f"pre-existing values changed: {changed}"
    added = sorted(set(after) - set(old))
    removed = sorted(set(old) - set(after))
    assert not removed, f"keys removed: {removed}"
    for entry in new_catalog["entries"]:
        assert set(entry["weightsEvidence"]) == set(
            k for k, v in EVIDENCE[entry["id"]].items() if v is not None)
    print(f"OK: {len(added)} keys added, 0 changed, 0 removed")
    print("byte-for-byte outside additions:",
          CATALOG.read_text(encoding="utf-8").endswith("\n") == before_text.endswith("\n"))
    return 0


def entry_last_key(text: str, entry_id: str):
    """Returns the single key/value pair that ends the entry, as a JSON probe."""
    start = text.index(f'"id": "{entry_id}"')
    end = text.index("\n    }", start)
    lines = [ln for ln in text[start:end].splitlines() if ln.strip()]
    last = lines[-1].strip()
    obj = json.loads("{" + last + "}")
    assert len(obj) == 1, obj
    return list(obj.items())


if __name__ == "__main__":
    raise SystemExit(main())
