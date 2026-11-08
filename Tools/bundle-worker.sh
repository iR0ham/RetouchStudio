#!/bin/bash
# Assembles a relocatable Python runtime and the local AI helper inside the app.
#
# The helper is a Python package. Shipping it means shipping an interpreter and
# its wheels too, since the owner's Mac may have neither Homebrew nor a venv.
# The interpreter is the Homebrew framework this checkout was built against;
# its only absolute references are the two binaries rewritten below. Everything
# in site-packages already uses @rpath or @loader_path.
#
# Usage: bundle-worker.sh <app bundle> [--force]
set -euo pipefail

APP="${1:?usage: bundle-worker.sh <app bundle> [--force]}"
FORCE="${2:-}"
WORKER_ROOT="${RETOUCH_WORKER_ROOT:-$HOME/RetouchStudio-Phase0/worker}"
VENV="${RETOUCH_WORKER_VENV:-$HOME/RetouchStudio-Phase0/.venv}"
DEST="$APP/Contents/Resources/Worker"

[ -d "$WORKER_ROOT/retouch_ai_worker" ] || { echo "worker source not found: $WORKER_ROOT" >&2; exit 1; }
[ -x "$VENV/bin/python3" ] || { echo "venv not found: $VENV" >&2; exit 1; }

BASE_PREFIX="$("$VENV/bin/python3" -c 'import sys; print(sys.base_prefix)')"
FRAMEWORK="$(cd "$BASE_PREFIX/../.." && pwd)"   # .../Python.framework
VERSION="$(basename "$BASE_PREFIX")"            # 3.13
STAMP_CONTENT="$("$VENV/bin/python3" -c 'import sys; print(sys.version.split()[0])')"
SOURCE_HASH="$(cd "$WORKER_ROOT" && find retouch_ai_worker -name '*.py' -type f -print0 \
    | xargs -0 shasum -a 256 | shasum -a 256 | awk '{print $1}')"
PACKAGES_HASH="$("$VENV/bin/python3" -m pip freeze 2>/dev/null | shasum -a 256 | awk '{print $1}')"
STAMP_CONTENT="$(printf '%s\n%s\n%s\n' "$STAMP_CONTENT" "$SOURCE_HASH" "$PACKAGES_HASH" \
    | shasum -a 256 | awk '{print $1}')"

if [ -f "$DEST/.stamp" ] && [ "$(cat "$DEST/.stamp")" = "$STAMP_CONTENT" ] && [ "$FORCE" != "--force" ]; then
  # A previous launch may have cached bytecode inside the runtime. Those files
  # are not in the original seal, and leaving them here would break the next
  # build's signature, so drop them even when nothing else changes.
  if [ -d "$DEST" ]; then
    find "$DEST" -name '__pycache__' -type d -prune -exec rm -rf {} + 2>/dev/null || true
    find "$DEST" -name '*.pyc' -delete 2>/dev/null || true
  fi
  echo "  · helper runtime unchanged"
  exit 0
fi

echo "  · bundling helper runtime ($VERSION)"
rm -rf "$DEST"
mkdir -p "$DEST/bin" "$DEST/site-packages"

cp -R "$FRAMEWORK" "$DEST/Python.framework"
# Homebrew's bin/python3 is a stub that re-executes the framework app, so the
# app wrapper has to stay even though the helper never shows a window.
ln -s "../Python.framework/Versions/$VERSION/bin/python3.13" "$DEST/bin/python3"

# The framework's stdlib site-packages points six levels up at the Cellar, which
# does not travel with us. Aim it at the packages copied below instead: a
# dangling link inside the bundle makes its signature unverifiable.
STDLIB_SITE="$DEST/Python.framework/Versions/$VERSION/lib/python$VERSION/site-packages"
if [ -L "$STDLIB_SITE" ]; then
  rm "$STDLIB_SITE"
  ln -s "../../../../../site-packages" "$STDLIB_SITE"
fi

rsync -a --exclude '__pycache__' --exclude '*.pyc' \
  "$WORKER_ROOT/retouch_ai_worker" "$DEST/"
rsync -a --exclude '__pycache__' --exclude '*.pyc' \
  "$VENV/lib/python$VERSION/site-packages/" "$DEST/site-packages/"

PYBIN="$DEST/Python.framework/Versions/$VERSION/bin/python3.13"
LIBPY="$DEST/Python.framework/Versions/$VERSION/Python"
# The recorded dependency is the Homebrew Cellar path even though base_prefix
# reports the /opt/homebrew/opt symlink, so rewrite whatever is actually there.
OLD_LIBPY="$(otool -L "$PYBIN" | awk 'NR > 1 && /\/Python \(compat/ { print $1; exit }')"
[ -n "$OLD_LIBPY" ] || { echo "could not read the interpreter's libpython path" >&2; exit 1; }
install_name_tool -change "$OLD_LIBPY" "@loader_path/../Python" "$PYBIN"
install_name_tool -id "@loader_path/Python" "$LIBPY"
APPBIN="$DEST/Python.framework/Versions/$VERSION/Resources/Python.app/Contents/MacOS/Python"
OLD_APP_LIBPY="$(otool -L "$APPBIN" | awk 'NR > 1 && /\/Python \(compat/ { print $1; exit }')"
if [ -n "$OLD_APP_LIBPY" ]; then
  install_name_tool -change "$OLD_APP_LIBPY" "@loader_path/../../../../Python" "$APPBIN"
fi
if otool -L "$PYBIN" | grep -q '/opt/homebrew'; then
  echo "interpreter still refers to Homebrew after rewriting" >&2
  exit 1
fi

# The stdlib extensions linked to Homebrew dylibs need the same treatment.
/usr/bin/python3 "$(dirname "$0")/relink.py" "$DEST"
if find "$DEST" -type f \( -name '*.so' -o -name '*.dylib' -o -perm -111 \) -print0 \
    | while IFS= read -r -d '' file; do
        file "$file" | grep -q Mach-O || continue
        otool -L "$file" 2>/dev/null | sed -n '2,$p' | grep -q '/opt/homebrew' && echo "$file"
      done | grep -q .; then
  echo "the runtime still refers to Homebrew" >&2
  exit 1
fi

# codesign cannot seal a bundle that holds a dangling symlink, and the failure
# it reports ("No such file or directory") does not name the offender, so check
# here while the reason is still obvious.
BROKEN="$(find "$DEST" -type l ! -exec test -e {} \; -print)"
if [ -n "$BROKEN" ]; then
  echo "the runtime contains broken symlinks:" >&2
  echo "$BROKEN" >&2
  exit 1
fi

# Ad-hoc signatures on every Mach-O, innermost first. The outer app signature is
# added by build.sh after this script returns.
find "$DEST" -type f \( -name '*.so' -o -name '*.dylib' -o -perm -111 \) -print0 \
  | while IFS= read -r -d '' file; do
      if file "$file" | grep -q 'Mach-O'; then
        codesign --force --sign - "$file" >/dev/null 2>&1 || {
          echo "failed to sign $file" >&2; exit 1; }
      fi
    done
codesign --force --sign - "$PYBIN" >/dev/null
codesign --force --sign - "$LIBPY" >/dev/null

printf '%s' "$STAMP_CONTENT" > "$DEST/.stamp"
echo "  · helper runtime ready ($(du -sh "$DEST" | awk '{print $1}'))"
