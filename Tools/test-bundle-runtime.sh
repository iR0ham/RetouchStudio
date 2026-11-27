#!/bin/bash
# Regression fixtures for the helper-runtime contract in validate-bundle.sh.
#
#   Tools/test-bundle-runtime.sh
#
# The fixtures are real signed bundle-shaped directories with a tiny Mach-O
# executable. They exercise policy and integrity checks without building Python
# or downloading a model.
set -euo pipefail
cd "$(dirname "$0")/.."

VALIDATE="$PWD/Tools/validate-bundle.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
failures=0

fail() { echo "  ✗ $*" >&2; failures=$((failures + 1)); }
pass() { echo "  ✓ $*"; }

cat > "$WORK/main.c" <<'EOF'
int main(void) { return 0; }
EOF
clang -arch "$(uname -m)" "$WORK/main.c" -o "$WORK/RetouchStudio"
# The helper contract is Apple-silicon-only even when the host runner is Intel.
clang -arch arm64 "$WORK/main.c" -o "$WORK/RetouchStudio-arm64"
clang -arch x86_64 "$WORK/main.c" -o "$WORK/RetouchStudio-x86_64"

make_bundle() {
  local root="$1"
  mkdir -p "$root/Contents/MacOS" "$root/Contents/Resources/Fonts"
  cp "$WORK/RetouchStudio" "$root/Contents/MacOS/RetouchStudio"
  cp Resources/Info.plist "$root/Contents/Info.plist"
  cp Resources/THIRD_PARTY_NOTICES.txt "$root/Contents/Resources/THIRD_PARTY_NOTICES.txt"
  cp LICENSE "$root/Contents/Resources/LICENSE"
  cp Resources/Fonts/OFL.txt Resources/Fonts/Vazirmatn-Regular.ttf \
     Resources/Fonts/Vazirmatn-Medium.ttf Resources/Fonts/Vazirmatn-SemiBold.ttf \
     Resources/Fonts/Vazirmatn-Bold.ttf "$root/Contents/Resources/Fonts/"
  mkdir -p "$root/Contents/Resources/Tests/Fixtures"
  cp -R Tests/Fixtures/upscale-m3 "$root/Contents/Resources/Tests/Fixtures/"
  cp Resources/model-catalog.json "$root/Contents/Resources/model-catalog.json"
}

add_unsealed_worker() {
  local root="$1" worker
  worker="$root/Contents/Resources/Worker"
  mkdir -p "$worker/bin" "$worker/retouch_ai_worker" \
           "$worker/Python.framework/Versions/3.13/bin"
  cp "$WORK/RetouchStudio-arm64" "$worker/Python.framework/Versions/3.13/bin/python3.13"
  ln -s "../Python.framework/Versions/3.13/bin/python3.13" "$worker/bin/python3"
  printf '# worker\n' > "$worker/retouch_ai_worker/__init__.py"
  cp worker/LICENSE "$worker/LICENSE"
  cp worker/THIRD_PARTY_NOTICES.md "$worker/THIRD_PARTY_NOTICES.md"
  cp worker/requirements.lock "$worker/requirements.lock"
  printf '%064d' 0 > "$worker/.stamp"
}

sign_bundle() {
  local root="$1" worker
  worker="$root/Contents/Resources/Worker"
  if [ -d "$worker" ]; then
    codesign --force --sign - "$worker/Python.framework/Versions/3.13/bin/python3.13" \
      >/dev/null 2>&1
  fi
  codesign --force --sign - "$root" >/dev/null 2>&1
}

record_symlink() {
  local manifest="$1" name="$2" target="$3"
  /usr/bin/python3 - "$manifest" "$name" "$target" <<'PY'
import json
import sys

path, name, target = sys.argv[1:]
with open(path, encoding="utf-8") as handle:
    payload = json.load(handle)
payload["entries"].append({"path": name, "kind": "symlink", "target": target})
payload["entries"].sort(key=lambda entry: entry["path"])
with open(path, "w", encoding="utf-8") as handle:
    json.dump(payload, handle, ensure_ascii=True, indent=2, sort_keys=True)
    handle.write("\n")
PY
}

