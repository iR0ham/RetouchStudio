# StudioCore canonical JSON

**Status: R1 draft — provisional contract.** This document defines the byte-level
serialization that the R1 conformance fixtures use and that future StudioCore
consumers must match. Only the Python reference implementation in
`Tests/Conformance/conformance.py` has been executed. Byte-for-byte agreement
with Swift, Rust, C/C++, Go, or Qt serializers is **NOT VERIFIED** until each of
those languages has a passing test against the same fixtures.

Related documents:

- `Docs/STUDIOCORE_INTERFACE_DESIGN.md` — document model, render plan, error taxonomy.
- `Docs/STUDIOCORE_ARCHITECTURE.md` — engine boundary and pipeline.
- `Docs/STUDIOCORE_CONFORMANCE_R1.md` — R1 scope, fixture inventory, ABI draft.

---

## 1. Scope

Canonical JSON is the stable interchange form for:

- project documents (schemas in the R1 fixture envelope),
- render plans,
- export configuration,
- domain errors,
- progress and cancellation reports.

It is **not** a replacement for the current on-disk v3 project format. The app
keeps writing v3 exactly as it does today; these fixtures describe the contract
a future core must accept and produce.

---

## 2. Encoding

| Rule | Requirement |
|---|---|
| Character encoding | UTF-8 |
| Byte-order mark | Forbidden |
| Invalid UTF-8 | Rejected |
| Normalization | Strings must be NFC |
| Line ending | LF only |
| Trailing newline | Exactly one LF at end of file (pretty form) |

The R1 validator rejects a BOM, rejects bytes that do not decode as UTF-8, and
rejects any string whose NFC normalization differs from the stored value.
Normalization is a producer responsibility: encoders must normalize file names
and other text before writing.

Canonical JSON files contain no comments and no non-JSON syntax.

---

## 3. Pretty form (files on disk)

Every fixture file is the following Python expression, encoded as UTF-8 with no
BOM:

```python
json.dumps(value, ensure_ascii=False, allow_nan=False,
           indent=2, sort_keys=True) + "\n"
```

Consequences:

- Object members are sorted by Unicode code point, ascending, at every depth.
  Array order is never changed by sorting.
- Two spaces per nesting level.
- A member line is `"key": value`; a value that is an object or array starts on
  the same line as its key and expands below it.
- Commas separate members; no comma follows the last member.
- Empty objects and arrays are written as `{}` and `[]` on one line.
- No trailing whitespace on any line.
- Exactly one LF terminates the file.

The validator compares the **raw file bytes** against this form. A fixture with
reordered keys, tabs, four-space indentation, CRLF, an extra blank line, or a
missing final newline fails the gate even if it parses as valid JSON.

---

## 4. Compact form and stable hash

The compact form is:

```python
json.dumps(value, ensure_ascii=False, allow_nan=False,
           sort_keys=True, separators=(",", ":"))
```

with **no** trailing newline. The stable content hash is:

```text
sha256(lowercase_hex, over the compact UTF-8 bytes)
```

`Tests/Conformance/Fixtures/index.json` records this hash for every fixture, and
`corpus-lock.json` records the same form for the corpus manifest, baselines, and
reference images. Export files are listed by name only: their bytes are not
reproducible across encoder runs, and `baselines.json` records their structure
and dimensions instead. A file whose pretty bytes are correct but whose
semantic content changed will still fail the pinned hash, which is the intended
break-glass signal.

---

## 5. Numbers

- Integers are written in decimal without a sign for non-negative values.
- Exponent notation (`1e3`, `2.5E-4`) is not canonical and is rejected.
- Negative zero (`-0`, `-0.0`) is rejected.
- `NaN`, `Infinity`, and `-Infinity` are invalid JSON and are rejected.
- A value declared as a float keeps a decimal point in the reference encoder;
  `1.0` is not rewritten as `1`.
- A value declared as an integer is never serialized as a float.

Range rules are schema rules, not serialization rules: for example a fraction
must be in `0.0...1.0`, a pixel dimension must be a positive integer, and a
revision must be an unsigned integer. Booleans are not accepted where an
integer is required.

**Cross-language caution.** Shortest-round-trip float formatting is a property
of the reference Python encoder. Whether Swift, Rust, and C++ produce the same
text for the same binary float has **NOT VERIFIED**. A future core must either
adopt a fixed decimal formatting rule or prove equality against these fixtures
before the hash is used across languages.

---

## 6. Strings and identifiers

- Non-ASCII text is written directly, not as `\uXXXX` escapes.
- Only characters that JSON requires to be escaped are escaped.
- NFC applies to file names, relative paths, titles, and free text.
- Identifiers are opaque strings with these shapes:

| Kind | Shape |
|---|---|
| Object / operation / asset ID | Canonical lowercase UUID (`8-4-4-4-12`) |
| Content hash | 64 lowercase hexadecimal characters, SHA-256 |
| Timestamp | UTC RFC 3339, exactly three fractional digits, `Z` suffix |
| Error message key | `error.<segment>[.<segment>]*`, lowercase |
| Media type | Lowercase `type/subtype` |
| Semver engine version | `major.minor.patch` with optional suffix |

