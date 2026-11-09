import AppKit
import CoreGraphics
import CoreImage
import Dispatch
import Foundation
import UniformTypeIdentifiers

// Model-level regressions. These drive the real `EditorModel` through the same
// load and export paths the UI uses; only the panels are skipped. Every check
// here corresponds to a P0/P1 finding in Docs/TECHNICAL_AUDIT.md.

@MainActor var failures: [String] = []

@MainActor
func check(_ condition: Bool, _ label: String, _ detail: String = "") {
    if condition {
        print("  ✓ \(label)\(detail.isEmpty ? "" : " — \(detail)")")
    } else {
        print("  ✗ \(label)\(detail.isEmpty ? "" : " — \(detail)")")
        failures.append(label)
    }
}

let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!
let workDir = FileManager.default.temporaryDirectory
    .appendingPathComponent("retouch-modeltests-\(UUID().uuidString)")
try? FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)

/// Suspends the MainActor task so the model's own load/export tasks can run.
@MainActor
func waitUntil(_ timeout: TimeInterval = 60, _ condition: @MainActor () -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if condition() { return true }
        try? await Task.sleep(nanoseconds: 20_000_000)
    }
    return condition()
}

func makeImage(width: Int, height: Int) -> CGImage? {
    guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                              bytesPerRow: 0, space: sRGB,
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { return nil }
    let w = CGFloat(width), h = CGFloat(height)
    ctx.setFillColor(CGColor(srgbRed: 0.72, green: 0.60, blue: 0.52, alpha: 1))
    ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
    ctx.setFillColor(CGColor(srgbRed: 0.84, green: 0.70, blue: 0.62, alpha: 1))
    ctx.fillEllipse(in: CGRect(x: w * 0.24, y: h * 0.18, width: w * 0.52, height: h * 0.62))
    ctx.setFillColor(CGColor(srgbRed: 0.30, green: 0.22, blue: 0.20, alpha: 1))
    ctx.fillEllipse(in: CGRect(x: w * 0.36, y: h * 0.55, width: w * 0.08, height: h * 0.04))
    ctx.fillEllipse(in: CGRect(x: w * 0.56, y: h * 0.55, width: w * 0.08, height: h * 0.04))
    return ctx.makeImage()
}

func writePNG(_ image: CGImage, to url: URL) -> Bool {
    guard let dest = CGImageDestinationCreateWithURL(url as CFURL,
                                                     UTType.png.identifier as CFString,
                                                     1, nil) else { return false }
    CGImageDestinationAddImage(dest, image, nil)
    return CGImageDestinationFinalize(dest)
}

@MainActor
func removeRecentEntries(under directory: URL) {
    for entry in RecentStore.shared.entries where entry.path.hasPrefix(directory.path) {
        RecentStore.shared.remove(entry)
    }
}

// MARK: - P0-1 / C-1

@MainActor
func testExportDoesNotSave() async {
    print("\n[P0-1] an export is a copy, not a saved project")

    let sourceURL = workDir.appendingPathComponent("source.png")
    check(makeImage(width: 480, height: 600).map { writePNG($0, to: sourceURL) } ?? false,
          "fixture written")

    let model = EditorModel()
    model.load(url: sourceURL)
    check(await waitUntil { model.hasImage && !model.isBusy }, "fixture loads")

    model.adjustments.smooth = 40
    check(model.hasUnsavedChanges, "an edit marks the document dirty")

    let firstExport = workDir.appendingPathComponent("first.png")
    model.export(to: firstExport)
    let firstDone = await waitUntil(120) {
        FileManager.default.fileExists(atPath: firstExport.path) && !model.isBusy
    }
    check(firstDone, "export finishes")
    check(model.hasUnsavedChanges, "export leaves the document dirty")

    // A document that was already clean must stay clean: the fix must not
    // invent a dirty flag where there is no unsaved work.
    model.discardUnsavedChanges()
    check(!model.hasUnsavedChanges, "clean baseline is restored")

    let secondExport = workDir.appendingPathComponent("second.png")
    model.export(to: secondExport)
    _ = await waitUntil(120) {
        FileManager.default.fileExists(atPath: secondExport.path) && !model.isBusy
    }
    check(!model.hasUnsavedChanges, "exporting a clean document stays clean")

    // A failed write must not touch the clean baseline either.
    model.adjustments.contrast = 25
    let dirtyBeforeFailure = model.hasUnsavedChanges
    model.export(to: workDir.appendingPathComponent("missing/never.png"))
    _ = await waitUntil(120) { !model.isBusy }
    check(model.hasUnsavedChanges == dirtyBeforeFailure,
          "a failed export leaves the dirty flag unchanged")
}

// MARK: - P0-2 / H-1

/// Every retouch slider carries a distinct sentinel so a cleared field is
/// unmistakable in the comparison.
func sentinelAdjustments() -> Adjustments {
    var a = Adjustments()
    a.smooth = 11; a.blemish = 12; a.wrinkle = 13; a.skinToneEvens = 14
    a.darkCircles = 15; a.skinBrighten = 16; a.texturePreserve = 17
    a.teethWhiten = 18; a.eyeBrighten = 19; a.eyeSharpen = 20
    a.skinFinish = 21; a.shine = 22; a.irisEnhance = 23; a.lashDarken = 24
    a.lensTint = 25; a.teethAlign = 26
    a.exposure = 31; a.contrast = 32; a.blacks = 33; a.whites = 34
    a.saturation = 35; a.vibrance = 36; a.warmth = 37; a.clarity = 38
    a.vignette = 39; a.splitTone = 40
    a.curveShadows = 41; a.curveMidtones = 42; a.curveHighlights = 43
    a.hslHue = Array(repeating: 44, count: HSLBand.allCases.count)
    a.hslSaturation = Array(repeating: 45, count: HSLBand.allCases.count)
    a.hslLuminance = Array(repeating: 46, count: HSLBand.allCases.count)
    a.lipTint = 51; a.blush = 52; a.browDefine = 53
    a.eyeSize = 61; a.noseSize = 62; a.lipSize = 63
    a.bodySmooth = 71; a.bodySlim = 72
    a.backgroundBlur = 81; a.backgroundTone = 82
    a.hairColor = 91; a.hairShine = 92; a.hairVolume = 93
    a.lookStrength = 95; a.grain = 96
    return a
}

func changedRetouchFields(_ before: Adjustments, _ after: Adjustments) -> Adjustments.RetouchField {
    var fields: Adjustments.RetouchField = []
    if before.smooth != after.smooth { fields.insert(.smooth) }
    if before.blemish != after.blemish { fields.insert(.blemish) }
    if before.wrinkle != after.wrinkle { fields.insert(.wrinkle) }
    if before.skinToneEvens != after.skinToneEvens { fields.insert(.skinToneEvens) }
    if before.darkCircles != after.darkCircles { fields.insert(.darkCircles) }
    if before.skinBrighten != after.skinBrighten { fields.insert(.skinBrighten) }
    if before.texturePreserve != after.texturePreserve { fields.insert(.texturePreserve) }
    if before.teethWhiten != after.teethWhiten { fields.insert(.teethWhiten) }
    if before.eyeBrighten != after.eyeBrighten { fields.insert(.eyeBrighten) }
    if before.eyeSharpen != after.eyeSharpen { fields.insert(.eyeSharpen) }
    if before.skinFinish != after.skinFinish { fields.insert(.skinFinish) }
    if before.shine != after.shine { fields.insert(.shine) }
    if before.irisEnhance != after.irisEnhance { fields.insert(.irisEnhance) }
    if before.lashDarken != after.lashDarken { fields.insert(.lashDarken) }
    if before.lensTint != after.lensTint { fields.insert(.lensTint) }
    if before.lensColor != after.lensColor { fields.insert(.lensColor) }
    if before.teethAlign != after.teethAlign { fields.insert(.teethAlign) }
    return fields
}

