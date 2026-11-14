#!/bin/bash
# ساخت اپ و بسته‌بندی آن به صورت یک فایل .app قابل اجرا روی مک
#
# چرا swiftc و نه swift build؟
#   روی این سیستم فقط Command Line Tools نصب است (بدون Xcode). موتور جدید
#   SwiftPM روی این نسخه از کار می‌افتد و ضمناً SDK پیش‌فرض (MacOSX.sdk → 27.0)
#   پلاگین SwiftUIMacros را همراه ندارد و هر @State خطا می‌دهد. پس مستقیماً با
#   swiftc کامپایل می‌کنیم و SDK سازگار را خودمان پیدا می‌کنیم.
set -euo pipefail
cd "$(dirname "$0")"

CONFIG="${1:-release}"
APP_NAME="Retouch Studio"
APP_BUNDLE="$APP_NAME.app"
BINARY_NAME="RetouchStudio"
OUT_DIR="build/bin"

# One universal bundle serves both Apple silicon and Intel. The AI helper is an
# Apple-silicon runtime, so AIWorker disables it on the Intel slice.
case "${RETOUCH_ARCH:-universal}" in
  arm64) ARCHS=(arm64) ;;
  x86_64|intel) ARCHS=(x86_64) ;;
  universal) ARCHS=(arm64 x86_64) ;;
  *)
    echo "✗ RETOUCH_ARCH باید arm64، x86_64 یا universal باشد." >&2
    exit 1
    ;;
esac

case "${ARCHS[*]}" in
  "arm64 x86_64"|"x86_64 arm64") BUNDLE_ARCH=universal ;;
  arm64) BUNDLE_ARCH=arm64 ;;
  x86_64) BUNDLE_ARCH=x86_64 ;;
  *) BUNDLE_ARCH="" ;;
esac

# --- پیدا کردن SDK سازگار (آنی که ماکروهای SwiftUI را دارد) ---
SDK=""
for candidate in $(ls -d /Library/Developer/CommandLineTools/SDKs/MacOSX*.sdk 2>/dev/null | sort -Vr); do
  probe=$(mktemp -d)
  printf 'import SwiftUI\nstruct P: View { @State var v = 1; var body: some View { Text("\\(v)") } }\n' > "$probe/p.swift"
  if swiftc -typecheck -target "${ARCHS[0]}-apple-macosx14.0" -sdk "$candidate" "$probe/p.swift" >/dev/null 2>&1; then
    SDK="$candidate"
    rm -rf "$probe"
    break
  fi
  rm -rf "$probe"
done

if [ -z "$SDK" ]; then
  echo "✗ هیچ SDK سازگاری با SwiftUI پیدا نشد." >&2
  echo "  راه‌حل: Xcode را نصب کن و xcode-select --switch /Applications/Xcode.app را اجرا کن." >&2
  exit 1
fi

# An ASCII comma after $CONFIG: bash reads a multibyte character glued to a
# name as part of the name, and `set -u` then fails on `CONFIG<byte>`.
echo "→ کامپایل پروژه ($CONFIG, ${ARCHS[*]}) با SDK: $(basename "$SDK")"
mkdir -p "$OUT_DIR"

FLAGS=(-sdk "$SDK")
if [ "$CONFIG" = "release" ]; then
  FLAGS+=(-O -whole-module-optimization)
else
  FLAGS+=(-Onone -g)
fi
SOURCES=$(find Sources/RetouchStudio -name '*.swift')

for ARCH in "${ARCHS[@]}"; do
  # StudioCore is a separate Foundation-only module; the app consumes it
  # through its module interface and links the static library. Build one
  # module per architecture because a .swiftmodule is architecture-specific.
  CORE_DIR="build/studiocore/$ARCH"
  ./Tests/build-studiocore.sh "$ARCH" "$SDK" "$CORE_DIR"
  # shellcheck disable=SC2046,SC2086
  swiftc "${FLAGS[@]}" -target "${ARCH}-apple-macosx14.0" \
    -I "$CORE_DIR" \
    -o "$OUT_DIR/$BINARY_NAME-$ARCH" $SOURCES "$CORE_DIR/libStudioCore.a" \
    -framework SwiftUI -framework AppKit -framework CoreImage \
    -framework Vision -framework UniformTypeIdentifiers
done