The R1 validator accepts a UUID only when `str(uuid.UUID(value)) == value`,
which rejects uppercase, braces, and alternate spellings. UUID version and
variant bits are not otherwise constrained by these fixtures.

---

## 7. Objects, unknown fields, and `null`

- Duplicate keys in one object are invalid.
- Unknown **optional** fields are accepted and must be preserved by a reader
  that rewrites the document. The R1 validator accepts the
  `DOC-UNKNOWN-FIELDS` fixture but does not itself round-trip it; preservation
  is a contract on implementations, not a property the runner proves.
- Unknown **required** capabilities are refused with `UNSUPPORTED_FEATURE`.
  `document.requires` is the only place a v1 fixture can demand a capability.
- Nullable fields are present with `null` when there is no value. Fields that
  are part of the declared schema are written explicitly rather than omitted.
  Omission is reserved for fields the schema declares optional; a reader must
  treat an omitted optional field the same as its documented default.

Unknown fields never change the meaning of known fields. A reader that does not
understand an unknown field must not reinterpret it.

---

## 8. Arrays and ordering

Arrays are ordered. Canonicalization only sorts object keys; it never sorts an
array. Where the schema defines an order, the order is normative and checked:

- `document.operations.operations` is stored in non-decreasing stage rank:
  `orientation` 0, `heal` 1, `aiPatch` 2, `retouchParameters` 3,
  `stickers` 16, `crop` 17, `analysis` 18. **Provisional:** this is the R1
  storage order; it is not yet the on-disk v3 order and may change before a
  format is frozen.
- `renderPlan.stages` is always the 17 canonical stages in pipeline order,
  with contiguous `index` values `1...17`.
- `exportPlan.metadataPolicy.allow` is sorted ascending.
- `Tests/Conformance/Fixtures/index.json` entries are sorted by fixture ID.
- The asset table and operation sub-arrays (heal spots, AI patches, stickers)
  are not order-constrained by the R1 runner. Preserve insertion order until a
  later contract says otherwise.

Arrays must not be reordered to make two semantically equal documents
byte-identical. Two documents that differ only in a defined order are different
canonical encodings.

---

## 9. Schema versioning

- Every fixture has an integer `schema` at its envelope level; each nested
  contract object that can evolve independently also has its own `schema`
  (for example `document.assets.schema`, `document.operations.schema`, and each
  operation's `schema`).
- R1 pins all of these to `1`.
- A reader that sees a higher schema version must fail with
  `UNSUPPORTED_VERSION`; it must not partially interpret the object.
- Adding a new optional field is allowed within schema `1`. Renaming or
  changing the meaning of a field requires a new schema integer.

---

## 10. Fixture envelope

Each fixture is a standalone JSON object. The top-level key names the kind:

| Kind | Envelope | File |
|---|---|---|
| Document | `{"schema": 1, "document": {...}}` | `canonical/document-*.json` |
| Render plan | `{"schema": 1, ...plan fields...}` | `canonical/render-plan-*.json` |
| Export configuration | `{"schema": 1, "exportPlan": {...}}` | `canonical/export-config.json` |
| Domain error | `{"schema": 1, "error": {...}}` | `canonical/error-*.json` |
| Progress / cancellation | `{"schema": 1, "progress": {...}}` | `canonical/progress-*.json` |

The render plan is not wrapped because it is the payload sent across the C ABI
as `render_plan_json`; the envelope `schema` travels with it.

---

## 11. What the runner actually verifies

`Tests/Conformance/conformance.py` verifies, for every fixture:

1. UTF-8 without BOM; NFC strings; no duplicate keys; finite numbers only; no
   exponent notation; no negative zero.
2. Raw bytes equal the canonical pretty form plus one LF.
3. The SHA-256 of the compact form equals the value pinned in `index.json`.
4. The schema integers are `1`.
5. Kind-specific field, identifier, reference, and ordering rules.
6. Render plans reference operations and assets that exist in the linked
   document fixture, and cover the 17 stages exactly once in order.
7. Expected-invalid fixtures fail with the pinned domain code.
8. The golden corpus manifest, baselines, reference images, and export files
   still match their pinned hashes.

It does not verify pixel output, color correctness, image decoding, AI output,
or platform behavior. Those remain the job of the existing corpus harness and
the future engine.

---

## 12. Changing this contract

Any change to canonical bytes, ordering, identifier shapes, or schema integers
must:

1. update the specification and the fixtures together,
2. regenerate `index.json` hashes,
3. explain in the R1 or successor document why the old bytes were wrong or
   insufficient, and
4. not be used to silently bless a current bug. Label each fixture as current
   behavior or target contract.

The golden corpus is read-only for R1. Regenerating its baselines is a separate
change with its own review.
