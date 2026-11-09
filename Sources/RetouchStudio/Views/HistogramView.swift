import AppKit
import SwiftUI

/// RGB and luma counts of the current preview, normalized to the tallest bin.
struct HistogramBins: Equatable {
    var red: [Double] = []
    var green: [Double] = []
    var blue: [Double] = []
    var luma: [Double] = []

    var isEmpty: Bool { red.isEmpty }
    static let empty = HistogramBins()
}

/// Reads a small copy of the preview instead of the full photo: 80 px on the
/// long side is ~5k samples, enough to see clipping and colour balance, and
/// cheap enough to run on every preview update.
enum HistogramSampler {
    static func bins(from image: NSImage?, count: Int = 64) -> HistogramBins {
        guard let image,
              let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
              cg.width > 0, cg.height > 0,
              let space = CGColorSpace(name: CGColorSpace.sRGB) else { return .empty }

        let scale = min(1, 80 / CGFloat(max(cg.width, cg.height)))
        let width = max(1, Int((CGFloat(cg.width) * scale).rounded()))
        let height = max(1, Int((CGFloat(cg.height) * scale).rounded()))
        var pixels = [UInt8](repeating: 0, count: width * height * 4)

        let drew: Bool = pixels.withUnsafeMutableBytes { buffer in
            guard let base = buffer.baseAddress,
                  let context = CGContext(
                    data: base, width: width, height: height,
                    bitsPerComponent: 8, bytesPerRow: width * 4,
                    space: space,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { return false }
            context.interpolationQuality = .low
            context.draw(cg, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drew else { return .empty }

        var red = [Double](repeating: 0, count: count)
        var green = red
        var blue = red
        var luma = red
        for index in stride(from: 0, to: pixels.count, by: 4) {
            let r = Int(pixels[index])
            let g = Int(pixels[index + 1])
            let b = Int(pixels[index + 2])
            red[min(count - 1, r * count / 256)] += 1
            green[min(count - 1, g * count / 256)] += 1
            blue[min(count - 1, b * count / 256)] += 1
            let l = Int((0.2126 * Double(r) + 0.7152 * Double(g) + 0.0722 * Double(b)).rounded())
            luma[min(count - 1, l * count / 256)] += 1
        }

        let peak = max(red.max() ?? 0, green.max() ?? 0, blue.max() ?? 0, luma.max() ?? 0)
        guard peak > 0 else { return .empty }
        func normalized(_ values: [Double]) -> [Double] { values.map { $0 / peak } }
        return HistogramBins(red: normalized(red), green: normalized(green),
                             blue: normalized(blue), luma: normalized(luma))
    }
}

/// A compact live histogram for the Color panel. Screen blending lets the three
/// channels add up where they overlap the way light does.
struct HistogramView: View {
    let image: NSImage?
    var accessibilityLabel: String

    @State private var bins = HistogramBins.empty

    var body: some View {
        Canvas { context, size in
            guard !bins.isEmpty, size.width > 1, size.height > 1 else { return }
            let channels: [([Double], Color)] = [
                (bins.red, .red), (bins.green, .green), (bins.blue, .blue),
                (bins.luma, .white),
            ]
            for (values, color) in channels {
                let path = area(values, in: size)
                var layer = context
                layer.blendMode = .screen
                layer.fill(path, with: .color(color.opacity(0.16)))
                layer.stroke(path, with: .color(color.opacity(0.42)), lineWidth: 0.75)
            }
        }
        .frame(height: 66)
        .padding(.horizontal, 7)
        .padding(.top, 5)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
                .fill(Theme.background)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
                .strokeBorder(Theme.stroke, lineWidth: 0.75)
        )
        .accessibilityElement()
        .accessibilityLabel(accessibilityLabel)
        .onAppear { bins = HistogramSampler.bins(from: image) }
        .onChange(of: image) { _, _ in bins = HistogramSampler.bins(from: image) }
    }

    private func area(_ values: [Double], in size: CGSize) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: 0, y: size.height))
        let steps = max(1, values.count - 1)
        for (index, value) in values.enumerated() {
            path.addLine(to: CGPoint(x: size.width * CGFloat(index) / CGFloat(steps),
                                     y: size.height * (1 - CGFloat(min(1, value)))))
        }
        path.addLine(to: CGPoint(x: size.width, y: size.height))
        path.closeSubpath()
        return path
    }
}
