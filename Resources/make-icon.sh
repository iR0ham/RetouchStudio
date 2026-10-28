#!/bin/bash
# بازسازی Resources/AppIcon.icns — نشانۀ «نور استودیو».
# کرۀ گرافیتی که مثل بیوتی‌دیش نور گرفته: کلید از بالا-چپ، ریم‌لایت سبز لیمویی
# روی لبۀ دور، و بازتاب سرد در سایه. رنگ‌ها از Theme.swift گرفته شده‌اند.
#
#   ./Resources/make-icon.sh
set -euo pipefail
cd "$(dirname "$0")/.."

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

cat > "$WORK/render.swift" <<'SWIFT'
import CoreGraphics
import Foundation
import ImageIO

let outPath = CommandLine.arguments[1]

let unit = 1024.0
let scale = 2.0
let space = CGColorSpace(name: CGColorSpace.sRGB)!

guard let ctx = CGContext(data: nil,
                          width: Int(unit * scale),
                          height: Int(unit * scale),
                          bitsPerComponent: 8,
                          bytesPerRow: 0,
                          space: space,
                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
    fatalError("cannot create bitmap context")
}
// Top-left origin so the layout reads like screen coordinates.
ctx.scaleBy(x: scale, y: scale)
ctx.translateBy(x: 0, y: unit)
ctx.scaleBy(x: 1, y: -1)

let art = 824.0
let margin = (unit - art) / 2

func c(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(colorSpace: space,
            components: [CGFloat((hex >> 16) & 0xFF) / 255,
                         CGFloat((hex >> 8) & 0xFF) / 255,
                         CGFloat(hex & 0xFF) / 255,
                         a])!
}

/// Fraction of the art box → canvas coordinate.
func f(_ v: CGFloat) -> CGFloat { margin + v * art }

func rr(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, _ r: CGFloat) -> CGPath {
    let path = CGMutablePath()
    let right = x + w, bottom = y + h
    path.move(to: CGPoint(x: x + r, y: y))
    path.addLine(to: CGPoint(x: right - r, y: y))
    path.addArc(tangent1End: CGPoint(x: right, y: y),
                tangent2End: CGPoint(x: right, y: y + r), radius: r)
    path.addLine(to: CGPoint(x: right, y: bottom - r))
    path.addArc(tangent1End: CGPoint(x: right, y: bottom),
                tangent2End: CGPoint(x: x + r, y: bottom), radius: r)
    path.addLine(to: CGPoint(x: x + r, y: bottom))
    path.addArc(tangent1End: CGPoint(x: x, y: bottom),
                tangent2End: CGPoint(x: x, y: bottom - r), radius: r)
    path.addLine(to: CGPoint(x: x, y: y + r))
    path.addArc(tangent1End: CGPoint(x: x, y: y),
                tangent2End: CGPoint(x: x + r, y: y), radius: r)
    path.closeSubpath()
    return path
}

func fill(_ path: CGPath, _ color: CGColor) {
    ctx.addPath(path)
    ctx.setFillColor(color)
    ctx.fillPath()
}

