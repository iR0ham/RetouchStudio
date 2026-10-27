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

# --- پیدا کردن SDK سازگار (آنی که ماکروهای SwiftUI را دارد) ---
SDK=""
for candidate in $(ls -d /Library/Developer/CommandLineTools/SDKs/MacOSX*.sdk 2>/dev/null | sort -Vr); do
  probe=$(mktemp -d)
  printf 'import SwiftUI\nstruct P: View { @State var v = 1; var body: some View { Text("\\(v)") } }\n' > "$probe/p.swift"
  if swiftc -typecheck -target arm64-apple-macosx14.0 -sdk "$candidate" "$probe/p.swift" >/dev/null 2>&1; then
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

echo "→ کامپایل پروژه ($CONFIG) با SDK: $(basename "$SDK")"
mkdir -p "$OUT_DIR"

FLAGS=(-target arm64-apple-macosx14.0 -sdk "$SDK" -o "$OUT_DIR/$BINARY_NAME")
if [ "$CONFIG" = "release" ]; then
  FLAGS+=(-O -whole-module-optimization)
else
  FLAGS+=(-Onone -g)
fi

# shellcheck disable=SC2046
swiftc "${FLAGS[@]}" $(find Sources -name '*.swift') \
  -framework SwiftUI -framework AppKit -framework CoreImage \
  -framework Vision -framework UniformTypeIdentifiers

echo "→ ساخت بسته‌ی اپ…"
rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS" "$APP_BUNDLE/Contents/Resources"
cp "$OUT_DIR/$BINARY_NAME" "$APP_BUNDLE/Contents/MacOS/$BINARY_NAME"
cp Resources/Info.plist "$APP_BUNDLE/Contents/Info.plist"
printf 'APPL????' > "$APP_BUNDLE/Contents/PkgInfo"

# App icon. Regenerate with Resources/make-icon.sh if the design changes.
if [ -f Resources/AppIcon.icns ]; then
  cp Resources/AppIcon.icns "$APP_BUNDLE/Contents/Resources/AppIcon.icns"
else
  echo "  ! warning: Resources/AppIcon.icns missing; building without an icon."
fi

# امضای ad-hoc تا مک بدون هشدار بازش کند
codesign --force --sign - "$APP_BUNDLE" >/dev/null 2>&1 || echo "  (بدون امضا ادامه می‌دهیم)"

echo "→ بررسی سلامت موتور پردازش…"
"$OUT_DIR/$BINARY_NAME" --selftest --out build/selftest >/dev/null 2>&1 \
  && echo "  ✓ خودآزمون پردازش پاس شد" \
  || echo "  ! خودآزمون پردازش خطا داد (اجرا کن: ./build/bin/$BINARY_NAME --selftest)"

echo "✓ آماده است: $(pwd)/$APP_BUNDLE"
echo "  اجرا:  open \"$(pwd)/$APP_BUNDLE\""