if [ ${#ARCHS[@]} -eq 1 ]; then
  mv "$OUT_DIR/$BINARY_NAME-${ARCHS[0]}" "$OUT_DIR/$BINARY_NAME"
else
  lipo -create -output "$OUT_DIR/$BINARY_NAME" \
    "$OUT_DIR/$BINARY_NAME-arm64" "$OUT_DIR/$BINARY_NAME-x86_64"
fi

echo "→ ساخت بسته‌ی اپ…"
# The helper runtime is ~1.6 GB. Keep it out of the delete/rebuild cycle; the
# bundler's stamp decides whether anything actually has to be copied again.
WORKER_CACHE="build/Worker.cache"
mkdir -p build
if [ -d "$APP_BUNDLE/Contents/Resources/Worker" ]; then
  rm -rf "$WORKER_CACHE"
  mv "$APP_BUNDLE/Contents/Resources/Worker" "$WORKER_CACHE"
fi
rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS" "$APP_BUNDLE/Contents/Resources"
if [ -d "$WORKER_CACHE" ]; then
  mv "$WORKER_CACHE" "$APP_BUNDLE/Contents/Resources/Worker"
fi
cp "$OUT_DIR/$BINARY_NAME" "$APP_BUNDLE/Contents/MacOS/$BINARY_NAME"
cp Resources/Info.plist "$APP_BUNDLE/Contents/Info.plist"

# Optional release stamping, so a public build does not have to edit a source
# file: RETOUCH_VERSION=1.0.0 RETOUCH_BUILD=1 ./build.sh
PLIST="$APP_BUNDLE/Contents/Info.plist"
if [ -n "${RETOUCH_VERSION:-}" ]; then
  /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $RETOUCH_VERSION" "$PLIST"
fi
if [ -n "${RETOUCH_BUILD:-}" ]; then
  /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $RETOUCH_BUILD" "$PLIST"
fi
APP_VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$PLIST")
APP_BUILD=$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$PLIST")

printf 'APPL????' > "$APP_BUNDLE/Contents/PkgInfo"

# App icon. Regenerate with Resources/make-icon.sh if the design changes.
if [ -f Resources/AppIcon.icns ]; then
  cp Resources/AppIcon.icns "$APP_BUNDLE/Contents/Resources/AppIcon.icns"
else
  echo "  ! warning: Resources/AppIcon.icns missing; building without an icon."
fi

# Vazir, the typeface the whole interface is set in. macOS registers the folder
# named by ATSApplicationFontsPath in Info.plist; UIAppFonts is ignored here.
if [ -d Resources/Fonts ]; then
  mkdir -p "$APP_BUNDLE/Contents/Resources/Fonts"
  cp Resources/Fonts/*.ttf "$APP_BUNDLE/Contents/Resources/Fonts/"
  # The SIL Open Font License travels with the fonts it covers.
  [ -f Resources/Fonts/OFL.txt ] && cp Resources/Fonts/OFL.txt "$APP_BUNDLE/Contents/Resources/Fonts/"
else
  echo "  ! warning: Resources/Fonts missing; Persian text will fall back to the system font."
fi

# Python interpreter, wheels and the worker package, so the app does not depend
# on this checkout or on Homebrew. Model weights stay out: they are downloaded
# by explicit consent. A checkout without the private worker still builds; the
# AI tools then report that the helper is not installed.
WORKER_ROOT="${RETOUCH_WORKER_ROOT:-}"
if [ -z "$WORKER_ROOT" ]; then
  if [ -d "$PWD/worker/retouch_ai_worker" ]; then
    WORKER_ROOT="$PWD/worker"
  else
    WORKER_ROOT="$HOME/RetouchStudio-Phase0/worker"
  fi
fi
WORKER_VENV="${RETOUCH_WORKER_VENV:-}"
if [ -z "$WORKER_VENV" ]; then
  if [ -x "$PWD/.venv/bin/python3" ]; then
    WORKER_VENV="$PWD/.venv"
  else
    WORKER_VENV="$HOME/RetouchStudio-Phase0/.venv"
  fi
fi
if [ "${RETOUCH_SKIP_WORKER:-}" = "1" ]; then
  # Park a cached runtime instead of shipping it, so a later build can reuse it.
  if [ -d "$APP_BUNDLE/Contents/Resources/Worker" ]; then
    rm -rf "$WORKER_CACHE"
    mv "$APP_BUNDLE/Contents/Resources/Worker" "$WORKER_CACHE"
  fi
  echo "  · helper runtime skipped (RETOUCH_SKIP_WORKER=1)"
elif [ -d "$WORKER_ROOT/retouch_ai_worker" ] && [ -x "$WORKER_VENV/bin/python3" ]; then
  RETOUCH_WORKER_ROOT="$WORKER_ROOT" RETOUCH_WORKER_VENV="$WORKER_VENV" \
    Tools/bundle-worker.sh "$APP_BUNDLE" ${RETOUCH_REBUNDLE:+--force}
else
  echo "  ! helper runtime not bundled — AI tools will be unavailable."
  echo "    Set RETOUCH_WORKER_ROOT and RETOUCH_WORKER_VENV, or RETOUCH_SKIP_WORKER=1 to silence this."
fi

# --- امضا ---
# ad-hoc فقط برای اجرای محلی است. انتشار عمومی به Developer ID، Hardened
# Runtime و notarization نیاز دارد؛ RETOUCH_SIGN_IDENTITY آن مسیر را باز می‌کند.
SIGN_IDENTITY="${RETOUCH_SIGN_IDENTITY:-}"
ENTITLEMENTS="${RETOUCH_ENTITLEMENTS:-Resources/RetouchStudio.entitlements}"
if [ -n "$SIGN_IDENTITY" ]; then
  SIGN_ARGS=(--force --timestamp --options runtime)
  [ -f "$ENTITLEMENTS" ] && SIGN_ARGS+=(--entitlements "$ENTITLEMENTS")
  SIGN_TARGET="$SIGN_IDENTITY"
  echo "→ امضای بسته با Developer ID + Hardened Runtime"
else
  SIGN_ARGS=(--force)
  SIGN_TARGET="-"
  echo "  ! امضای ad-hoc — فقط برای اجرای محلی؛ امضای انتشار عمومی نیست."
  echo "    برای انتشار: RETOUCH_SIGN_IDENTITY=\"Developer ID Application: …\" ./build.sh"
fi

# Nested Mach-O code (the bundled Python interpreter and its libraries) must be
# signed before the outer bundle, or hardened runtime rejects it at launch.
if [ -d "$APP_BUNDLE/Contents/Resources/Worker" ]; then
  nested=0
  while IFS= read -r -d '' candidate; do
    if file -b "$candidate" 2>/dev/null | grep -q "Mach-O"; then
      codesign "${SIGN_ARGS[@]}" --sign "$SIGN_TARGET" "$candidate"
      nested=$((nested + 1))
    fi
  done < <(find "$APP_BUNDLE/Contents/Resources/Worker" -type f \
             \( -name '*.so' -o -name '*.dylib' -o -perm -111 \) -print0 2>/dev/null || true)
  echo "  · nested Mach-O signed: $nested"
fi
codesign "${SIGN_ARGS[@]}" --sign "$SIGN_TARGET" "$APP_BUNDLE"
codesign --verify --deep --strict "$APP_BUNDLE"

echo "→ بررسی بسته…"
./Tools/validate-bundle.sh "$APP_BUNDLE" "$BUNDLE_ARCH" || exit 1

echo "→ بررسی سلامت موتور پردازش…"
mkdir -p build/selftest
BUNDLED_BINARY="$APP_BUNDLE/Contents/MacOS/$BINARY_NAME"
if "$BUNDLED_BINARY" --selftest --out build/selftest > build/selftest/selftest.log 2>&1; then
  echo "  ✓ خودآزمون پردازش پاس شد"
else
  echo "✗ خودآزمون پردازش خطا داد — بیلد متوقف شد." >&2
  echo "  جزئیات: build/selftest/selftest.log" >&2
  tail -n 30 build/selftest/selftest.log >&2 || true
  exit 1
fi

# A universal build is only useful on Intel if the Intel slice passes the same
# self-test. Rosetta can execute that slice here; a real Intel Mac runs it
# natively, so this is a CPU check, not a GPU benchmark.
if [ ${#ARCHS[@]} -gt 1 ] && [ "$(uname -m)" = "arm64" ] \
   && arch -x86_64 /usr/bin/true >/dev/null 2>&1; then
  mkdir -p build/selftest-intel
  if arch -x86_64 "$BUNDLED_BINARY" --selftest --out build/selftest-intel \
       > build/selftest-intel/selftest.log 2>&1; then
    echo "  ✓ خودآزمون پردازش روی بخش Intel هم پاس شد"
  else
    echo "✗ خودآزمون بخش Intel خطا داد — بیلد متوقف شد." >&2
    echo "  جزئیات: build/selftest-intel/selftest.log" >&2
    tail -n 30 build/selftest-intel/selftest.log >&2 || true
    exit 1
  fi
fi

echo "✓ آماده است: $(pwd)/$APP_BUNDLE  —  نسخهٔ $APP_VERSION ($APP_BUILD)"
echo "  اجرا:  open \"$(pwd)/$APP_BUNDLE\""
