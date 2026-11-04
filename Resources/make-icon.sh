#!/bin/bash
# بازسازی Resources/AppIcon.icns — نشانۀ «لنز استودیو».
# حلقهٔ گرافیتی لنز با روزنۀ شش‌ضلعیِ روشن (دیافراگم) و رینگ لیمویی روی لبۀ
# پایین-راست. رنگ‌ها از Theme.swift گرفته شده‌اند.
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
ctx.setShouldAntialias(true)
ctx.interpolationQuality = .high

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
func P(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: f(x), y: f(y)) }

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

func circle(_ center: CGPoint, _ r: CGFloat) -> CGPath {
    CGPath(ellipseIn: CGRect(x: center.x - r, y: center.y - r, width: r * 2, height: r * 2),
           transform: nil)
}

func fill(_ path: CGPath, _ color: CGColor) {
    ctx.addPath(path)
    ctx.setFillColor(color)
    ctx.fillPath()
}

func stroke(_ path: CGPath, _ color: CGColor, _ width: CGFloat) {
    ctx.addPath(path)
    ctx.setStrokeColor(color)
    ctx.setLineWidth(width)
    ctx.setLineCap(.round)
    ctx.setLineJoin(.round)
    ctx.strokePath()
}

func vgrad(_ clip: CGPath, _ from: CGPoint, _ to: CGPoint,
           _ stops: [(CGFloat, CGColor)], evenOdd: Bool = false) {
    ctx.saveGState()
    ctx.addPath(clip)
    ctx.clip(using: evenOdd ? .evenOdd : .winding)
    let gradient = CGGradient(colorsSpace: space,
                              colors: stops.map { $0.1 } as CFArray,
                              locations: stops.map { $0.0 })!
    ctx.drawLinearGradient(gradient, start: from, end: to,
                           options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    ctx.restoreGState()
}

func radial(_ center: CGPoint, _ radius: CGFloat, _ stops: [(CGFloat, CGColor)],
            _ clip: CGPath) {
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

/// Paints only the inside edge of a path, fading from `from` to `to`.
func rimLight(_ path: CGPath, width: CGFloat, from: CGPoint, to: CGPoint,
              color: CGColor, alpha: CGFloat = 0.9) {
    ctx.saveGState()
    ctx.beginTransparencyLayer(auxiliaryInfo: nil)
    ctx.addPath(path)
    ctx.clip()
    ctx.addPath(path)
    ctx.setLineWidth(width)
    ctx.setLineJoin(.round)
    ctx.setLineCap(.round)
    ctx.replacePathWithStrokedPath()
    ctx.clip()
    ctx.setFillColor(color.copy(alpha: alpha) ?? color)
    ctx.fill(CGRect(x: 0, y: 0, width: unit, height: unit))
    ctx.setBlendMode(.destinationIn)
    let fade = CGGradient(colorsSpace: space,
                          colors: [c(0xFFFFFF), c(0xFFFFFF, 0.55), c(0xFFFFFF, 0)] as CFArray,
                          locations: [0, 0.55, 1])!
    ctx.drawLinearGradient(fade, start: from, end: to, options: [])
    ctx.setBlendMode(.normal)
    ctx.endTransparencyLayer()
    ctx.restoreGState()
}

// MARK: Graphite plate

let plate = rr(margin, margin, art, art, art * 0.2245)

ctx.saveGState()
ctx.addPath(plate)
ctx.clip()
let body = CGGradient(colorsSpace: space,
                      colors: [c(0x4A4E55), c(0x2A2D33), c(0x121418)] as CFArray,
                      locations: [0, 0.45, 1])!
ctx.drawLinearGradient(body, start: P(0.06, 0.04), end: P(0.94, 0.98),
                       options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
ctx.restoreGState()

radial(P(0.36, 0.10), art * 0.85,
       [(0, c(0xFFFFFF, 0.10)), (1, c(0xFFFFFF, 0))], plate)
vgrad(plate, P(0, 0.68), P(0, 1.02),
      [(0, c(0x000000, 0)), (1, c(0x000000, 0.28))])
ctx.addPath(rr(margin + 1.2, margin + 1.2, art - 2.4, art - 2.4, art * 0.2245 - 1.2))
ctx.setStrokeColor(c(0xF7F7F7, 0.14))
ctx.setLineWidth(1.6)
ctx.strokePath()

// MARK: The lens

let center = P(0.5, 0.5)
let outer = art * 0.345
let ringWidth = art * 0.054
let inner = outer - ringWidth

// The lens barrel.
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: 20), blur: 46, color: c(0x000000, 0.60))
fill(circle(center, outer), c(0x0C0E11))
ctx.restoreGState()

// Glass, cold and deep.
vgrad(circle(center, inner), P(0.5, 0.22), P(0.5, 0.86),
      [(0, c(0x1B2C39)), (0.5, c(0x0D141A)), (1, c(0x06090C))])
radial(CGPoint(x: center.x + inner * 0.12, y: center.y + inner * 0.18),
       inner * 0.95,
       [(0, c(0x74D2FF, 0.20)), (0.55, c(0x74D2FF, 0.05)), (1, c(0x000000, 0))],
       circle(center, inner))

// Blades, seams and a hexagonal opening: the shape a lens makes.
let hexRadius = inner * 0.60
func around(_ radius: CGFloat, _ deg: CGFloat) -> CGPoint {
    let a = deg * .pi / 180
    return CGPoint(x: center.x + cos(a) * radius, y: center.y + sin(a) * radius)
}
let hex = CGMutablePath()
for i in 0..<6 {
    let point = around(hexRadius, 30 + CGFloat(i) * 60)
    if i == 0 { hex.move(to: point) } else { hex.addLine(to: point) }
}
hex.closeSubpath()

ctx.saveGState()
ctx.addPath(circle(center, inner))
ctx.clip()
// Blade faces.
vgrad(circle(center, inner), P(0.28, 0.16), P(0.72, 0.86),
      [(0, c(0x353B45)), (0.5, c(0x262B33)), (1, c(0x1A1E24))])
radial(P(0.34, 0.28), inner * 1.1,
       [(0, c(0xFFFFFF, 0.10)), (1, c(0xFFFFFF, 0))], circle(center, inner))
radial(P(0.70, 0.70), inner * 0.9,
       [(0, c(0xDFF57A, 0.12)), (1, c(0xDFF57A, 0))], circle(center, inner))

// The glass in the opening.
vgrad(hex, P(0.36, 0.28), P(0.64, 0.74),
      [(0, c(0x2C4A5E)), (0.45, c(0x16262F)), (1, c(0x070B0E))])
radial(around(0, hexRadius * 0.15), hexRadius * 1.05,
       [(0, c(0x74D2FF, 0.22)), (0.6, c(0x74D2FF, 0.05)), (1, c(0x000000, 0))], hex)
stroke(hex, c(0xBFE9FF, 0.16), art * 0.004)

// A seam from every corner, angled like a turning shutter.
for i in 0..<6 {
    let corner = around(hexRadius, 30 + CGFloat(i) * 60)
    let foot = around(inner * 0.995, 30 + CGFloat(i) * 60 + 26)
    let seam = CGMutablePath()
    seam.move(to: corner)
    seam.addLine(to: foot)
    stroke(seam, c(0x05060A, 0.55), art * 0.012)
    let lit = CGMutablePath()
    lit.move(to: CGPoint(x: corner.x, y: corner.y + art * 0.006))
    lit.addLine(to: foot)
    stroke(lit, c(0xD7E2EC, 0.10), art * 0.0025)
}
// The barrel throws a shadow onto the blades.
ctx.addPath(circle(center, inner))
ctx.setStrokeColor(c(0x000000, 0.50))
ctx.setLineWidth(art * 0.020)
ctx.strokePath()
ctx.restoreGState()

// Barrel face, then the chartreuse sweep on its lower right.
let donut = CGMutablePath()
donut.addPath(circle(center, outer))
donut.addPath(circle(center, inner))
vgrad(donut, P(0.06, 0.02), P(0.96, 1.0),
      [(0, c(0x5A5F67)), (0.45, c(0x2D3138)), (1, c(0x16181C))], evenOdd: true)
rimLight(circle(center, outer - art * 0.010), width: art * 0.026,
         from: P(0.88, 1.02), to: P(0.02, 0.02), color: c(0xDFF57A), alpha: 0.90)
ctx.saveGState()
ctx.addPath(donut)
ctx.clip(using: .evenOdd)
stroke(circle(center, outer - 1.4), c(0xF7F7F7, 0.18), 2.2)
// Cold bounce under the opening.
stroke(circle(center, inner + art * 0.008), c(0xBFE9FF, 0.16), art * 0.006)
ctx.restoreGState()

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
