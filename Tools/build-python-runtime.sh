#!/bin/bash
# Builds the macOS AI runtime's interpreter from pinned CPython source.
#
# The tarball is fetched from python.org and verified against the SHA-256 below.
# The framework is linked against Homebrew's OpenSSL, xz and SQLite because
# macOS does not ship their headers; Tools/bundle-worker.sh later rewrites every
# Homebrew reference and copies the libraries into the app, so the installed app
# never depends on Homebrew.
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION=3.13.15
PYVER="${VERSION%.*}"
SHA256=c28d9d213c09b5b5ab2c29812950e12f746999e099b82894231be954b26baed9
URL="https://www.python.org/ftp/python/$VERSION/Python-$VERSION.tgz"

ROOT="$PWD/build/python-runtime"
FRAMEWORK="$ROOT/install/Python.framework"
PYTHON="$FRAMEWORK/Versions/$PYVER/bin/python$PYVER"
STAMP="$ROOT/.source-stamp"

if [ -x "$PYTHON" ] && [ -f "$STAMP" ] && [ "$(cat "$STAMP")" = "$SHA256" ]; then
  echo "$PYTHON"
  exit 0
fi

[ "$(uname -m)" = "arm64" ] || {
  echo "the AI runtime is arm64-only; build it on Apple silicon" >&2
  exit 1
}
for formula in openssl@3 xz sqlite; do
  command -v brew >/dev/null 2>&1 || {
    echo "Homebrew is required to build CPython's optional modules" >&2
    exit 1
  }
  brew list --versions "$formula" >/dev/null 2>&1 || {
    echo "missing build dependency: brew install $formula" >&2
    exit 1
  }
done

CACHE="$PWD/build/python-cache"
mkdir -p "$CACHE" "$ROOT"
TARBALL="$CACHE/Python-$VERSION.tgz"
if [ ! -f "$TARBALL" ] || [ "$(shasum -a 256 "$TARBALL" | awk '{print $1}')" != "$SHA256" ]; then
  rm -f "$TARBALL"
  curl -fL --retry 3 --retry-delay 2 -o "$TARBALL" "$URL"
fi
ACTUAL="$(shasum -a 256 "$TARBALL" | awk '{print $1}')"
[ "$ACTUAL" = "$SHA256" ] || {
  echo "CPython source hash mismatch: $ACTUAL" >&2
  exit 1
}

OPENSSL="$(brew --prefix openssl@3)"
XZ="$(brew --prefix xz)"
SQLITE="$(brew --prefix sqlite)"
BUILD="$ROOT/src"
rm -rf "$BUILD"
mkdir -p "$BUILD"
tar -xzf "$TARBALL" -C "$BUILD" --strip-components=1

echo "  · building CPython $VERSION from source" >&2
cd "$BUILD"
CPPFLAGS="-I$OPENSSL/include -I$XZ/include -I$SQLITE/include" \
LDFLAGS="-L$OPENSSL/lib -L$XZ/lib -L$SQLITE/lib" \
./configure --prefix="$ROOT/install" --enable-framework="$ROOT/install" \
  --with-openssl="$OPENSSL" --with-ensurepip=install \
  MACOSX_DEPLOYMENT_TARGET=14.0 >"$ROOT/configure.log" 2>&1
make -j"$(sysctl -n hw.ncpu)" >"$ROOT/make.log" 2>&1
make install >"$ROOT/install.log" 2>&1
cd "$OLDPWD"

"$PYTHON" -c 'import ssl, sqlite3, lzma, zlib' || {
  echo "the source-built interpreter is missing a required stdlib module" >&2
  exit 1
}
printf '%s' "$SHA256" > "$STAMP"
echo "$PYTHON"