func vgrad(_ clip: CGPath, _ from: CGPoint, _ to: CGPoint, _ stops: [(CGFloat, CGColor)]) {
    ctx.saveGState()
    ctx.addPath(clip)
    ctx.clip()
    let gradient = CGGradient(colorsSpace: space,
                              colors: stops.map { $0.1 } as CFArray,
                              locations: stops.map { $0.0 })!
    ctx.drawLinearGradient(gradient, start: from, end: to,
                           options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    ctx.restoreGState()
}

func radial(_ center: CGPoint, _ radius: CGFloat, _ stops: [(CGFloat, CGColor)], _ clip: CGPath) {
    ctx.saveGState()
    ctx.addPath(clip)
    ctx.clip()
    let gradient = CGGradient(colorsSpace: space,
                              colors: stops.map { $0.1 } as CFArray,
                              locations: stops.map { $0.0 })!
    ctx.drawRadialGradient(gradient,
                           startCenter: center, startRadius: 0,
                           endCenter: center, endRadius: radius, options: [])
    ctx.restoreGState()
}

// MARK: Graphite plate

let plate = rr(margin, margin, art, art, art * 0.2245)

ctx.saveGState()
ctx.addPath(plate)
ctx.clip()
let body = CGGradient(colorsSpace: space,
                      colors: [c(0x424242), c(0x262626), c(0x111111)] as CFArray,
                      locations: [0, 0.4, 1])!
ctx.drawLinearGradient(body, start: CGPoint(x: margin, y: margin),
                       end: CGPoint(x: margin + art, y: margin + art),
                       options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
ctx.restoreGState()

radial(CGPoint(x: f(0.42), y: f(0.14)), art * 0.75,
       [(0, c(0xFFFFFF, 0.09)), (1, c(0xFFFFFF, 0))], plate)
vgrad(plate, CGPoint(x: 0, y: f(0.74)), CGPoint(x: 0, y: unit),
      [(0, c(0x000000, 0)), (1, c(0x000000, 0.24))])
ctx.addPath(rr(margin + 1.2, margin + 1.2, art - 2.4, art - 2.4, art * 0.2245 - 1.2))
ctx.setStrokeColor(c(0xF7F7F7, 0.13))
ctx.setLineWidth(1.6)
ctx.strokePath()

// MARK: The dish

let cx = f(0.5), cy = f(0.5), radius = art * 0.335
let box = CGRect(x: cx - radius, y: cy - radius, width: radius * 2, height: radius * 2)
let dish = CGPath(ellipseIn: box, transform: nil)

ctx.saveGState()
ctx.addPath(plate)
ctx.clip()
ctx.setShadow(offset: CGSize(width: 0, height: 32), blur: 56, color: c(0x000000, 0.62))
fill(dish, c(0x161616))
ctx.restoreGState()

// Key light from above, falling into the plate.
vgrad(dish, CGPoint(x: 0, y: cy - radius), CGPoint(x: 0, y: cy + radius),
      [(0, c(0x9E9E9E)), (0.40, c(0x474747)), (1, c(0x141414))])
radial(CGPoint(x: f(0.40), y: f(0.33)), art * 0.68,
       [(0, c(0xC4C4C4)), (0.42, c(0x4A4A4A, 0.5)), (1, c(0x000000, 0))], dish)
radial(CGPoint(x: f(0.395), y: f(0.325)), art * 0.10,
       [(0, c(0xFFFFFF, 0.95)), (0.5, c(0xFFFFFF, 0.25)), (1, c(0xFFFFFF, 0))], dish)

/// A lit crescent: the dish minus the same dish nudged toward the light.
func crescent(toward offset: CGSize, _ paint: (CGContext) -> Void) {
    let ring = CGMutablePath()
    ring.addPath(dish)
    ring.addPath(CGPath(ellipseIn: box.offsetBy(dx: offset.width, dy: offset.height),
                        transform: nil))
    ctx.saveGState()
    ctx.addPath(plate)
    ctx.clip()
    ctx.addPath(ring)
    ctx.clip(using: .evenOdd)
    paint(ctx)
    ctx.restoreGState()
}

// Chartreuse rim on the edge away from the key.
crescent(toward: CGSize(width: -40, height: -40)) { g in
    let rim = CGGradient(colorsSpace: space,
                         colors: [c(0xF5FFC4), c(0xDFF57A, 0.95), c(0xDFF57A, 0)] as CFArray,
                         locations: [0, 0.55, 1])!
    g.drawRadialGradient(rim,
                         startCenter: CGPoint(x: f(0.735), y: f(0.735)), startRadius: 0,
                         endCenter: CGPoint(x: f(0.735), y: f(0.735)),
                         endRadius: art * 0.36, options: [])
}

// Cool bounce back into the shadow side.
crescent(toward: CGSize(width: 32, height: 32)) { g in
    let bounce = CGGradient(colorsSpace: space,
                            colors: [c(0xFFFFFF, 0.16), c(0xFFFFFF, 0)] as CFArray,
                            locations: [0, 1])!
    g.drawRadialGradient(bounce,
                         startCenter: CGPoint(x: f(0.28), y: f(0.72)), startRadius: 0,
                         endCenter: CGPoint(x: f(0.28), y: f(0.72)),
                         endRadius: art * 0.22, options: [])
}

ctx.addPath(dish)
ctx.setStrokeColor(c(0xF7F7F7, 0.10))
ctx.setLineWidth(2)
ctx.strokePath()

// MARK: Write

guard let image = ctx.makeImage() else { fatalError("no image") }
guard let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: outPath) as CFURL,
                                                 "public.png" as CFString, 1, nil) else {
    fatalError("cannot create destination")
}
CGImageDestinationAddImage(dest, image, nil)
guard CGImageDestinationFinalize(dest) else { fatalError("cannot write \(outPath)") }
SWIFT

echo "→ رندر مستر ۲۰۴۸px…"
swiftc -O -o "$WORK/render" "$WORK/render.swift" \
  -framework CoreGraphics -framework ImageIO
"$WORK/render" "$WORK/master.png"

echo "→ ساخت بسته‌ی آیکون…"
ICONSET="$WORK/AppIcon.iconset"
mkdir -p "$ICONSET"
for size in 16 32 64 128 256 512 1024; do
  sips -Z "$size" -s format png "$WORK/master.png" --out "$WORK/$size.png" >/dev/null
done
cp "$WORK/16.png"   "$ICONSET/icon_16x16.png"
cp "$WORK/32.png"   "$ICONSET/icon_16x16@2x.png"
cp "$WORK/32.png"   "$ICONSET/icon_32x32.png"
cp "$WORK/64.png"   "$ICONSET/icon_32x32@2x.png"
cp "$WORK/128.png"  "$ICONSET/icon_128x128.png"
cp "$WORK/256.png"  "$ICONSET/icon_128x128@2x.png"
cp "$WORK/256.png"  "$ICONSET/icon_256x256.png"
cp "$WORK/512.png"  "$ICONSET/icon_256x256@2x.png"
cp "$WORK/512.png"  "$ICONSET/icon_512x512.png"
cp "$WORK/1024.png" "$ICONSET/icon_512x512@2x.png"

iconutil -c icns "$ICONSET" -o Resources/AppIcon.icns
sips -Z 256 -s format png "$WORK/master.png" --out /tmp/icon_preview.png >/dev/null
sips -Z 32 -s format png "$WORK/master.png" --out /tmp/icon_tiny.png >/dev/null
sips -Z 96 -s format png /tmp/icon_tiny.png --out /tmp/icon_tiny_big.png >/dev/null

echo "✓ Resources/AppIcon.icns بازسازی شد ($(du -h Resources/AppIcon.icns | cut -f1))"
echo "  پیش‌نمایش: /tmp/icon_preview.png و /tmp/icon_tiny_big.png"