func changedColorFields(_ before: Adjustments, _ after: Adjustments) -> Adjustments.ColorField {
    var fields: Adjustments.ColorField = []
    if before.exposure != after.exposure { fields.insert(.exposure) }
    if before.contrast != after.contrast { fields.insert(.contrast) }
    if before.blacks != after.blacks { fields.insert(.blacks) }
    if before.whites != after.whites { fields.insert(.whites) }
    if before.saturation != after.saturation { fields.insert(.saturation) }
    if before.vibrance != after.vibrance { fields.insert(.vibrance) }
    if before.warmth != after.warmth { fields.insert(.warmth) }
    if before.clarity != after.clarity { fields.insert(.clarity) }
    if before.vignette != after.vignette { fields.insert(.vignette) }
    if before.splitTone != after.splitTone { fields.insert(.splitTone) }
    if before.curveShadows != after.curveShadows { fields.insert(.curveShadows) }
    if before.curveMidtones != after.curveMidtones { fields.insert(.curveMidtones) }
    if before.curveHighlights != after.curveHighlights { fields.insert(.curveHighlights) }
    if before.hslHue != after.hslHue { fields.insert(.hslHue) }
    if before.hslSaturation != after.hslSaturation { fields.insert(.hslSaturation) }
    if before.hslLuminance != after.hslLuminance { fields.insert(.hslLuminance) }
    return fields
}

func makeFadedImage(width: Int, height: Int) -> CGImage? {
    guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                              bytesPerRow: 0, space: sRGB,
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { return nil }
    ctx.setFillColor(CGColor(srgbRed: 0.47, green: 0.47, blue: 0.47, alpha: 1))
    ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
    ctx.setFillColor(CGColor(srgbRed: 0.56, green: 0.55, blue: 0.54, alpha: 1))
    ctx.fillEllipse(in: CGRect(x: 20, y: 20, width: CGFloat(width) - 40,
                               height: CGFloat(height) - 40))
    ctx.setFillColor(CGColor(srgbRed: 0.36, green: 0.35, blue: 0.34, alpha: 1))
    ctx.fill(CGRect(x: 0, y: CGFloat(height) * 0.4, width: CGFloat(width) * 0.3, height: 12))
    return ctx.makeImage()
}

@MainActor
func testSmartKeepsUnmeasuredFields() async {
    print("\n[P0-2] Smart Analyze only writes what it measured")

    let base = sentinelAdjustments()
    let zero = Adjustments()

    let retouchApplied = base.applyingRetouch(zero, fields: .smart)
    let retouchChanged = changedRetouchFields(base, retouchApplied)
    check(retouchChanged.isSubset(of: .smart),
          "retouch apply leaves the owner's other fields alone",
          "changed \(retouchChanged.rawValue & ~Adjustments.RetouchField.smart.rawValue) outside")
    for (label, untouched) in [
        ("skin finish", retouchApplied.skinFinish == base.skinFinish),
        ("lens tint", retouchApplied.lensTint == base.lensTint),
        ("lens colour", retouchApplied.lensColor == base.lensColor),
        ("teeth align", retouchApplied.teethAlign == base.teethAlign),
        ("iris enhance", retouchApplied.irisEnhance == base.irisEnhance),
        ("lash darken", retouchApplied.lashDarken == base.lashDarken),
    ] {
        check(untouched, "\(label) survives a Smart apply")
    }
    check(retouchApplied.smooth == 0 && retouchApplied.blemish == 0,
          "a measured zero is still applied")

    let colorApplied = base.applyingColorLight(zero, fields: .autoColorLight)
    let colorChanged = changedColorFields(base, colorApplied)
    check(colorChanged.isSubset(of: .autoColorLight),
          "color apply leaves vignette, curves, split tone and HSL alone",
          "changed \(colorChanged.rawValue & ~Adjustments.ColorField.autoColorLight.rawValue) outside")

    // The field sets must track what the analyzers actually produce.
    let findings: [SmartAnalyzer.Finding] = [
        .init(kind: .texture, severity: 1, detail: .texturePronounced),
        .init(kind: .blemish, severity: 1, detail: .spots(4)),
        .init(kind: .wrinkles, severity: 1, detail: .linesHeavy),
        .init(kind: .darkCircles, severity: 1, detail: .underEyeStrong),
        .init(kind: .shine, severity: 1, detail: .shineHeavy),
        .init(kind: .unevenTone, severity: 1, detail: .tonePatchy),
        .init(kind: .teeth, severity: 1, detail: .teethWarm),
        .init(kind: .eyes, severity: 1, detail: .eyesDim),
    ]
    let retouchPatch = SmartAnalyzer.retouchValues(findings: findings, hasEyes: true,
                                                   scleraLevel: 0.4, skinMedian: 0.40)
    let producedRetouch = changedRetouchFields(Adjustments(), retouchPatch)
    check(!producedRetouch.isEmpty && producedRetouch.isSubset(of: .smart),
          "retouchValues stays inside the smart field set",
          "produced \(producedRetouch.rawValue)")

    if let cg = makeFadedImage(width: 320, height: 240), let buffer = PixelBuffer(cgImage: cg) {
        let colorPatch = AutoAnalyzer.autoColorLight(buffer)
        let producedColor = changedColorFields(Adjustments(), colorPatch)
        check(!producedColor.isEmpty, "the faded fixture actually asks for a correction")
        check(producedColor.isSubset(of: .autoColorLight),
              "autoColorLight stays inside its field set",
              "produced \(producedColor.rawValue)")
    } else {
        check(false, "faded fixture for the color coverage test")
    }
}

// MARK: - P0-3 / H-2

@MainActor
func testResetAllClearsEverything() async {
    print("\n[P0-3] Reset All clears the whole document in one step")

    let sourceURL = workDir.appendingPathComponent("source.png")
    let model = EditorModel()
    model.load(url: sourceURL)
    check(await waitUntil { model.hasImage && !model.isBusy }, "fixture reloads")

    model.adjustments.smooth = 30
    model.tapHeal(at: CGPoint(x: 0.5, y: 0.5))
    model.tapArt(at: CGPoint(x: 0.3, y: 0.3))
    check(await waitUntil { !model.isBusy }, "the stamp preview settles")
    model.cropDraft = CGRect(x: 0.1, y: 0.1, width: 0.8, height: 0.8)
    model.applyCrop()
    check(await waitUntil { !model.isBusy && model.appliedCrop != nil }, "a crop joins the edit")
    // Pins are placed after the crop: applying a crop clears the old endpoints,
    // so a pin set before it would not be part of the document being reset.
    model.analysis.isEnabled = true
    model.analysis.setEndpoint(CGPoint(x: 0.9, y: 0.9), for: .lips)
    check(!model.isDocumentPristine, "a document with every kind of edit is not pristine")

    model.resetAll()
    check(model.adjustments.isIdentity, "sliders are back to zero")
    check(model.healSpots.isEmpty, "heal stamps are gone")
    check(model.stickers.isEmpty, "stickers are gone")
    check(model.analysis == AnalysisSettings(), "analysis overlay is back to default")
    check(model.appliedCrop == nil, "the crop is back to the original framing")
    check(model.isDocumentPristine, "the document reads as pristine")
    check(await waitUntil { !model.isBusy }, "the uncropped pixels finish loading")

    model.undo()
    check(model.adjustments.smooth == 30, "one undo restores the slider")
    check(model.healSpots.count == 1, "one undo restores the stamp")
    check(model.stickers.count == 1, "one undo restores the sticker")
    check(model.analysis.isEnabled && !model.analysis.endpoints.isEmpty,
          "one undo restores the analysis pins")
    check(model.appliedCrop != nil, "one undo restores the crop")
    check(await waitUntil { !model.isBusy }, "the restored crop finishes re-reading")
}

// MARK: - P1-1 / H-3

func readImage(_ url: URL) -> CGImage? {
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
    return CGImageSourceCreateImageAtIndex(source, 0, nil)
}