expect_pass() {
  local name="$1" root="$2" expected="$3" mode="$4"
  if "$VALIDATE" "$root" "$expected" "$mode" > "$WORK/out.log" 2>&1; then
    pass "$name"
  else
    fail "$name: expected PASS"
    sed 's/^/      /' "$WORK/out.log" >&2
  fi
}

expect_fail() {
  local name="$1" root="$2" expected="$3" mode="$4" needle="$5"
  if "$VALIDATE" "$root" "$expected" "$mode" > "$WORK/out.log" 2>&1; then
    fail "$name: expected FAIL"
  elif grep -Fq "$needle" "$WORK/out.log"; then
    pass "$name"
  else
    fail "$name: failed without saying '$needle'"
    sed 's/^/      /' "$WORK/out.log" >&2
  fi
}

HOST_ARCH="$(uname -m)"
LIGHT="$WORK/light.app"
make_bundle "$LIGHT"
sign_bundle "$LIGHT"
expect_fail "an arm64 helper-bearing build refuses a missing Worker" \
  "$LIGHT" "$HOST_ARCH" "--require-worker" \
  "helper runtime is required but Contents/Resources/Worker is missing"

UNSIGNED="$WORK/unsigned.app"
make_bundle "$UNSIGNED"
# clang on Apple silicon ad-hoc signs its output by default; remove that
# compiler signature so this fixture is genuinely unsigned.
codesign --remove-signature "$UNSIGNED/Contents/MacOS/RetouchStudio" >/dev/null 2>&1
expect_fail "an unsigned app is refused even when its fixture bytes are valid" \
  "$UNSIGNED" "$HOST_ARCH" "--forbid-worker" \
  "no recognizable code signature"

INVALID_OUTER="$WORK/invalid-outer.app"
cp -R "$LIGHT" "$INVALID_OUTER"
printf '\0' >> "$INVALID_OUTER/Contents/MacOS/RetouchStudio"
expect_fail "an invalid outer signature is refused" \
  "$INVALID_OUTER" "$HOST_ARCH" "--forbid-worker" \
  "codesign --verify --deep --strict failed"

UNSEALED="$WORK/unsealed.app"
make_bundle "$UNSEALED"
add_unsealed_worker "$UNSEALED"
sign_bundle "$UNSEALED"
expect_fail "a helper tree without an integrity manifest is refused" \
  "$UNSEALED" "$HOST_ARCH" "--require-worker" \
  "worker integrity manifest is missing"

expect_fail "a helper-free build refuses an unexpected Worker" \
  "$UNSEALED" "$HOST_ARCH" "--forbid-worker" \
  "helper runtime is forbidden in this build"
expect_pass "a helper-free build with an explicit policy passes" \
  "$LIGHT" "$HOST_ARCH" "--forbid-worker"

DANGLING_WORKER="$WORK/dangling-worker.app"
cp -R "$LIGHT" "$DANGLING_WORKER"
ln -s "MissingWorker" "$DANGLING_WORKER/Contents/Resources/Worker"
sign_bundle "$DANGLING_WORKER"
expect_fail "a helper-free build refuses a dangling Worker symlink" \
  "$DANGLING_WORKER" "$HOST_ARCH" "--forbid-worker" \
  "helper runtime is forbidden in this build"

SEALED="$WORK/sealed.app"
cp -R "$UNSEALED" "$SEALED"
/usr/bin/python3 Tools/worker-integrity.py write \
  "$SEALED/Contents/Resources/Worker" > "$WORK/manifest.log"
sign_bundle "$SEALED"
expect_pass "a sealed arm64 helper bundle passes" \
  "$SEALED" "$HOST_ARCH" "--require-worker"

ROOT_LINK="$WORK/root-link.app"
EXTERNAL_WORKER="$WORK/external-worker"
cp -R "$LIGHT" "$ROOT_LINK"
cp -R "$SEALED/Contents/Resources/Worker" "$EXTERNAL_WORKER"
ln -s "$EXTERNAL_WORKER" "$ROOT_LINK/Contents/Resources/Worker"
sign_bundle "$ROOT_LINK"
expect_fail "a helper-bearing build refuses a symlinked Worker root" \
  "$ROOT_LINK" "$HOST_ARCH" "--require-worker" \
  "worker runtime root must not be a symbolic link"

