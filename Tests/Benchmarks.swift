import CoreGraphics
import CoreImage
import CoreVideo
import Darwin
import Foundation
import ImageIO
import StudioCore
import UniformTypeIdentifiers
import Vision

// Measures the engine stages the product actually pays for. It is deliberately
// outside Tests/run.sh: timings depend on the host and must never gate a
// correctness run. Run it with ./Tests/run-benchmarks.sh.

struct StageTiming: Encodable {
    var name: String
    var seconds: Double
    var runs: Int
}

struct ImageBenchmark: Encodable {
    var name: String
    var width: Int
    var height: Int
    var bitsPerComponent: Int
    var faces: Int
    var stages: [StageTiming]
    var residentAfterLoadMB: Double
}

struct BenchmarkReport: Encodable {
    var tool: String
    var generatedAt: String
    var commit: String
    var os: String
    var cpu: String
    var memoryGB: Double
    var measurements: [String: String]
    var notes: [String]
    var images: [ImageBenchmark]
    var peakResidentMB: Double
}

func now() -> Double {
    Double(DispatchTime.now().uptimeNanoseconds) / 1_000_000_000
}

func measure(_ body: () throws -> Void) rethrows -> Double {
    let start = now()
    try body()
    return now() - start
}

func median(_ values: [Double]) -> Double {
    guard !values.isEmpty else { return 0 }
    let sorted = values.sorted()
    let middle = sorted.count / 2
    return sorted.count % 2 == 0 ? (sorted[middle - 1] + sorted[middle]) / 2 : sorted[middle]
}

func stage(_ name: String, runs: [Double]) -> StageTiming {
    StageTiming(name: name, seconds: median(runs), runs: runs.count)
}

func residentBytes() -> UInt64 {
    var info = mach_task_basic_info()
    var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
    let result = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
        }
    }
    return result == KERN_SUCCESS ? info.resident_size : 0
}

func peakResidentBytes() -> UInt64 {
    var usage = rusage()
    guard getrusage(RUSAGE_SELF, &usage) == 0 else { return 0 }
    return UInt64(usage.ru_maxrss)
}

func sysctlString(_ name: String) -> String {
    var size = 0
    guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return "unknown" }
    var buffer = [CChar](repeating: 0, count: size)
    guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return "unknown" }
    return String(cString: buffer)
}

func sysctlUInt64(_ name: String) -> UInt64 {
    var value: UInt64 = 0
    var size = MemoryLayout<UInt64>.size
    guard sysctlbyname(name, &value, &size, nil, 0) == 0 else { return 0 }
    return value
}

func sRGB() -> CGColorSpace {
    CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
}

/// A camera-sized frame with a smooth falloff and per-pixel noise, so the
/// JPEG decoder and the filters see textured data rather than flat blocks.
func makeSynthetic(width: Int, height: Int) -> CGImage? {
    let bytesPerRow = width * 4
    guard let context = CGContext(data: nil, width: width, height: height,
                                  bitsPerComponent: 8, bytesPerRow: bytesPerRow,
                                  space: sRGB(),
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue),
          let base = context.data?.assumingMemoryBound(to: UInt8.self)
    else { return nil }

    var state: UInt64 = 0x9E37_79B9_7F4A_7C15
    for y in 0..<height {
        let fy = Double(y) / Double(height)
        for x in 0..<width {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            let noise = Int((state >> 33) & 0xFF) / 8 - 14
            let fx = Double(x) / Double(width)
            let radial = max(0, 1 - hypot(fx - 0.5, fy - 0.45) * 1.8)
            let r = UInt8(clamping: 40 + Int(180 * radial) + noise)
            let g = UInt8(clamping: 55 + Int(120 * radial) + noise / 2)
            let b = UInt8(clamping: 70 + Int(90 * (1 - radial)) + noise / 3)
            let index = y * bytesPerRow + x * 4
            base[index] = r
            base[index + 1] = g
            base[index + 2] = b
            base[index + 3] = 255
        }
    }
    return context.makeImage()
}