/// Mean absolute channel difference in 0…255, the same scale a 1/255
/// acceptance threshold is written in.
func meanDelta(_ aURL: URL, _ bURL: URL) -> Double? {
    guard let a = readImage(aURL), let b = readImage(bURL),
          a.width == b.width, a.height == b.height else { return nil }

    func bytes(_ image: CGImage) -> [UInt8]? {
        var data = [UInt8](repeating: 0, count: image.width * image.height * 4)
        guard let ctx = CGContext(data: &data, width: image.width, height: image.height,
                                  bitsPerComponent: 8, bytesPerRow: image.width * 4,
                                  space: sRGB,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return data
    }

    guard let da = bytes(a), let db = bytes(b) else { return nil }
    var sum = 0.0
    for offset in stride(from: 0, to: da.count, by: 4) {
        for channel in 0..<3 {
            sum += abs(Double(da[offset + channel]) - Double(db[offset + channel]))
        }
    }
    return sum / Double((da.count / 4) * 3)
}

/// How many pixels differ by more than `threshold` on any channel. A small
/// sticker barely moves a whole-image mean, but it is unmistakable per pixel.
func changedPixels(_ aURL: URL, _ bURL: URL, threshold: Int = 8) -> Int? {
    guard let a = readImage(aURL), let b = readImage(bURL),
          a.width == b.width, a.height == b.height else { return nil }

    func bytes(_ image: CGImage) -> [UInt8]? {
        var data = [UInt8](repeating: 0, count: image.width * image.height * 4)
        guard let ctx = CGContext(data: &data, width: image.width, height: image.height,
                                  bitsPerComponent: 8, bytesPerRow: image.width * 4,
                                  space: sRGB,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return data
    }

    guard let da = bytes(a), let db = bytes(b) else { return nil }
    var count = 0
    for offset in stride(from: 0, to: da.count, by: 4) {
        for channel in 0..<3 where abs(Int(da[offset + channel]) - Int(db[offset + channel])) > threshold {
            count += 1
            break
        }
    }
    return count
}

@MainActor
func testBatchMatchesSingleExport() async {
    print("\n[P1-1] batch export equals a single export and respects each file's shape")

    let docURL = workDir.appendingPathComponent("batch-doc.png")
    let sameURL = workDir.appendingPathComponent("batch-same.png")
    let squareURL = workDir.appendingPathComponent("batch-square.png")
    guard let docImage = makeImage(width: 800, height: 600),
          let squareImage = makeImage(width: 600, height: 600) else {
        check(false, "batch fixtures")
        return
    }
    check(writePNG(docImage, to: docURL) && writePNG(docImage, to: sameURL)
          && writePNG(squareImage, to: squareURL), "fixtures written")

    let brokenURL = workDir.appendingPathComponent("batch-broken.txt")
    try? "not a photo".write(to: brokenURL, atomically: true, encoding: .utf8)

    let model = EditorModel()
    model.load(url: docURL)
    check(await waitUntil { model.hasImage && !model.isBusy }, "document loads")

    model.cropDraft = CGRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5)
    model.applyCrop()
    check(await waitUntil { !model.isBusy && model.appliedCrop != nil }, "crop applies")

    model.adjustments.contrast = 30
    model.adjustments.exposure = 8
    model.tapHeal(at: CGPoint(x: 0.5, y: 0.5))
    model.tapArt(at: CGPoint(x: 0.3, y: 0.3))
    model.exportFormat = .png

    let singleURL = workDir.appendingPathComponent("batch-single.png")
    model.export(to: singleURL)
    check(await waitUntil(120) {
        FileManager.default.fileExists(atPath: singleURL.path) && !model.isBusy
    }, "single export finishes")

    let folder = workDir.appendingPathComponent("batch-out")
    try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

    model.batchIncludeStamps = true
    model.batchIncludeAnalysis = true
    model.runBatch([sameURL, squareURL, brokenURL], to: folder)
    check(await waitUntil(180) { !model.isBatchRunning && model.batchHasReport },
          "batch finishes")

    check(model.batchTotal == 3, "batch reports all three files", "total \(model.batchTotal)")
    check(model.batchSavedCount == 2 && model.batchSkippedCrops == 1,
          "one file failed and one crop was skipped",
          "saved \(model.batchSavedCount), skipped \(model.batchSkippedCrops)")
    check(!model.isBusy, "isBusy is released once at the end")

    let sameOut = folder.appendingPathComponent("batch-same-retouched.png")
    let squareOut = folder.appendingPathComponent("batch-square-retouched.png")
    if let delta = meanDelta(singleURL, sameOut) {
        check(delta < 1.0, "batch pixels match the single export",
              String(format: "mean delta %.3f/255", delta))
    } else {
        check(false, "same-shape batch file written", sameOut.lastPathComponent)
    }

    if let sameDims = readImage(sameOut) {
        check(sameDims.width == 400 && sameDims.height == 300,
              "same-shape file takes the document crop",
              "\(sameDims.width)×\(sameDims.height)")
    } else {
        check(false, "same-shape output reads back")
    }

    if let squareDims = readImage(squareOut) {
        check(squareDims.width == 600 && squareDims.height == 600,
              "different-shape file exports whole",
              "\(squareDims.width)×\(squareDims.height)")
    } else {
        check(false, "square output reads back")
    }

    let leftovers = (try? FileManager.default.contentsOfDirectory(atPath: folder.path))?
        .filter { $0.hasSuffix(".tmp") } ?? []
    check(leftovers.isEmpty, "no partial files remain", leftovers.joined(separator: ", "))

    // Stamps are opt-in for batch work, so the same snapshot without them must
    // produce a different picture from the one that carried them.
    let plainFolder = workDir.appendingPathComponent("batch-plain")
    try? FileManager.default.createDirectory(at: plainFolder, withIntermediateDirectories: true)
    model.batchIncludeStamps = false
    model.runBatch([sameURL], to: plainFolder)
    check(await waitUntil(180) { !model.isBatchRunning && model.batchHasReport },
          "batch without stamps finishes")
    let plainOut = plainFolder.appendingPathComponent("batch-same-retouched.png")
    if let stampDelta = meanDelta(sameOut, plainOut) {
        let changed = changedPixels(sameOut, plainOut) ?? 0
        check(stampDelta > 0.1 && changed > 100, "stamps and stickers appear only when asked for",
              String(format: "mean delta %.2f/255, %d pixels changed", stampDelta, changed))
    } else {
        check(false, "batch without stamps written")
    }
}

// MARK: - P1-2 / H-5

@MainActor
func testCropIsUndoable() async {
    print("\n[P1-2] crop travels through undo history")

    let url = workDir.appendingPathComponent("crop-undo.png")
    guard let image = makeImage(width: 800, height: 600), writePNG(image, to: url) else {
        check(false, "crop fixture")
        return
    }

    let model = EditorModel()
    model.load(url: url)
    check(await waitUntil { model.hasImage && !model.isBusy }, "fixture loads")
    check(model.workingPixelSize == CGSize(width: 800, height: 600), "original frame is 800×600")

    let half = CGRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5)
    model.cropDraft = half
    model.applyCrop()
    check(await waitUntil { !model.isBusy && model.appliedCrop != nil }, "crop applies")
    check(model.workingPixelSize == CGSize(width: 400, height: 300), "crop re-reads the pixels")
    check(model.hasUnsavedChanges, "a crop-only edit is unsaved work")
    check(model.canUndo, "the crop is an undo step")

    model.undo()
    check(await waitUntil { !model.isBusy }, "undo finishes its re-read")
    check(model.appliedCrop == nil && model.workingPixelSize == CGSize(width: 800, height: 600),
          "undo restores the previous frame")
    check(!model.hasUnsavedChanges, "undo returns to the clean baseline")
    check(model.canRedo, "redo is offered")

    model.redo()
    check(await waitUntil { !model.isBusy }, "redo finishes its re-read")
    check(model.appliedCrop != nil && model.workingPixelSize == CGSize(width: 400, height: 300),
          "redo re-applies the crop")

    // The re-read must not clear the stack: one undo gives the frame back, a
    // second undo still reaches the slider edit made before the crop.
    model.undo()
    _ = await waitUntil { !model.isBusy }
    model.adjustments.contrast = 24
    model.commitAdjustments()
    model.cropDraft = CGRect(x: 0.1, y: 0.1, width: 0.8, height: 0.8)
    model.applyCrop()
    _ = await waitUntil { !model.isBusy }
    check(model.appliedCrop != nil, "second crop applies")

    model.undo()
    _ = await waitUntil { !model.isBusy }
    check(model.adjustments.contrast == 24 && model.appliedCrop == nil,
          "one undo removes only the crop")
    model.undo()
    _ = await waitUntil { !model.isBusy }
    check(model.adjustments.contrast == 0, "the next undo reaches the slider")
    check(model.workingPixelSize == CGSize(width: 800, height: 600), "back at the original frame")

    // Reset Crop is its own step too.
    model.cropDraft = half
    model.applyCrop()
    _ = await waitUntil { !model.isBusy }
    model.resetCrop()
    check(await waitUntil { !model.isBusy && model.appliedCrop == nil }, "reset crop applies")
    model.undo()
    check(await waitUntil { !model.isBusy }, "undo after reset finishes")
    check(model.appliedCrop != nil && model.workingPixelSize == CGSize(width: 400, height: 300),
          "undo of Reset Crop brings the crop back")

    // A second undo arriving while the first re-read is still running must win:
    // the stale load is discarded by the generation guard.
    model.cropDraft = CGRect(x: 0.05, y: 0.05, width: 0.5, height: 0.5)
    model.applyCrop()
    model.undo()
    model.undo()
    check(await waitUntil { !model.isBusy }, "overlapping undos settle")
    check(model.appliedCrop == nil && model.workingPixelSize == CGSize(width: 800, height: 600),
          "a stale crop reload never installs")
}