ABSOLUTE_ESCAPE="$WORK/absolute-escape.app"
cp -R "$SEALED" "$ABSOLUTE_ESCAPE"
printf 'outside\n' > "$WORK/outside.txt"
ln -s "$WORK/outside.txt" \
  "$ABSOLUTE_ESCAPE/Contents/Resources/Worker/external-link"
record_symlink "$ABSOLUTE_ESCAPE/Contents/Resources/Worker/.integrity.json" \
  "external-link" "$WORK/outside.txt"
sign_bundle "$ABSOLUTE_ESCAPE"
expect_fail "an absolute helper symlink is refused" \
  "$ABSOLUTE_ESCAPE" "$HOST_ARCH" "--require-worker" \
  "worker symlink must be relative"

RELATIVE_ESCAPE="$WORK/relative-escape.app"
cp -R "$SEALED" "$RELATIVE_ESCAPE"
ln -s "../../../../outside.txt" \
  "$RELATIVE_ESCAPE/Contents/Resources/Worker/external-link"
record_symlink "$RELATIVE_ESCAPE/Contents/Resources/Worker/.integrity.json" \
  "external-link" "../../../../outside.txt"
sign_bundle "$RELATIVE_ESCAPE"
expect_fail "a relative helper symlink cannot escape the runtime" \
  "$RELATIVE_ESCAPE" "$HOST_ARCH" "--require-worker" \
  "worker symlink escapes the runtime root"

ABSOLUTE_INTERNAL="$WORK/absolute-internal.app"
cp -R "$SEALED" "$ABSOLUTE_INTERNAL"
internal_target="$ABSOLUTE_INTERNAL/Contents/Resources/Worker/retouch_ai_worker/__init__.py"
ln -s "$internal_target" \
  "$ABSOLUTE_INTERNAL/Contents/Resources/Worker/absolute-internal-link"
record_symlink "$ABSOLUTE_INTERNAL/Contents/Resources/Worker/.integrity.json" \
  "absolute-internal-link" "$internal_target"
sign_bundle "$ABSOLUTE_INTERNAL"
expect_fail "an absolute helper symlink is refused even when currently contained" \
  "$ABSOLUTE_INTERNAL" "$HOST_ARCH" "--require-worker" \
  "worker symlink must be relative"

INERT_TEXT="$WORK/inert-text.app"
cp -R "$SEALED" "$INERT_TEXT"
cat >> "$INERT_TEXT/Contents/Resources/Worker/retouch_ai_worker/__init__.py" <<'EOF'
# Upstream comments and optional completion paths may name /opt/homebrew or
# /usr/local/Cellar without placing either directory on Python's import path.
EOF
/usr/bin/python3 Tools/worker-integrity.py write \
  "$INERT_TEXT/Contents/Resources/Worker" > "$WORK/manifest.log"
sign_bundle "$INERT_TEXT"
expect_pass "inert Homebrew path text is not a runtime-path leak" \
  "$INERT_TEXT" "$HOST_ARCH" "--require-worker"

TAMPERED="$WORK/tampered.app"
cp -R "$SEALED" "$TAMPERED"
printf '\n# changed after sealing\n' >> \
  "$TAMPERED/Contents/Resources/Worker/retouch_ai_worker/__init__.py"
expect_fail "a post-seal worker edit is refused" \
  "$TAMPERED" "$HOST_ARCH" "--require-worker" \
  "worker integrity verification failed"

SIGNED_TAMPERED="$WORK/signed-tampered.app"
cp -R "$SEALED" "$SIGNED_TAMPERED"
printf '\n# changed before a valid outer re-sign\n' >> \
  "$SIGNED_TAMPERED/Contents/Resources/Worker/retouch_ai_worker/__init__.py"
sign_bundle "$SIGNED_TAMPERED"
expect_fail "a valid outer signature cannot hide a stale Worker integrity seal" \
  "$SIGNED_TAMPERED" "$HOST_ARCH" "--require-worker" \
  "worker integrity verification failed"

ADDED="$WORK/added.app"
cp -R "$SEALED" "$ADDED"
printf 'unsealed\n' > "$ADDED/Contents/Resources/Worker/retouch_ai_worker/extra.py"
expect_fail "a post-seal added file is refused" \
  "$ADDED" "$HOST_ARCH" "--require-worker" \
  "worker integrity verification failed"