func makeSynthetic16(width: Int, height: Int) -> CGImage? {
    guard let gradient = CIFilter(name: "CILinearGradient", parameters: [
        "inputPoint0": CIVector(x: 0, y: 0),
        "inputPoint1": CIVector(x: CGFloat(width), y: CGFloat(height)),
        "inputColor0": CIColor(red: 0.25, green: 0.10, blue: 0.06),
        "inputColor1": CIColor(red: 0.85, green: 0.70, blue: 0.60)
    ])?.outputImage?.cropped(to: CGRect(x: 0, y: 0, width: width, height: height)),
    let noise = CIFilter(name: "CIRandomGenerator")?.outputImage?
        .cropped(to: CGRect(x: 0, y: 0, width: width, height: height))
        .applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: 0.05, y: 0, z: 0, w: 0),
            "inputGVector": CIVector(x: 0, y: 0.05, z: 0, w: 0),
            "inputBVector": CIVector(x: 0, y: 0, z: 0.05, w: 0),
            "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 0.10),
            "inputBiasVector": CIVector(x: 0, y: 0, z: 0, w: 0)
        ])
    else { return nil }
    let mixed = noise.composited(over: gradient)
    return ImageProcessor.shared.renderCGImage(mixed, scale: 1, colorSpace: sRGB(), format: .RGBA16)
}

func write(_ image: CGImage, to url: URL, type: UTType, quality: Double? = nil) -> Bool {
    guard let destination = CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil)
    else { return false }
    var properties: [CFString: Any] = [:]
    if let quality { properties[kCGImageDestinationLossyCompressionQuality] = quality }
    CGImageDestinationAddImage(destination, image, properties as CFDictionary)
    return CGImageDestinationFinalize(destination)
}

func benchmarkAdjustments() -> Adjustments {
    var adjustments = Adjustments()
    adjustments.smooth = 40
    adjustments.texturePreserve = 50
    adjustments.skinToneEvens = 30
    adjustments.eyeBrighten = 20
    adjustments.teethWhiten = 15
    adjustments.eyeSize = 10
    adjustments.faceWidth = 5
    adjustments.exposure = 6
    adjustments.contrast = 8
    adjustments.vibrance = 6
    return adjustments
}

func sourceDepth(_ url: URL) -> Int {
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
          let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
    else { return 0 }
    return (properties[kCGImagePropertyDepth] as? NSNumber)?.intValue ?? 0
}

func gitCommit(root: URL) -> String {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
    process.arguments = ["-C", root.path, "rev-parse", "HEAD"]
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = Pipe()
    do { try process.run() } catch { return "unknown" }
    process.waitUntilExit()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    return String(data: data, encoding: .utf8)?
        .trimmingCharacters(in: .whitespacesAndNewlines) ?? "unknown"
}

func padded(_ value: String, _ width: Int) -> String {
    value.count >= width ? value : value + String(repeating: " ", count: width - value.count)
}