// MARK: - P1-3 / H-4 / M-9

@MainActor
func writeProject(_ project: RetouchProject, to url: URL) -> Bool {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    guard let data = try? encoder.encode(project) else { return false }
    return (try? data.write(to: url, options: .atomic)) != nil
}

@MainActor
func testProjectRelink() async {
    print("\n[P1-3] a moved photo is found again")

    let folderA = workDir.appendingPathComponent("relink-a-\(UUID().uuidString)")
    let folderB = workDir.appendingPathComponent("relink-b-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: folderA, withIntermediateDirectories: true)
    try? FileManager.default.createDirectory(at: folderB, withIntermediateDirectories: true)
    let originalPhoto = folderA.appendingPathComponent("portrait.png")
    let movedPhoto = folderB.appendingPathComponent("portrait.png")
    let projectURL = folderA.appendingPathComponent("portrait.retouch")

    guard let image = makeImage(width: 480, height: 600), writePNG(image, to: originalPhoto) else {
        check(false, "relink fixture")
        return
    }
    // The bookmark is made where the photo lives today. Moving the file must
    // not invalidate it.
    let bookmark = try? originalPhoto.bookmarkData(options: [],
                                                   includingResourceValuesForKeys: nil,
                                                   relativeTo: nil)
    let project = RetouchProject(imagePath: originalPhoto.path,
                                 imageBookmark: bookmark,
                                 adjustments: .zero,
                                 exportFormat: "jpeg",
                                 exportQuality: 0.9,
                                 autoRetouchStrength: 70)
    check(writeProject(project, to: projectURL), "project written next to the photo")
    try? FileManager.default.moveItem(at: originalPhoto, to: movedPhoto)
    check(!FileManager.default.fileExists(atPath: originalPhoto.path),
          "photo moved away from the recorded path")

    let model = EditorModel()
    model.openProject(at: projectURL)
    check(await waitUntil { model.hasImage && !model.isBusy }, "project opens with the photo missing")
    check(model.statusToken == .projectRelinked, "the status says the photo was relinked",
          "\(model.statusToken)")
    check(model.workingPixelSize == CGSize(width: 480, height: 600), "the moved photo is the one loaded")

    // The project was rewritten with the new path, so opening it again resolves
    // without asking anyone.
    let rewritten = (try? Data(contentsOf: projectURL))
        .flatMap { try? JSONDecoder().decode(RetouchProject.self, from: $0) }
    let recordedURL = rewritten.map { URL(fileURLWithPath: $0.imagePath).resolvingSymlinksInPath() }
    check(recordedURL == movedPhoto.resolvingSymlinksInPath(),
          "the project now records the new path", rewritten?.imagePath ?? "unreadable")
    check(rewritten?.imageBookmark != nil, "the rebuilt bookmark is stored")
    if let rewritten {
        let resolved = model.resolveProjectImage(rewritten, projectURL: projectURL)
        check(resolved?.standardizedFileURL == movedPhoto.standardizedFileURL,
              "a second open resolves straight to the photo")
    }

    // A whole folder move (photo + project together) needs no bookmark at all:
    // the sibling next to the project is the photo.
    let folderC = workDir.appendingPathComponent("relink-c-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: folderC, withIntermediateDirectories: true)
    let movedFolder = workDir.appendingPathComponent("relink-d-\(UUID().uuidString)")
    try? FileManager.default.moveItem(at: folderC, to: movedFolder)
    let siblingPhoto = movedFolder.appendingPathComponent("sibling.png")
    check(makeImage(width: 120, height: 120).map { writePNG($0, to: siblingPhoto) } ?? false,
          "sibling fixture written")
    let siblingProject = RetouchProject(imagePath: folderC.appendingPathComponent("sibling.png").path,
                                        adjustments: .zero,
                                        exportFormat: "jpeg",
                                        exportQuality: 0.9,
                                        autoRetouchStrength: 70)
    let siblingURL = movedFolder.appendingPathComponent("sibling.retouch")
    let siblingResolved = model.resolveProjectImage(
        siblingProject, projectURL: siblingURL)
    check(siblingResolved?.standardizedFileURL == siblingPhoto.standardizedFileURL,
          "a moved folder resolves through the sibling path")

    let gone = RetouchProject(imagePath: "/nonexistent/\(UUID().uuidString).png",
                              adjustments: .zero,
                              exportFormat: "jpeg",
                              exportQuality: 0.9,
                              autoRetouchStrength: 70)
    check(model.resolveProjectImage(gone, projectURL: movedFolder.appendingPathComponent("gone.retouch")) == nil,
          "a photo that is truly gone goes to Locate")
}

@MainActor
func testProjectVersionGuard() async {
    print("\n[P1-3] future projects are refused, old ones still open")

    let folder = workDir.appendingPathComponent("version-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let photoURL = folder.appendingPathComponent("photo.png")
    let projectURL = folder.appendingPathComponent("future.retouch")
    guard let image = makeImage(width: 240, height: 300), writePNG(image, to: photoURL) else {
        check(false, "version fixture")
        return
    }

    var future = RetouchProject(imagePath: photoURL.path,
                                adjustments: .zero,
                                exportFormat: "jpeg",
                                exportQuality: 0.9,
                                autoRetouchStrength: 70)
    future.version = RetouchProject.currentVersion + 1
    check(writeProject(future, to: projectURL), "a version-2 project is written")

    let model = EditorModel()
    model.openProject(at: projectURL)
    // The guard runs synchronously before the load, so no sleep is needed.
    check(model.statusToken == .projectTooNew(RetouchProject.currentVersion + 1),
          "the version guard explains why it was refused", "\(model.statusToken)")
    check(!model.hasImage, "nothing was loaded from the newer project")

    // A project written before the version key existed is version 1.
    let encoder = JSONEncoder()
    guard var object = (try? encoder.encode(future)).flatMap({
        try? JSONSerialization.jsonObject(with: $0)
    }) as? [String: Any] else {
        check(false, "fixture JSON")
        return
    }
    object.removeValue(forKey: "version")
    object.removeValue(forKey: "imageBookmark")
    guard let legacyData = try? JSONSerialization.data(withJSONObject: object),
          let legacy = try? JSONDecoder().decode(RetouchProject.self, from: legacyData) else {
        check(false, "a project without a version key decodes")
        return
    }
    check(legacy.version == RetouchProject.currentVersion,
          "a missing version decodes as the current one", "v\(legacy.version)")
    check(legacy.imageBookmark == nil, "a project without a bookmark still opens")

    let chosen = RetouchProject(imagePath: photoURL.path,
                                adjustments: .zero,
                                exportFormat: "png",
                                exportQuality: 1,
                                autoRetouchStrength: 70,
                                selectedFace: 1)
    let reopened = (try? JSONEncoder().encode(chosen))
        .flatMap { try? JSONDecoder().decode(RetouchProject.self, from: $0) }
    check(reopened?.selectedFace == 1, "the chosen face survives save and reopen",
          "selectedFace=\(reopened?.selectedFace.map(String.init) ?? "nil")")
}

// MARK: - P1-5 / M-13 / M-4

@MainActor
func testOperationCoordination() async {
    print("\n[P1-5] blocking work is serialized and previews cannot end it")

    let sourceURL = workDir.appendingPathComponent("coordination.png")
    guard let big = makeImage(width: 2400, height: 1800), writePNG(big, to: sourceURL) else {
        check(false, "coordination fixture")
        return
    }

    let model = EditorModel()
    model.load(url: sourceURL)
    check(await waitUntil { model.hasImage && !model.isBusy }, "fixture loads")

    // A preview in flight must lose the busy flag to the export that follows.
    model.schedulePreview()
    check(model.isBusy, "a preview starts as busy")

    let first = workDir.appendingPathComponent("coordination-first.png")
    model.export(to: first)
    check(model.isExporting && model.isBusy, "export starts over the preview")

    model.schedulePreview()
    check(model.isBusy, "a preview requested during an export is refused")
    try? await Task.sleep(nanoseconds: 120_000_000)
    if model.isExporting {
        check(model.isBusy, "the interrupted preview never clears the export's busy flag")
    }
    check(await waitUntil(240) { !model.isBusy && !model.isExporting }, "export releases busy once")
    check(FileManager.default.fileExists(atPath: first.path), "the export was written")

    // A second blocking request is refused with a visible status, not queued.
    let second = workDir.appendingPathComponent("coordination-second.png")
    model.export(to: second)
    check(model.isExporting, "a fresh export starts")
    let third = workDir.appendingPathComponent("coordination-third.png")
    model.export(to: third)
    check(model.statusToken == .operationBusy, "a concurrent export is refused", "\(model.statusToken)")

    let refusedFolder = workDir.appendingPathComponent("coordination-refused-batch")
    try? FileManager.default.createDirectory(at: refusedFolder, withIntermediateDirectories: true)
    model.runBatch([sourceURL], to: refusedFolder)
    check(!model.isBatchRunning && model.statusToken == .operationBusy,
          "a batch cannot start during an export")
    model.undo()
    check(model.statusToken == .operationBusy, "undo is refused while an export runs")

    check(await waitUntil(240) { !model.isBusy && !model.isExporting }, "the export still finishes")
    check(!FileManager.default.fileExists(atPath: third.path), "the refused export wrote nothing")
    let refusedOut = (try? FileManager.default.contentsOfDirectory(atPath: refusedFolder.path)) ?? []
    check(refusedOut.isEmpty, "the refused batch wrote nothing", refusedOut.joined(separator: ", "))

    // Cancelling a render releases busy exactly once and leaves no file.
    let cancelled = workDir.appendingPathComponent("coordination-cancelled.png")
    model.export(to: cancelled)
    model.cancelExport()
    check(await waitUntil(240) { !model.isBusy && !model.isExporting }, "cancel releases busy")
    check(model.statusToken == .exportCancelled, "cancel is reported", "\(model.statusToken)")
    check(!FileManager.default.fileExists(atPath: cancelled.path), "a cancelled export writes no file")

    // A cancelled batch stops between files and reports why.
    let batchFolder = workDir.appendingPathComponent("coordination-batch")
    try? FileManager.default.createDirectory(at: batchFolder, withIntermediateDirectories: true)
    model.runBatch([sourceURL, sourceURL], to: batchFolder)
    check(model.isBatchRunning && model.isBusy, "batch starts")
    model.cancelBatchExport()
    check(await waitUntil(240) { !model.isBatchRunning && !model.isBusy }, "batch cancel releases busy")
    check(model.statusToken == .batchCancelled, "batch cancel is reported", "\(model.statusToken)")
    let leftovers = (try? FileManager.default.contentsOfDirectory(atPath: batchFolder.path))?
        .filter { $0.hasSuffix(".tmp") } ?? []
    check(leftovers.isEmpty, "a cancelled batch leaves no partial files",
          leftovers.joined(separator: ", "))
}

// MARK: - P1-6 / H-6 / M-3

@MainActor
func testPreviewStaysAtPreviewResolution() async {
    print("\n[P1-6] a slider preview renders the preview copy, not the full photo")

    let url = workDir.appendingPathComponent("preview-resolution.png")
    guard let image = makeImage(width: 3000, height: 2000), writePNG(image, to: url) else {
        check(false, "preview-resolution fixture")
        return
    }

    let model = EditorModel()
    model.load(url: url)
    check(await waitUntil { model.hasImage && !model.isBusy }, "fixture loads")
    check(model.workingPixelSize == CGSize(width: 3000, height: 2000),
          "the full photo is 3000×2000", "\(model.workingPixelSize)")

    let loaded = model.previewImage?.size ?? .zero
    check(max(loaded.width, loaded.height) > 0 && max(loaded.width, loaded.height) <= 1800,
          "the loaded preview is capped at 1800 px",
          "\(Int(loaded.width))×\(Int(loaded.height))")

    model.adjustments.contrast = 20
    model.schedulePreview()
    check(await waitUntil { !model.isBusy }, "the slider preview settles")
    let rendered = model.previewImage?.size ?? .zero
    check(max(rendered.width, rendered.height) > 0
            && max(rendered.width, rendered.height) <= 1800,
          "a slider preview still renders the preview copy",
          "\(Int(rendered.width))×\(Int(rendered.height))")
}

// MARK: - P2-6 / M-6

@MainActor
func testPrivacySettingDefaults() async {
    print("\n[P2-6] privacy stripping defaults on and survives a restart")

    let suite = "RetouchStudio.tests.\(UUID().uuidString)"
    guard let store = UserDefaults(suiteName: suite) else {
        check(false, "temporary preferences")
        return
    }
    defer { store.removePersistentDomain(forName: suite) }

    let fresh = AppSettings(store: store)
    check(fresh.stripLocationMetadata,
          "a fresh install strips location and camera identity")

    fresh.stripLocationMetadata = false
    let reopened = AppSettings(store: store)
    check(!reopened.stripLocationMetadata, "turning it off survives a restart")

    // A preference file written before the key existed has no answer; the
    // missing key must mean the private default, not "keep everything".
    store.removeObject(forKey: "settings.stripLocationMetadata")
    let missing = AppSettings(store: store)
    check(missing.stripLocationMetadata,
          "a preference without the key keeps the private default")

    reopened.resetToDefaults()
    check(reopened.stripLocationMetadata, "Restore Defaults turns the strip back on")
}

// MARK: - Phase 2: AI edits

/// A solid RGBA image, used as synthetic patch pixels.
func solidImage(width: Int, height: Int,
                red: CGFloat, green: CGFloat, blue: CGFloat) -> CGImage? {
    guard let ctx = CGContext(data: nil, width: width, height: height,
                              bitsPerComponent: 8, bytesPerRow: 0, space: sRGB,
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { return nil }
    ctx.setFillColor(CGColor(srgbRed: red, green: green, blue: blue, alpha: 1))
    ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
    return ctx.makeImage()
}

/// Stages a real pair of files in the edit store: solid patch pixels and an
/// alpha that is opaque only in a centered inset. The inset is the same
/// fraction the worker's dilation leaves inside its rectangle.
func storedAIEdit(box: CGRect, inset: CGFloat = 0.25) -> AIEdit? {
    let side = 64
    guard let patch = solidImage(width: side, height: side, red: 0.92, green: 0.16, blue: 0.08)
    else { return nil }
    let gray = CGColorSpaceCreateDeviceGray()
    guard let alphaContext = CGContext(data: nil, width: side, height: side,
                                       bitsPerComponent: 8, bytesPerRow: 0,
                                       space: gray,
                                       bitmapInfo: CGImageAlphaInfo.none.rawValue)
    else { return nil }
    alphaContext.setFillColor(gray: 0, alpha: 1)
    alphaContext.fill(CGRect(x: 0, y: 0, width: side, height: side))
    alphaContext.setFillColor(gray: 1, alpha: 1)
    let insetPixels = CGFloat(side) * inset
    alphaContext.fill(CGRect(x: insetPixels, y: insetPixels,
                             width: CGFloat(side) - 2 * insetPixels,
                             height: CGFloat(side) - 2 * insetPixels))
    guard let alpha = alphaContext.makeImage() else { return nil }

    let patchURL = workDir.appendingPathComponent("patch-\(UUID().uuidString).png")
    let alphaURL = workDir.appendingPathComponent("alpha-\(UUID().uuidString).png")
    guard writePNG(patch, to: patchURL), writePNG(alpha, to: alphaURL) else { return nil }
    let id = UUID()
    guard let files = try? AIEditStore.adopt(id: id, patch: patchURL, alpha: alphaURL)
    else { return nil }
    return AIEdit(id: id,
                  preset: "removeObject", prompt: "test", seed: 1,
                  patchFile: files.patch, alphaFile: files.alpha,
                  box: box, imagePixels: CGSize(width: side, height: side))
}

func rgbaBytes(_ image: CGImage) -> [UInt8]? {
    var data = [UInt8](repeating: 0, count: image.width * image.height * 4)
    guard let ctx = CGContext(data: &data, width: image.width, height: image.height,
                              bitsPerComponent: 8, bytesPerRow: image.width * 4,
                              space: sRGB,
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { return nil }
    ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
    return data
}

func ciBytes(_ image: CIImage, width: Int, height: Int) -> [UInt8]? {
    guard let cg = ImageProcessor.shared.context.createCGImage(
        image, from: CGRect(x: 0, y: 0, width: width, height: height),
        format: .RGBA8, colorSpace: sRGB) else { return nil }
    return rgbaBytes(cg)
}

/// Counts changed pixels outside the authorized box and inside the opaque
/// part of the alpha. `rgbaBytes` dumps rows top-first, the same order as the
/// document's top-left coordinates, so no flip is needed.
func aiDiffStats(_ a: [UInt8], _ b: [UInt8], width: Int, height: Int,
                 box: CGRect, alphaBox: CGRect) -> (outside: Int, insideAlpha: Int) {
    var outside = 0
    var insideAlpha = 0
    for row in 0..<height {
        let y = (Double(row) + 0.5) / Double(height)
        for column in 0..<width {
            let x = (Double(column) + 0.5) / Double(width)
            let offset = (row * width + column) * 4
            let changed = a[offset] != b[offset]
                || a[offset + 1] != b[offset + 1]
                || a[offset + 2] != b[offset + 2]
            guard changed else { continue }
            let point = CGPoint(x: x, y: y)
            if !box.contains(point) {
                outside += 1
            } else if alphaBox.contains(point) {
                insideAlpha += 1
            }
        }
    }
    return (outside, insideAlpha)
}

@MainActor
func testAIEditBoundaries() async {
    print("\n[P2-1] an AI edit changes only its alpha inside the authorized box")

    let box = CGRect(x: 0.25, y: 0.30, width: 0.40, height: 0.30)
    guard let edit = storedAIEdit(box: box) else {
        check(false, "the edit files are staged")
        return
    }
    defer { AIEditStore.remove(edit) }

    let layers = AICompositor.layers([edit], crop: nil)
    check(layers.count == 1, "the layer resolves from the store")

    // The same edit at preview size and at twice that size must cover the same
    // fraction of the frame: the app can re-composite at export size.
    for (width, height) in [(480, 600), (960, 1200)] {
        guard let source = makeImage(width: width, height: height) else {
            check(false, "fixture \(width)×\(height)")
            continue
        }
        let extent = CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height))
        let base = CIImage(cgImage: source).cropped(to: extent)
        let out = AICompositor.apply(layers, to: base, extent: extent)
        guard let a = rgbaBytes(source), let b = ciBytes(out, width: width, height: height) else {
            check(false, "render \(width)×\(height)")
            continue
        }

        let alphaBox = box.insetBy(dx: box.width * 0.25, dy: box.height * 0.25)
        let stats = aiDiffStats(a, b, width: width, height: height,
                                box: box, alphaBox: alphaBox)
        let expected = alphaBox.width * alphaBox.height * Double(width * height)
        check(stats.outside == 0,
              "\(width)×\(height): byte-identical outside the box",
              "\(stats.outside) px")
        check(Double(stats.insideAlpha) > expected * 0.9,
              "\(width)×\(height): the alpha area is edited",
              "\(stats.insideAlpha) of \(Int(expected)) px")
    }

    // A crop narrows the working frame; the edit's photo coordinates must move
    // with it instead of staying at the same place on screen.
    let moved = AICompositor.workingBox(CGRect(x: 0.5, y: 0.5, width: 0.25, height: 0.25),
                                        crop: CGRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5))
    check(moved == CGRect(x: 0.5, y: 0.5, width: 0.5, height: 0.5),
          "a box maps through the crop", "\(moved)")
}

@MainActor
func testAIProjectRoundTrip() async {
    print("\n[P2-2] a project carries its AI edits and reports missing pixels")

    guard let edit = storedAIEdit(box: CGRect(x: 0.2, y: 0.2, width: 0.3, height: 0.3)) else {
        check(false, "the edit files are staged")
        return
    }
    defer { AIEditStore.remove(edit) }

    let project = RetouchProject(imagePath: "/tmp/photo.jpg",
                                 adjustments: Adjustments(),
                                 exportFormat: "png", exportQuality: 0.9,
                                 autoRetouchStrength: 70, aiEdits: [edit])
    guard let encoded = try? JSONEncoder().encode(project),
          let decoded = try? JSONDecoder().decode(RetouchProject.self, from: encoded) else {
        check(false, "the project encodes and decodes")
        return
    }
    check(decoded.version == RetouchProject.currentVersion && decoded.version >= 2,
          "the project is written at the current version")
    check(decoded.aiEdits == [edit], "every AI edit survives the round trip")

    // A file written before AI edits existed has no key at all. It must open
    // with the tool off, not fail.
    guard var object = try? JSONSerialization.jsonObject(with: encoded) as? [String: Any]
    else {
        check(false, "the project is valid JSON")
        return
    }
    object.removeValue(forKey: "aiEdits")
    object["version"] = 1
    guard let legacy = try? JSONSerialization.data(withJSONObject: object),
          let old = try? JSONDecoder().decode(RetouchProject.self, from: legacy) else {
        check(false, "a version-1 project still decodes")
        return
    }
    check(old.aiEdits == nil, "an older project opens with no AI edits")

    AIEditStore.remove(edit)
    check(AICompositor.missing([edit]).count == 1, "a removed edit is reported")
    check(AICompositor.layers([edit], crop: nil).isEmpty,
          "a removed edit is not composited")
}

@MainActor
func testAIEditUndoAndExport() async {
    print("\n[P2-3] an AI edit is one undo step and reaches the export")

    let sourceURL = workDir.appendingPathComponent("ai-source.png")
    check(makeImage(width: 480, height: 600).map { writePNG($0, to: sourceURL) } ?? false,
          "fixture written")

    let model = EditorModel()
    model.exportFormat = .png
    model.load(url: sourceURL)
    check(await waitUntil { model.hasImage && !model.isBusy }, "fixture loads")

    let baseURL = workDir.appendingPathComponent("ai-base.png")
    model.export(to: baseURL)
    check(await waitUntil(120) {
        FileManager.default.fileExists(atPath: baseURL.path) && !model.isBusy
    }, "baseline export finishes")
    check(model.isDocumentPristine, "the baseline is pristine")

    let box = CGRect(x: 0.30, y: 0.35, width: 0.40, height: 0.30)
    guard let edit = storedAIEdit(box: box) else {
        check(false, "the edit files are staged")
        return
    }
    defer { AIEditStore.remove(edit) }

    model.addAIEdit(edit)
    check(model.aiEdits.count == 1 && !model.isDocumentPristine,
          "the edit joins the document")
    check(model.canUndo, "the toolbar offers undo for the new edit")
    check(await waitUntil { !model.isBusy }, "the preview settles")

    let editedURL = workDir.appendingPathComponent("ai-edited.png")
    model.export(to: editedURL)
    check(await waitUntil(120) {
        FileManager.default.fileExists(atPath: editedURL.path) && !model.isBusy
    }, "edited export finishes")

    guard let base = readImage(baseURL), let edited = readImage(editedURL),
          let a = rgbaBytes(base), let b = rgbaBytes(edited) else {
        check(false, "both exports decode")
        return
    }
    let alphaBox = box.insetBy(dx: box.width * 0.25, dy: box.height * 0.25)
    let stats = aiDiffStats(a, b, width: 480, height: 600, box: box, alphaBox: alphaBox)
    check(stats.outside == 0,
          "the export is byte-identical outside the authorized box",
          "\(stats.outside) px")
    let expected = alphaBox.width * alphaBox.height * 480 * 600
    check(Double(stats.insideAlpha) > expected * 0.9,
          "the edit is present in the exported file",
          "\(stats.insideAlpha) of \(Int(expected)) px")

    // Undo has to be pixel-stable, not only a list change: the undone document
    // must export exactly what it exported before the edit existed.
    model.undo()
    check(model.aiEdits.isEmpty, "one undo removes the edit")
    let undoneURL = workDir.appendingPathComponent("ai-undone.png")
    model.export(to: undoneURL)
    check(await waitUntil(120) {
        FileManager.default.fileExists(atPath: undoneURL.path) && !model.isBusy
    }, "undone export finishes")
    if let undone = readImage(undoneURL).flatMap(rgbaBytes) {
        let undoneStats = aiDiffStats(a, undone, width: 480, height: 600,
                                      box: box, alphaBox: alphaBox)
        check(undoneStats.outside == 0 && undoneStats.insideAlpha == 0,
              "undo restores the earlier pixels exactly")
    } else {
        check(false, "the undone export decodes")
    }

    model.redo()
    check(model.aiEdits.count == 1, "redo restores it")
    let redoneURL = workDir.appendingPathComponent("ai-redone.png")
    model.export(to: redoneURL)
    check(await waitUntil(120) {
        FileManager.default.fileExists(atPath: redoneURL.path) && !model.isBusy
    }, "redone export finishes")
    if let redone = readImage(redoneURL).flatMap(rgbaBytes) {
        // The redone document must export the same bytes the first edited
        // export produced, not merely "some edit somewhere".
        let diff = zip(b, redone).lazy.filter { $0 != $1 }.count
        check(diff == 0, "redo reproduces the edited pixels", "\(diff) bytes differ")
    } else {
        check(false, "the redone export decodes")
    }

    model.removeLastAIEdit()
    check(model.aiEdits.isEmpty, "the last edit can be removed")
}

// MARK: - Phase 3: selection masks

func grayLevel(_ image: CGImage, x: Int, y: Int) -> Int? {
    guard let data = image.dataProvider?.data as Data? else { return nil }
    let offset = y * image.bytesPerRow + x
    guard offset >= 0, offset < data.count else { return nil }
    return Int(data[offset])
}

func alphaLevel(_ image: CGImage, x: Int, y: Int) -> Int? {
    let width = image.width, height = image.height
    guard let ctx = CGContext(data: nil, width: width, height: height,
                              bitsPerComponent: 8, bytesPerRow: width * 4,
                              space: sRGB,
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { return nil }
    ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    guard let raw = ctx.data else { return nil }
    return Int(raw.load(fromByteOffset: y * width * 4 + x * 4 + 3, as: UInt8.self))
}

func isWhite(_ level: Int?) -> Bool { (level ?? -1) >= 250 }
func isBlack(_ level: Int?) -> Bool { (level ?? 256) <= 5 }

@MainActor
func testAIMaskRenderer() async {
    print("\n[P3] the selection mask keeps its orientation, erase and invert")

    let size = CGSize(width: 100, height: 100)
    // Normalized top-left box: white pixels must land in the top-left corner,
    // even though CGContext counts rows from the bottom.
    let box = CGRect(x: 0.1, y: 0.1, width: 0.2, height: 0.2)
    guard let boxMask = AIMaskRenderer.mask(size: size, strokes: [], box: box,
                                            refined: nil, inverted: false) else {
        check(false, "box mask renders")
        return
    }
    check(boxMask.width == 100 && boxMask.height == 100, "the mask matches the photo size")
    check(isWhite(grayLevel(boxMask, x: 20, y: 15)), "the box is white at the top-left")
    check(isBlack(grayLevel(boxMask, x: 20, y: 90)), "the same column is black at the bottom")
    check(isBlack(grayLevel(boxMask, x: 80, y: 20)), "the same row is black at the right")

    // A brush point at the center of the photo, one tenth of the width across.
    let dot = AIMaskStroke(points: [CGPoint(x: 0.5, y: 0.5)], width: 0.1, erase: false)
    guard let dotMask = AIMaskRenderer.mask(size: size, strokes: [dot], box: nil,
                                            refined: nil, inverted: false) else {
        check(false, "stroke mask renders")
        return
    }
    check(isWhite(grayLevel(dotMask, x: 50, y: 50)), "a brush dot is white where it was drawn")
    check(isBlack(grayLevel(dotMask, x: 50, y: 20)), "the dot does not leak upward")
    check(isBlack(grayLevel(dotMask, x: 20, y: 50)), "the dot does not leak sideways")

    // Erasing must carve the previous coverage back to black.
    let wipe = AIMaskStroke(points: [CGPoint(x: 0.5, y: 0.3), CGPoint(x: 0.5, y: 0.7)],
                            width: 0.2, erase: true)
    guard let erased = AIMaskRenderer.mask(size: size, strokes: [dot, wipe], box: nil,
                                           refined: nil, inverted: false) else {
        check(false, "erase mask renders")
        return
    }
    check(isBlack(grayLevel(erased, x: 50, y: 50)), "an erase stroke clears the dot")

    // Invert swaps what may change without moving anything else.
    guard let inverted = AIMaskRenderer.mask(size: size, strokes: [], box: box,
                                             refined: nil, inverted: true) else {
        check(false, "inverted mask renders")
        return
    }
    check(isBlack(grayLevel(inverted, x: 20, y: 15)), "invert clears the box")
    check(isWhite(grayLevel(inverted, x: 80, y: 80)), "invert fills the rest")

    guard let alpha = AIMaskRenderer.alphaMask(boxMask) else {
        check(false, "the preview alpha plane renders")
        return
    }
    check(alphaLevel(alpha, x: 20, y: 15) == 255, "the preview is opaque inside the box")
    check(alphaLevel(alpha, x: 80, y: 80) == 0, "the preview is clear outside the box")
}

@MainActor
func testQuickEditSelectionGating() async {
    print("\n[P3] Quick Edit needs a selection, and heal needs a mask")

    let url = workDir.appendingPathComponent("mask-gating.png")
    guard let image = makeImage(width: 640, height: 480), writePNG(image, to: url) else {
        check(false, "mask-gating fixture")
        return
    }
    let model = EditorModel()
    model.load(url: url)
    check(await waitUntil { model.hasImage && !model.isBusy }, "fixture loads")

    check(!model.canRunQuickEdit, "no run without a point or a mask")

    model.beginQuickEdit()
    check(model.isAIPicking, "begin starts picking")
    model.placeQuickEditPoint(CGPoint(x: 0.5, y: 0.5))
    check(model.canRunQuickEdit, "a point is enough for Remove object")
    check(model.aiMaskPreview == nil, "a point alone paints no mask")

    model.selectQuickEditPreset(.healArea)
    check(model.quickEditPoint == nil, "switching to heal drops the point")
    check(!model.canRunQuickEdit, "heal cannot run from a point")
    check(model.aiMaskTool == .brush, "heal selects the brush")

    model.selectAIMaskTool(.brush)
    model.appendMaskStroke(AIMaskStroke(
        points: [CGPoint(x: 0.4, y: 0.4), CGPoint(x: 0.6, y: 0.6)],
        width: 0.04, erase: false))
    check(model.canRunQuickEdit, "a stroke enables heal")
    check(model.aiMaskPreview != nil, "the stroke paints a preview")
    check(model.aiMaskPreview?.width == Int(model.previewSize.width),
          "the preview plane matches the preview size")

    model.aiMaskInverted = true
    check(model.aiMaskPreview != nil, "inverting keeps the preview")
    model.aiMaskInverted = false

    model.clearAIMask()
    check(!model.aiMaskHasSelection, "Clear empties the mask")
    check(!model.canRunQuickEdit, "Clear disables Run again")
    check(model.aiMaskPreview == nil, "Clear removes the preview")

    // Reimagine is the one preset that redraws the frame, so it must not be
    // held to the selection rule the other two live by.
    model.beginQuickEdit()
    model.placeQuickEditPoint(CGPoint(x: 0.5, y: 0.5))
    model.selectQuickEditPreset(.reimagine)
    check(model.quickEditPreset.isFullFrame && !model.quickEditPreset.needsSelection,
          "reimagine is a full-frame preset")
    check(model.quickEditPoint == nil && !model.isAIPicking,
          "switching to reimagine drops the point and the picking mode")
    check(model.canRunQuickEdit, "reimagine runs without a selection")
    model.selectQuickEditPreset(.removeObject)
    check(!model.canRunQuickEdit, "a masked preset still needs a selection")
}

/// A full-frame edit is one opaque layer over the whole frame: every pixel is
/// new, and undo still has to restore the earlier bytes exactly.
@MainActor
func testFullFrameReimagine() async {
    print("\n[P5] a full-frame edit covers the picture and undoes in one step")

    let url = workDir.appendingPathComponent("reimagine-source.png")
    guard let image = makeImage(width: 480, height: 600), writePNG(image, to: url) else {
        check(false, "reimagine fixture")
        return
    }
    let model = EditorModel()
    model.exportFormat = .png
    model.load(url: url)
    check(await waitUntil { model.hasImage && !model.isBusy }, "fixture loads")

    let baseURL = workDir.appendingPathComponent("reimagine-base.png")
    model.export(to: baseURL)
    check(await waitUntil(120) {
        FileManager.default.fileExists(atPath: baseURL.path) && !model.isBusy
    }, "baseline export finishes")

    guard let edit = storedAIEdit(box: CGRect(x: 0, y: 0, width: 1, height: 1), inset: 0)
    else {
        check(false, "the full-frame edit files are staged")
        return
    }
    defer { AIEditStore.remove(edit) }

    model.addAIEdit(edit)
    check(await waitUntil { !model.isBusy }, "the preview settles")

    let editedURL = workDir.appendingPathComponent("reimagine-edited.png")
    model.export(to: editedURL)
    check(await waitUntil(120) {
        FileManager.default.fileExists(atPath: editedURL.path) && !model.isBusy
    }, "edited export finishes")

    guard let base = readImage(baseURL), let edited = readImage(editedURL),
          let a = rgbaBytes(base), let b = rgbaBytes(edited) else {
        check(false, "both exports decode")
        return
    }
    let changed = zip(a, b).lazy.enumerated().filter { $0.offset % 4 != 3 && $0.element.0 != $0.element.1 }.count
    let total = 480 * 600 * 3
    check(Double(changed) > Double(total) * 0.9,
          "the edit reaches the whole frame", "\(changed) of \(total) channels")

    model.undo()
    check(model.aiEdits.isEmpty, "one undo removes the full-frame edit")
    let undoneURL = workDir.appendingPathComponent("reimagine-undone.png")
    model.export(to: undoneURL)
    check(await waitUntil(120) {
        FileManager.default.fileExists(atPath: undoneURL.path) && !model.isBusy
    }, "undone export finishes")
    if let undone = readImage(undoneURL).flatMap(rgbaBytes) {
        let diff = zip(a, undone).lazy.filter { $0 != $1 }.count
        check(diff == 0, "undo restores the whole frame exactly", "\(diff) bytes differ")
    } else {
        check(false, "the undone export decodes")
    }
}

// MARK: - runner

@MainActor
func testExportUpscalePolicy() async {
    print("\n[P4-1] the upscaler's limits match what the helper will accept")

    // Swin2SR is fixed at 4x and the helper refuses more than 40 MP out, so a
    // full pass is only offered up to 2.5 MP in. Both numbers live here so the
    // sheet can refuse in the same terms before a job is queued.
    check(ExportUpscale.factor == 4, "the pass is four times the pixels per axis")
    check(ExportUpscale.canHandle(CGSize(width: 1500, height: 1500)),
          "2.25 MP fits the 4x ceiling", "\(6000 * 6000) px out")
    check(!ExportUpscale.canHandle(CGSize(width: 1600, height: 1600)),
          "the first size past 2.5 MP is refused", "\(6400 * 6400) px out")
    check(ExportUpscale.canHandle(CGSize(width: 400, height: 300)),
          "a small photo is accepted")
    check(!ExportUpscale.canHandle(CGSize(width: 0, height: 300)),
          "an empty size is refused")

    check(ExportUpscale.outputLongEdge(sourceLong: 1000, requested: 4096) == 4000,
          "4x wins when the request is above it", "1000 -> 4000")
    check(ExportUpscale.outputLongEdge(sourceLong: 1000, requested: 2048) == 2048,
          "the requested edge wins below 4x", "1000 -> 2048")
    check(ExportUpscale.outputLongEdge(sourceLong: 1000, requested: nil) == 4000,
          "no request means the full 4x")
}

// MARK: - Orientation

@MainActor
func testOrientationKeepsEditsAttached() async {
    print("\n[R1] rotating and flipping keep every edit on its pixel")

    let sourceURL = workDir.appendingPathComponent("orientation-source.png")
    check(makeImage(width: 480, height: 600).map { writePNG($0, to: sourceURL) } ?? false,
          "fixture written")

    let model = EditorModel()
    model.load(url: sourceURL)
    check(await waitUntil { model.hasImage && !model.isBusy }, "fixture loads")
    check(model.workingPixelSize == CGSize(width: 480, height: 600), "starts portrait")

    model.tapHeal(at: CGPoint(x: 0.25, y: 0.25))
    model.tapArt(at: CGPoint(x: 0.75, y: 0.75))
    check(await waitUntil { !model.isBusy }, "stamp preview settles")

    model.cropDraft = CGRect(x: 0, y: 0, width: 0.5, height: 0.5)
    model.applyCrop()
    check(await waitUntil { !model.isBusy && model.appliedCrop != nil },
          "a top-left crop is applied")
    check(abs((model.appliedCrop?.width ?? 0) - 0.5) < 0.001, "the crop is the quarter asked for")

    model.rotateClockwise()
    check(await waitUntil { !model.isBusy && model.documentOrientation.quarterTurns == 1 },
          "the frame turns clockwise")
    check(model.workingPixelSize == CGSize(width: 300, height: 240),
          "the cropped working frame swapped sides", "\(model.workingPixelSize)")
    let turnedCrop = model.appliedCrop ?? .zero
    check(abs(turnedCrop.minX - 0.5) < 0.001 && abs(turnedCrop.minY) < 0.001
            && abs(turnedCrop.width - 0.5) < 0.001 && abs(turnedCrop.height - 0.5) < 0.001,
          "the top-left crop moved to the top-right", "\(turnedCrop)")
    let healed = model.healSpots.first?.center ?? .zero
    check(abs(healed.x - 0.75) < 0.001 && abs(healed.y - 0.25) < 0.001,
          "the healing stamp turned with the photo", "\(healed)")
    let art = model.stickers.first?.center ?? .zero
    check(abs(art.x - 0.25) < 0.001 && abs(art.y - 0.75) < 0.001,
          "the sticker turned with the photo", "\(art)")

    model.undo()
    check(await waitUntil { !model.isBusy && model.documentOrientation == .identity },
          "one undo puts the frame back")
    check(model.workingPixelSize == CGSize(width: 240, height: 300),
          "the cropped portrait frame is back")
    check(abs((model.healSpots.first?.center.x ?? 0) - 0.25) < 0.001,
          "the stamp is back on its original pixel")

    let radiusBefore = model.healSpots.first?.radius ?? 0
    model.setStraightenAngle(12)
    check(await waitUntil { !model.isBusy && abs(model.straightenAngle - 12) < 0.01 },
          "the straighten slider commits one turn")
    check(model.workingPixelSize == CGSize(width: 240, height: 300),
          "straighten keeps the frame size")
    let grownRadius = model.healSpots.first?.radius ?? 0
    check(radiusBefore > 0 && grownRadius > radiusBefore,
          "the stamp grows with the upscaled pixels", "\(radiusBefore) -> \(grownRadius)")

    model.undo()
    check(await waitUntil { !model.isBusy && model.documentOrientation == .identity },
          "undo removes the straighten")
}

@MainActor
func runAll() async {
    await testExportDoesNotSave()
    await testSmartKeepsUnmeasuredFields()
    await testResetAllClearsEverything()
    await testCropIsUndoable()
    await testOrientationKeepsEditsAttached()
    await testBatchMatchesSingleExport()
    await testProjectRelink()
    await testProjectVersionGuard()
    await testOperationCoordination()
    await testPreviewStaysAtPreviewResolution()
    await testPrivacySettingDefaults()
    await testAIEditBoundaries()
    await testAIProjectRoundTrip()
    await testAIEditUndoAndExport()
    await testAIMaskRenderer()
    await testQuickEditSelectionGating()
    await testFullFrameReimagine()
    await testExportUpscalePolicy()

    print("\n" + String(repeating: "-", count: 60))
    removeRecentEntries(under: workDir)
    try? FileManager.default.removeItem(at: workDir)
    if failures.isEmpty {
        print("MODEL TESTS: PASS")
        exit(0)
    } else {
        print("MODEL TESTS: FAIL (\(failures.count))")
        for failure in failures { print("   - \(failure)") }
        exit(1)
    }
}

Task { @MainActor in
    await runAll()
}
dispatchMain()