RETARGETED="$WORK/retargeted.app"
cp -R "$SEALED" "$RETARGETED"
rm "$RETARGETED/Contents/Resources/Worker/bin/python3"
ln -s "../Python.framework/Versions/3.13/bin/other-python" \
  "$RETARGETED/Contents/Resources/Worker/bin/python3"
expect_fail "a post-seal interpreter retarget is refused" \
  "$RETARGETED" "$HOST_ARCH" "--require-worker" \
  "worker integrity verification failed"

MALFORMED="$WORK/malformed.app"
cp -R "$SEALED" "$MALFORMED"
/usr/bin/python3 - "$MALFORMED/Contents/Resources/Worker/.integrity.json" <<'PY'
import json
import sys

path = sys.argv[1]
with open(path, encoding="utf-8") as handle:
    payload = json.load(handle)
payload["entries"][0]["path"] = []
with open(path, "w", encoding="utf-8") as handle:
    json.dump(payload, handle)
PY
sign_bundle "$MALFORMED"
expect_fail "a malformed manifest fails cleanly without a traceback" \
  "$MALFORMED" "$HOST_ARCH" "--require-worker" \
  "worker integrity manifest has a malformed entry"

DUPLICATED="$WORK/duplicated.app"
cp -R "$SEALED" "$DUPLICATED"
/usr/bin/python3 - "$DUPLICATED/Contents/Resources/Worker/.integrity.json" <<'PY'
import json
import sys

path = sys.argv[1]
with open(path, encoding="utf-8") as handle:
    payload = json.load(handle)
payload["entries"].append(dict(payload["entries"][0]))
with open(path, "w", encoding="utf-8") as handle:
    json.dump(payload, handle)
PY
sign_bundle "$DUPLICATED"
expect_fail "a duplicate manifest path is refused" \
  "$DUPLICATED" "$HOST_ARCH" "--require-worker" \
  "worker integrity manifest has a malformed entry"

WRONG_ARCH="$WORK/wrong-arch.app"
cp -R "$UNSEALED" "$WRONG_ARCH"
cp "$WORK/RetouchStudio-x86_64" \
  "$WRONG_ARCH/Contents/Resources/Worker/Python.framework/Versions/3.13/bin/python3.13"
/usr/bin/python3 Tools/worker-integrity.py write \
  "$WRONG_ARCH/Contents/Resources/Worker" > "$WORK/manifest.log"
sign_bundle "$WRONG_ARCH"
expect_fail "an x86_64 helper cannot pass an arm64 bundle gate" \
  "$WRONG_ARCH" "$HOST_ARCH" "--require-worker" \
  "the Apple-silicon helper interpreter must be arm64, found: x86_64"

# The unchanged-cache path must verify the existing seal, never manufacture a
# new seal around bytes that may have changed since the previous build. A tiny
# fake venv supplies only the interpreter identity; the cache and manifest logic
# under test is the real bundle-worker.sh.
CACHE_ROOT="$WORK/cache"
CACHE_SOURCE="$CACHE_ROOT/source"
CACHE_VENV="$CACHE_ROOT/venv"
CACHE_BASE="$CACHE_ROOT/runtime/Python.framework/Versions/3.13"
mkdir -p "$CACHE_SOURCE/retouch_ai_worker" "$CACHE_VENV/bin" "$CACHE_BASE"
printf '# fixture worker\n' > "$CACHE_SOURCE/retouch_ai_worker/__init__.py"
: > "$CACHE_SOURCE/requirements.lock"
printf '%s\n' 'fixture source stamp' > "$CACHE_ROOT/.source-stamp"
cat > "$CACHE_VENV/bin/python3" <<'SH'
#!/bin/bash
if [ "${1:-}" = "-c" ]; then
  case "${2:-}" in
    *sys.base_prefix*) printf '%s\n' "$FAKE_BASE_PREFIX" ;;
    *sys.version.split*) printf '%s\n' '3.13.15' ;;
    *) exit 1 ;;
  esac
elif [ "${1:-}" = "-m" ] && [ "${2:-}" = "pip" ] && [ "${3:-}" = "freeze" ]; then
  printf '%s\n' 'fixture==1.0'
else
  exit 0