func benchmark(_ url: URL, label: String, exportFormat: ExportFormat,
               workDirectory: URL) -> ImageBenchmark? {
    let processor = ImageProcessor.shared
    let adjustments = benchmarkAdjustments()

    // One untimed load warms the decoder and the Core Image cache, so the first
    // measured run is not reported as cold-start cost.
    guard processor.load(from: url, previewMaxDimension: 2048) != nil else {
        print("  ✗ could not load \(url.lastPathComponent)")
        return nil
    }

    var loadRuns: [Double] = []
    var previewRuns: [Double] = []
    var analyzeRuns: [Double] = []
    var maskRuns: [Double] = []
    var exportRuns: [Double] = []
    var batchRuns: [Double] = []
    var load: LoadResult?
    var residentAfterLoad: UInt64 = 0

    for _ in 0..<3 {
        // ImageIO, Vision and Core Image return autoreleased buffers; a command
        // line tool has no runloop to drain them, so each run gets its own pool.
        // Without this the probe measures pool accumulation, not the engine.
        autoreleasepool {
            var result: LoadResult?
            let seconds = measure {
                result = processor.load(from: url, previewMaxDimension: 2048)
            }
            guard let result else { return }
            load = result
            loadRuns.append(seconds)
            residentAfterLoad = residentBytes()

            let previewTime = measure {
                let rendered = processor.process(result.sourcePreview, adjustments: adjustments,
                                                masks: result.masksPreview, faces: result.faces)
                _ = processor.renderCGImage(rendered, scale: 1, colorSpace: result.colorSpace)
            }
            previewRuns.append(previewTime)

            if !result.faces.isEmpty, let buffer = AutoAnalyzer.analysisBuffer(result.sourcePreview) {
                let maskBuffer = result.masksPreview?.skin.flatMap { AutoAnalyzer.analysisBuffer($0) }
                let crops = result.faces.map {
                    processor.faceCrop(for: $0, in: result.sourcePreview,
                                       skinMask: result.masksPreview?.skin)
                }
                let analyzeTime = measure {
                    _ = SmartAnalyzer.analyze(buffer: buffer, skinMask: maskBuffer,
                                              faces: result.faces, crops: crops)
                }
                analyzeRuns.append(analyzeTime)

                if result.masksPreview?.skin != nil {
                    let maskTime = measure {
                        _ = processor.buildMasks(extent: result.sourceFull.extent,
                                                 faces: result.faces,
                                                 image: result.sourceFull,
                                                 maskDimension: MaskBuilder.exportMaskDimension)
                    }
                    maskRuns.append(maskTime)
                }
            }
        }
    }

    guard let loaded = load else {
        print("  ✗ load failed for \(url.lastPathComponent)")
        return nil
    }
    let aspect = loaded.sourcePixelSize.width / loaded.sourcePixelSize.height
    let source = ExportSource(image: loaded.sourceFull, masks: nil, faces: loaded.faces,
                              photoAspect: aspect, colorSpace: loaded.colorSpace,
                              metadata: loaded.metadata, xmp: loaded.xmp)
    let request = RenderRequest(adjustments: adjustments, format: exportFormat,
                                quality: 0.92, longEdge: nil,
                                stripsPrivacyMetadata: true,
                                includeStamps: false, includeAnalysis: false,
                                aiUpscale: false)

    for index in 0..<2 {
        let destination = workDirectory.appendingPathComponent("bench-\(label)-\(index).\(exportFormat.fileExtension)")
        autoreleasepool {
            let seconds = measure {
                guard let rendered = ExportService.render(request, source: source) else { return }
                _ = ExportService.writeResult(rendered, snapshot: request, to: destination,
                                              colorSpace: loaded.colorSpace,
                                              metadata: loaded.metadata,
                                              xmp: loaded.xmp, protecting: nil)
            }
            exportRuns.append(seconds)
        }
    }

    let batchDirectory = workDirectory.appendingPathComponent("batch-\(label)", isDirectory: true)
    try? FileManager.default.createDirectory(at: batchDirectory, withIntermediateDirectories: true)
    let batchTime = measure {
        for index in 0..<4 {
            autoreleasepool {
                let destination = batchDirectory.appendingPathComponent("frame-\(index).\(exportFormat.fileExtension)")
                guard let rendered = ExportService.render(request, source: source) else { return }
                _ = ExportService.writeResult(rendered, snapshot: request, to: destination,
                                              colorSpace: loaded.colorSpace,
                                              metadata: loaded.metadata,
                                              xmp: loaded.xmp, protecting: nil)
            }
        }
    }
    batchRuns.append(batchTime)

    var stages: [StageTiming] = [
        stage("load", runs: loadRuns),
        stage("preview", runs: previewRuns)
    ]
    if !analyzeRuns.isEmpty { stages.append(stage("analysis", runs: analyzeRuns)) }
    if !maskRuns.isEmpty { stages.append(stage("masks", runs: maskRuns)) }
    stages.append(stage("export", runs: exportRuns))
    stages.append(stage("batch4", runs: batchRuns))

    let result = ImageBenchmark(name: loaded.fileName,
                                width: Int(loaded.pixelSize.width.rounded()),
                                height: Int(loaded.pixelSize.height.rounded()),
                                bitsPerComponent: sourceDepth(url),
                                faces: loaded.faces.count, stages: stages,
                                residentAfterLoadMB: Double(residentAfterLoad) / 1_048_576)
    // Each measured image is a separate document; the app does not keep the
    // previous photo's render intermediates alive.
    processor.context.clearCaches()
    return result
}

let root = URL(fileURLWithPath: ProcessInfo.processInfo.environment["RETOUCH_TESTS_ROOT"] ?? ".")
let workDirectory = URL(fileURLWithPath: NSTemporaryDirectory())
    .appendingPathComponent("retouch-bench-\(UUID().uuidString)", isDirectory: true)
try? FileManager.default.createDirectory(at: workDirectory, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: workDirectory) }

