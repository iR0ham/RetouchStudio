// Renders one adjustment with Core Image, the engine the macOS app uses, so a
// Windows model can be measured against the real filter instead of a guess.
//
//   swift Tools/ci-vignette-reference.swift <photo.png> <strength> <scale> <out.png>
//
// strength is the slider value (-100...100); scale resamples the source before
// the filter so the size behaviour can be checked. The vignette is applied
// exactly as ImageProcessor does: CIVignette with intensity 1.4 * strength/100
// and radius 0.78 * short side, in an extended-linear-sRGB working space.

import CoreGraphics
import CoreImage
import Foundation
import ImageIO
import UniformTypeIdentifiers

let arguments = CommandLine.arguments
guard arguments.count == 5,
      let strength = Double(arguments[2]),
      let scale = Double(arguments[3]) else {
    FileHandle.standardError.write(Data("usage: ci-vignette-reference.swift <photo.png> <strength> <scale> <out.png>\n".utf8))
    exit(2)
}
let sourcePath = arguments[1]
let outputPath = arguments[4]

let context = CIContext(options: [
    .cacheIntermediates: true,
    .workingColorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB) as Any
])
guard let loaded = CIImage(contentsOf: URL(fileURLWithPath: sourcePath)) else {
    FileHandle.standardError.write(Data("cannot read \(sourcePath)\n".utf8))
    exit(1)
}
let source = scale == 1
    ? loaded
    : loaded.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
let shortSide = min(source.extent.width, source.extent.height)

var image = source
if strength > 0 {
    image = source.applyingFilter("CIVignette", parameters: [
        kCIInputIntensityKey: 1.4 * strength / 100,
        kCIInputRadiusKey: shortSide * 0.78,
    ])
}

let space = CGColorSpace(name: CGColorSpace.sRGB)!
guard let rendered = context.createCGImage(image, from: image.extent, format: .RGBA8,
                                           colorSpace: space) else {
    FileHandle.standardError.write(Data("render failed\n".utf8))
    exit(1)
}
let destination = CGImageDestinationCreateWithURL(
    URL(fileURLWithPath: outputPath) as CFURL, UTType.png.identifier as CFString, 1, nil)!
CGImageDestinationAddImage(destination, rendered, nil)
guard CGImageDestinationFinalize(destination) else {
    FileHandle.standardError.write(Data("write failed\n".utf8))
    exit(1)
}
print("wrote \(outputPath)")