fi
SH
chmod +x "$CACHE_VENV/bin/python3"
export FAKE_BASE_PREFIX="$CACHE_BASE"
CACHE_SOURCE_HASH="$(cd "$CACHE_SOURCE" && { find retouch_ai_worker -type f \( -name '*.py' -o -name 'capability-evidence.json' \) -print0 | xargs -0 shasum -a 256; shasum -a 256 requirements.lock; } | shasum -a 256 | awk '{print $1}')"
CACHE_PACKAGES_HASH="$(printf '%s\n' 'fixture==1.0' | shasum -a 256 | awk '{print $1}')"
CACHE_RUNTIME_SOURCE_HASH="$(cat "$CACHE_ROOT/.source-stamp")"
CACHE_STAMP="$(printf '%s\n%s\n%s\n%s\n%s\n%s\n' \
  'retouchstudio.worker-bundle/v3' "$(uname -m)" '3.13.15' \
  "$CACHE_RUNTIME_SOURCE_HASH" "$CACHE_SOURCE_HASH" "$CACHE_PACKAGES_HASH" \
  | shasum -a 256 | awk '{print $1}')"

make_cache() {
  local app="$1" worker
  worker="$app/Contents/Resources/Worker"
  mkdir -p "$worker/retouch_ai_worker"
  printf 'sealed\n' > "$worker/retouch_ai_worker/__init__.py"
  printf '%s' "$CACHE_STAMP" > "$worker/.stamp"
  /usr/bin/python3 Tools/worker-integrity.py write "$worker" >/dev/null
}

expect_cache_failure() {
  local name="$1" app="$2" needle="$3"
  if RETOUCH_WORKER_ROOT="$CACHE_SOURCE" RETOUCH_WORKER_VENV="$CACHE_VENV" \
      ./Tools/bundle-worker.sh "$app" > "$WORK/cache.log" 2>&1; then
    fail "$name: expected FAIL"
  elif grep -Fq "$needle" "$WORK/cache.log"; then
    pass "$name"
  else
    fail "$name: failed without saying '$needle'"
    sed 's/^/      /' "$WORK/cache.log" >&2
  fi
}

expect_cache_pass() {
  local name="$1" app="$2"
  if RETOUCH_WORKER_ROOT="$CACHE_SOURCE" RETOUCH_WORKER_VENV="$CACHE_VENV" \
      ./Tools/bundle-worker.sh "$app" > "$WORK/cache.log" 2>&1; then
    pass "$name"
  else
    fail "$name: expected PASS"
    sed 's/^/      /' "$WORK/cache.log" >&2
  fi
}

BYTECODE_CACHE="$WORK/bytecode-cache.app"
make_cache "$BYTECODE_CACHE"
mkdir -p "$BYTECODE_CACHE/Contents/Resources/Worker/retouch_ai_worker/__pycache__"
printf 'launch residue\n' > \
  "$BYTECODE_CACHE/Contents/Resources/Worker/retouch_ai_worker/__pycache__/launch.cpython-313.pyc"
expect_cache_pass "an unchanged cache removes unsealed launch bytecode before verification" \
  "$BYTECODE_CACHE"
if find "$BYTECODE_CACHE/Contents/Resources/Worker" \
    \( -name '__pycache__' -o -name '*.pyc' \) -print | grep -q .; then
  fail "an unchanged cache leaves launch bytecode behind"
else
  pass "an unchanged cache is bytecode-free after reuse"
fi

TAMPERED_CACHE="$WORK/tampered-cache.app"
make_cache "$TAMPERED_CACHE"
printf 'changed\n' >> "$TAMPERED_CACHE/Contents/Resources/Worker/retouch_ai_worker/__init__.py"
expect_cache_failure "an unchanged cache refuses post-seal edits instead of re-sealing them" \
  "$TAMPERED_CACHE" "cached helper integrity verification failed"

UNSEALED_CACHE="$WORK/unsealed-cache.app"
make_cache "$UNSEALED_CACHE"
rm "$UNSEALED_CACHE/Contents/Resources/Worker/.integrity.json"
expect_cache_failure "an unchanged cache refuses a missing manifest instead of creating one" \
  "$UNSEALED_CACHE" "cached helper integrity verification failed"

if [ "$failures" -ne 0 ]; then
  echo "✗ bundle runtime fixtures: $failures problem(s)" >&2
  exit 1
fi
echo "✓ bundle runtime fixtures: all cases behaved as expected"
