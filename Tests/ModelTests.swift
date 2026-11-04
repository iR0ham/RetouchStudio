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

// MARK: - runner

@MainActor
func runAll() async {
    await testExportDoesNotSave()
    await testSmartKeepsUnmeasuredFields()
    await testResetAllClearsEverything()
    await testCropIsUndoable()
    await testBatchMatchesSingleExport()

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