var inputs: [(URL, String, ExportFormat)] = []
let syntheticSizes = [("12mp", 4000, 3000), ("24mp", 6000, 4000), ("48mp", 8000, 6000)]
for (name, width, height) in syntheticSizes {
    let url = workDirectory.appendingPathComponent("\(name).jpg")
    guard let image = makeSynthetic(width: width, height: height),
          write(image, to: url, type: .jpeg, quality: 0.9) else {
        print("✗ could not build the \(name) fixture")
        exit(1)
    }
    inputs.append((url, name, .jpeg))
}

let sixteenURL = workDirectory.appendingPathComponent("12mp-16bit.png")
if let image = makeSynthetic16(width: 4000, height: 3000),
   write(image, to: sixteenURL, type: .png) {
    inputs.append((sixteenURL, "12mp-16bit", .png))
} else {
    print("! 16-bit fixture skipped: this host could not build it")
}

if let directory = ProcessInfo.processInfo.environment["RETOUCH_BENCH_REAL_DIR"], !directory.isEmpty {
    let candidates = (try? FileManager.default.contentsOfDirectory(
        at: URL(fileURLWithPath: directory), includingPropertiesForKeys: nil))?
        .filter { ["jpg", "jpeg"].contains($0.pathExtension.lowercased()) }
        .sorted { $0.lastPathComponent < $1.lastPathComponent } ?? []
    for url in candidates.prefix(3) {
        inputs.append((url, url.deletingPathExtension().lastPathComponent, .jpeg))
    }
    if candidates.isEmpty { print("! no JPEGs found in \(directory)") }
}

// A repeated load+export on one frame shows whether the Core Image cache
// plateaus or grows with every document. Run it with RETOUCH_BENCH_MEMORY_PROBE
// set to 1, clear, load, render, decode, vision or vision-buffer; each mode
// narrows the retention to a smaller part of the path. Findings are recorded
// in Docs/PERFORMANCE_BENCHMARKS.md.
let memoryProbeMode = ProcessInfo.processInfo.environment["RETOUCH_BENCH_MEMORY_PROBE"] ?? ""
if ["1", "clear", "load", "render", "decode", "vision", "vision-buffer"].contains(memoryProbeMode) {
    guard let probe = inputs.first(where: { $0.1 == "24mp" })?.0 else {
        print("✗ the memory probe needs the 24 MP fixture")
        exit(1)
    }
    let processor = ImageProcessor.shared
    if memoryProbeMode == "decode" {
        print("memory probe — ImageIO decode only")
        for cycle in 1...8 {
            autoreleasepool {
                let source = CGImageSourceCreateWithURL(probe as CFURL, nil)
                _ = source.flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) }
                print("  cycle \(cycle): \(String(format: "%.0f", Double(residentBytes()) / 1_048_576)) MB resident")
            }
        }
        exit(0)
    }
    if memoryProbeMode == "vision" || memoryProbeMode == "vision-buffer" {
        guard let still = processor.load(from: probe, previewMaxDimension: 2048) else { exit(1) }
        let preview = still.originalPreview
        var pixelBuffer: CVPixelBuffer?
        if memoryProbeMode == "vision-buffer" {
            let status = CVPixelBufferCreate(nil, preview.width, preview.height,
                                             kCVPixelFormatType_32BGRA,
                                             [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary,
                                             &pixelBuffer)
            guard status == kCVReturnSuccess, let pixelBuffer else { exit(1) }
            processor.context.render(CIImage(cgImage: preview), to: pixelBuffer,
                                     bounds: CGRect(x: 0, y: 0, width: preview.width, height: preview.height),
                                     colorSpace: still.colorSpace)
        }
        print("memory probe — Vision face detection (\(memoryProbeMode))")
        for cycle in 1...8 {
            autoreleasepool {
                if let pixelBuffer {
                    let request = VNDetectFaceLandmarksRequest()
                    let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, options: [:])
                    try? handler.perform([request])
                } else {
                    _ = FaceAnalyzer.analyze(preview)
                }
                print("  cycle \(cycle): \(String(format: "%.0f", Double(residentBytes()) / 1_048_576)) MB resident")
            }
        }
        exit(0)
    }
    let previewLimit = CGFloat(Double(ProcessInfo.processInfo.environment["RETOUCH_BENCH_PREVIEW"] ?? "") ?? 2048)
    print("memory probe — repeated 24 MP cycles (mode: \(memoryProbeMode), preview \(Int(previewLimit)))")
    // "render" decodes once so only the export path repeats.
    let retained = memoryProbeMode == "render"
        ? processor.load(from: probe, previewMaxDimension: previewLimit) : nil
    for cycle in 1...8 {
        autoreleasepool {
            guard let loaded = retained ?? processor.load(from: probe, previewMaxDimension: 2048) else {
                exit(1)
            }
            let source = ExportSource(image: loaded.sourceFull, masks: nil, faces: loaded.faces,
                                      photoAspect: loaded.sourcePixelSize.width / loaded.sourcePixelSize.height,
                                      colorSpace: loaded.colorSpace,
                                      metadata: loaded.metadata, xmp: loaded.xmp)
            let request = RenderRequest(adjustments: benchmarkAdjustments(), format: .jpeg,
                                        quality: 0.92, longEdge: nil,
                                        stripsPrivacyMetadata: true,
                                        includeStamps: false, includeAnalysis: false,
                                        aiUpscale: false)
            if memoryProbeMode == "load" {
                print("  cycle \(cycle): \(String(format: "%.0f", Double(residentBytes()) / 1_048_576)) MB resident")
                return
            }
            if let rendered = ExportService.render(request, source: source) {
                _ = ExportService.writeResult(rendered, snapshot: request,
                                              to: workDirectory.appendingPathComponent("probe-\(cycle).jpg"),
                                              colorSpace: loaded.colorSpace,
                                              metadata: loaded.metadata,
                                              xmp: loaded.xmp, protecting: nil)
            }
            if memoryProbeMode == "clear" { processor.context.clearCaches() }
            print("  cycle \(cycle): \(String(format: "%.0f", Double(residentBytes()) / 1_048_576)) MB resident")
        }
    }
    print("  peak: \(String(format: "%.0f", Double(peakResidentBytes()) / 1_048_576)) MB")
    processor.context.clearCaches()
    print("  after clearCaches: \(String(format: "%.0f", Double(residentBytes()) / 1_048_576)) MB resident")
    exit(0)
}

print("RetouchStudio benchmarks — \(sysctlString("machdep.cpu.brand_string"))")
var results: [ImageBenchmark] = []
for (url, label, format) in inputs {
    print("→ \(label)")
    guard let result = benchmark(url, label: label, exportFormat: format,
                                 workDirectory: workDirectory) else {
        print("  ✗ skipped")
        continue
    }
    results.append(result)
    for stage in result.stages {
        print("  \(padded(stage.name, 9))\(String(format: "%6.3f s", stage.seconds))  (\(stage.runs) runs)")
    }
    print("  faces \(result.faces) · \(String(format: "%.0f", result.residentAfterLoadMB)) MB resident")
}

let commit = ProcessInfo.processInfo.environment["RETOUCH_BENCH_COMMIT"] ?? gitCommit(root: root)

let report = BenchmarkReport(
    tool: "Tests/run-benchmarks.sh",
    generatedAt: ISO8601DateFormatter().string(from: Date()),
    commit: commit,
    os: ProcessInfo.processInfo.operatingSystemVersionString,
    cpu: sysctlString("machdep.cpu.brand_string"),
    memoryGB: Double(sysctlUInt64("hw.memsize")) / 1_073_741_824,
    measurements: [
        "previewMaxDimension": "2048",
        "exportQuality": "0.92",
        "adjustments": "smooth 40, texture 50, tone 30, eyes 20/10, teeth 15, faceWidth 5, exposure 6, contrast 8, vibrance 6"
    ],
    notes: [
        "Synthetic frames are deterministic; they contain no face, so analysis and mask stages are reported only for real photos.",
        "One untimed load warms the decoder before the measured runs.",
        "Timings are single-machine observations on the host printed above, not controlled benchmarks."
    ],
    images: results,
    peakResidentMB: Double(peakResidentBytes()) / 1_048_576)

let outputDirectory = root.appendingPathComponent("build/benchmarks", isDirectory: true)
try? FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
let output = outputDirectory.appendingPathComponent("latest.json")
let encoder = JSONEncoder()
encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
if let data = try? encoder.encode(report) {
    try? data.write(to: output, options: .atomic)
    print("→ wrote \(output.path)")
} else {
    print("✗ could not encode the report")
    exit(1)
}
