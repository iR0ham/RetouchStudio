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

// Every recovery write in this process goes to one scratch directory, including
// the delayed autosave tasks a model leaves behind. The override is set before
// the first model exists and is never changed again, so a task cannot follow a
// later test into a different directory. The production copy is only read for
// a fingerprint; the isolation test at the end proves it stayed byte-identical.
let recoveryRoot = workDir.appendingPathComponent("recovery", isDirectory: true)
try? FileManager.default.createDirectory(at: recoveryRoot, withIntermediateDirectories: true)
let productionRecoveryBefore = RecoveryFingerprint.capture(RecoveryStore.productionDirectory)
RecoveryStore.directoryOverride = recoveryRoot

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

/// A counter the batch's file task and the main-actor test can share.
final class LockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    func next() -> Int {
        lock.lock()
        defer { lock.unlock() }
        value += 1
        return value
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

// MARK: - P0-4

@MainActor
func testBatchExportPolicy() {
    print("\n[P0-4] a batch file keeps only the shared export settings")

    let documentURL = workDir.appendingPathComponent("policy-doc.png")
    let otherURL = workDir.appendingPathComponent("policy-other.png")
    let differentURL = workDir.appendingPathComponent("policy-wide.png")

    var analysis = AnalysisSettings()
    analysis.isEnabled = true
    analysis.regions = [.forehead, .texture]
    analysis.exportMode = .poster
    analysis.setEndpoint(CGPoint(x: 0.21, y: 0.32), for: .forehead)
    analysis.setAnchor(CGPoint(x: 0.42, y: 0.55), for: .forehead)

    var base = ExportSnapshot()
    base.adjustments.contrast = 30
    base.healSpots = [HealSpot(center: CGPoint(x: 0.5, y: 0.5), radius: 0.02)]
    base.stickers = [Sticker(center: CGPoint(x: 0.2, y: 0.2), size: 0.1)]
    base.aiEdits = [AIEdit(preset: "test", prompt: "p", seed: 1,
                           patchFile: "patch.png", alphaFile: "alpha.png",
                           box: CGRect(x: 0, y: 0, width: 1, height: 1),
                           imagePixels: CGSize(width: 10, height: 10))]
    base.analysis = analysis
    base.crop = CGRect(x: 0.1, y: 0.1, width: 0.8, height: 0.8)
    base.orientation = DocumentOrientation(quarterTurns: 1)
    base.selectedFaceIndex = 1
    base.format = .png
    base.quality = 0.8
    base.longEdge = 2048
    base.stripsPrivacyMetadata = true
    base.includeStamps = true
    base.includeAnalysis = true
    base.aiUpscale = true
    base.watermark = WatermarkSettings(enabled: true, text: "Studio")

    let document = BatchExportPolicy.snapshot(
        base, fileURL: documentURL, documentURL: documentURL,
        documentAspect: 4.0 / 3.0, fileAspect: 4.0 / 3.0)
    check(document.selectedFaceIndex == 1
            && document.analysis.endpoint(for: .forehead) != nil
            && document.analysis.anchor(for: .forehead) != nil
            && document.crop != nil && document.orientation.quarterTurns == 1
            && !document.aiEdits.isEmpty,
          "the open document keeps its own selection, pins and crop")

    let sameAspect = BatchExportPolicy.snapshot(
        base, fileURL: otherURL, documentURL: documentURL,
        documentAspect: 4.0 / 3.0, fileAspect: 4.0 / 3.0)
    check(sameAspect.selectedFaceIndex == nil && sameAspect.analysis.endpoints.isEmpty
            && sameAspect.analysis.anchors.isEmpty && sameAspect.aiEdits.isEmpty
            && sameAspect.orientation.isIdentity,
          "another same-shape file gets automatic focus and callouts")
    check(sameAspect.crop == nil,
          "a turned document's crop does not leak into another photo")

    var unrotatedBase = base
    unrotatedBase.orientation = .identity
    let unrotatedSameAspect = BatchExportPolicy.snapshot(
        unrotatedBase, fileURL: otherURL, documentURL: documentURL,
        documentAspect: 4.0 / 3.0, fileAspect: 4.0 / 3.0)
    check(unrotatedSameAspect.crop == unrotatedBase.crop,
          "an unturned document's crop travels to a same-shape file")
    check(sameAspect.adjustments == base.adjustments && sameAspect.format == base.format
            && sameAspect.quality == base.quality && sameAspect.longEdge == base.longEdge
            && sameAspect.stripsPrivacyMetadata == base.stripsPrivacyMetadata
            && sameAspect.watermark == base.watermark && sameAspect.aiUpscale == base.aiUpscale
            && sameAspect.includeStamps == base.includeStamps
            && sameAspect.includeAnalysis == base.includeAnalysis,
          "shared look, format and privacy settings are unchanged")
    check(sameAspect.analysis.isEnabled && sameAspect.analysis.exportMode == .poster
            && sameAspect.analysis.regions == base.analysis.regions,
          "the analysis style stays shared, only the pins are cleared")

    let differentAspect = BatchExportPolicy.snapshot(
        base, fileURL: differentURL, documentURL: documentURL,
        documentAspect: 4.0 / 3.0, fileAspect: 1.0)
    check(differentAspect.crop == nil, "a different-shape file exports whole")

    // Zero, one and three faces all get automatic focus; the policy never
    // depends on how many faces the other file actually has.
    for count in [3, 1, 0] {
        let faces = (0..<count).map { index in
            FaceGeometry.synthetic(boundingBox: CGRect(x: 0.05 + Double(index) * 0.25,
                                                       y: 0.2, width: 0.2, height: 0.3))
        }
        let snapshot = BatchExportPolicy.snapshot(
            base, fileURL: otherURL, documentURL: documentURL,
            documentAspect: 4.0 / 3.0, fileAspect: 4.0 / 3.0)
        check(snapshot.selectedFaceIndex == nil && snapshot.analysis.endpoints.isEmpty
                && snapshot.analysis.anchors.isEmpty,
              "a file with \(count) faces still uses automatic focus",
              "faces \(faces.count)")
    }

    // The renderer guards an out-of-range index; the policy must not leak it.
    var invalid = base
    invalid.selectedFaceIndex = 99
    let invalidDocument = BatchExportPolicy.snapshot(
        invalid, fileURL: documentURL, documentURL: documentURL,
        documentAspect: 4.0 / 3.0, fileAspect: 4.0 / 3.0)
    let invalidOther = BatchExportPolicy.snapshot(
        invalid, fileURL: otherURL, documentURL: documentURL,
        documentAspect: 4.0 / 3.0, fileAspect: 4.0 / 3.0)
    check(invalidDocument.selectedFaceIndex == 99 && invalidOther.selectedFaceIndex == nil,
          "an out-of-range selection stays with the document and never leaks")
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

@MainActor
func testBatchKeepsCropAfterQuarterTurn() async {
    print("\n[P1-1b] a turned document keeps its own crop in a batch")

    let docURL = workDir.appendingPathComponent("turn-doc.png")
    let squareURL = workDir.appendingPathComponent("turn-square.png")
    guard let docImage = makeImage(width: 800, height: 600),
          let squareImage = makeImage(width: 600, height: 600),
          writePNG(docImage, to: docURL), writePNG(squareImage, to: squareURL) else {
        check(false, "turn fixtures")
        return
    }

    // 800×600 cropped by half is a 400×300 frame; a quarter turn swaps it to
    // roughly 300×400 (the crop edges are integral pixels, so the height can
    // differ by one).
    for (label, clockwise, expectedTurns) in [("90°", true, 1), ("270°", false, 3)] {
        let model = EditorModel()
        model.load(url: docURL)
        check(await waitUntil { model.hasImage && !model.isBusy },
              "\(label): document loads")

        model.cropDraft = CGRect(x: 0.1, y: 0.1, width: 0.5, height: 0.5)
        model.applyCrop()
        check(await waitUntil { !model.isBusy && model.appliedCrop != nil },
              "\(label): crop applies")

        if clockwise {
            model.rotateClockwise()
        } else {
            model.rotateCounterClockwise()
        }
        check(await waitUntil(30) {
            !model.isBusy && model.documentOrientation.quarterTurns == expectedTurns
                && model.workingPixelSize.width == 300
        }, "\(label): the document turns and re-crops",
        "\(model.workingPixelSize.width)×\(model.workingPixelSize.height)")

        model.exportFormat = .png
        let singleURL = workDir.appendingPathComponent("turn-\(expectedTurns)-single.png")
        model.export(to: singleURL)
        check(await waitUntil(120) {
            FileManager.default.fileExists(atPath: singleURL.path) && !model.isBusy
        }, "\(label): single export finishes")

        let folder = workDir.appendingPathComponent("turn-\(expectedTurns)-batch")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        model.runBatch([docURL, squareURL], to: folder)
        check(await waitUntil(180) { !model.isBatchRunning && model.batchHasReport },
              "\(label): batch finishes")
        check(model.batchSavedCount == 2 && model.batchSkippedCrops == 1,
              "\(label): the document is saved and only the square skips the crop",
              "saved \(model.batchSavedCount), skipped \(model.batchSkippedCrops)")

        let docOut = folder.appendingPathComponent("turn-doc-retouched.png")
        if let dims = readImage(docOut), let singleDims = readImage(singleURL) {
            check(dims.width == singleDims.width && dims.height == singleDims.height
                    && dims.width == 300,
                  "\(label): the batch keeps the turned crop",
                  "\(dims.width)×\(dims.height) vs single \(singleDims.width)×\(singleDims.height)")
        } else {
            check(false, "\(label): batch output reads back")
        }

        if let delta = meanDelta(singleURL, docOut) {
            check(delta < 1.0, "\(label): batch pixels match the single export",
                  String(format: "mean delta %.3f/255", delta))
        } else {
            check(false, "\(label): batch pixels comparable")
        }

        let squareOut = folder.appendingPathComponent("turn-square-retouched.png")
        if let squareDims = readImage(squareOut) {
            check(squareDims.width == 600 && squareDims.height == 600,
                  "\(label): a different-shape file still exports whole",
                  "\(squareDims.width)×\(squareDims.height)")
        } else {
            check(false, "\(label): square output reads back")
        }
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

// MARK: - P1-8

@MainActor
func testBatchCancellationStopsInFlightFile() async {
    print("\n[P1-8] cancelling a batch stops the file in flight before it writes")

    let prefix = "cancel-\(UUID().uuidString.prefix(8))"
    let documentURL = workDir.appendingPathComponent("\(prefix)-doc.png")
    let firstURL = workDir.appendingPathComponent("\(prefix)-first.png")
    let secondURL = workDir.appendingPathComponent("\(prefix)-second.png")
    guard let image = makeImage(width: 480, height: 600),
          writePNG(image, to: documentURL),
          writePNG(image, to: firstURL),
          writePNG(image, to: secondURL) else {
        check(false, "cancellation fixtures")
        return
    }

    let model = EditorModel()
    model.load(url: documentURL)
    check(await waitUntil { model.hasImage && !model.isBusy }, "document loads")
    model.exportFormat = .png

    let folder = workDir.appendingPathComponent("batch-cancel-\(prefix)")
    try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

    // The hook pauses the second file immediately before its write, which is
    // the only moment where a cancellation can land after the render and still
    // leave nothing behind.
    let reached = DispatchSemaphore(value: 0)
    let release = DispatchSemaphore(value: 0)
    let writes = LockedCounter()
    model.batchFileWillWriteHook = { _ in
        guard writes.next() == 2 else { return }
        reached.signal()
        _ = release.wait(timeout: .now() + 30)
    }

    model.runBatch([firstURL, secondURL], to: folder)
    let stopped = await waitUntil(120) { reached.wait(timeout: .now()) == .success }
    check(stopped, "the batch reaches the second file just before writing")
    model.cancelBatchExport()
    release.signal()
    check(await waitUntil(120) { !model.isBatchRunning && model.batchHasReport },
          "the cancelled batch finishes promptly")

    check(model.statusToken == .batchCancelled, "the status reports the cancellation",
          "\(model.statusToken)")
    check(model.batchSavedCount == 1, "the finished first file still counts",
          "\(model.batchSavedCount)")
    let firstOut = folder.appendingPathComponent("\(prefix)-first-retouched.png")
    let secondOut = folder.appendingPathComponent("\(prefix)-second-retouched.png")
    check(readImage(firstOut) != nil, "the first output is complete and readable")
    check(!FileManager.default.fileExists(atPath: secondOut.path),
          "the cancelled second file wrote nothing")
    let leftovers = (try? FileManager.default.contentsOfDirectory(atPath: folder.path))?
        .filter { $0.hasSuffix(".tmp") || $0.hasSuffix(".part") } ?? []
    check(leftovers.isEmpty, "no temporary files remain", leftovers.joined(separator: ", "))

    // The model must run normally again once the cancellation has been cleared.
    model.batchFileWillWriteHook = nil
    let again = workDir.appendingPathComponent("batch-after-cancel-\(prefix)")
    try? FileManager.default.createDirectory(at: again, withIntermediateDirectories: true)
    model.runBatch([firstURL], to: again)
    check(await waitUntil(180) { !model.isBatchRunning && model.batchHasReport },
          "a batch runs normally after a cancellation")
    check(model.batchSavedCount == 1
            && model.statusToken == .batchFinished(saved: 1, total: 1, cropsSkipped: 0),
          "the later batch saved its file", "\(model.statusToken)")
}

// MARK: - P1-8 write failure

@MainActor
func testBatchWriteFailureIsNotCounted() async {
    print("\n[P1-8] a failed write is not counted as a saved photo")

    let prefix = "writefail-\(UUID().uuidString.prefix(8))"
    let documentURL = workDir.appendingPathComponent("\(prefix)-doc.png")
    let firstURL = workDir.appendingPathComponent("\(prefix)-first.png")
    let secondURL = workDir.appendingPathComponent("\(prefix)-second.png")
    guard let image = makeImage(width: 480, height: 600),
          writePNG(image, to: documentURL),
          writePNG(image, to: firstURL),
          writePNG(image, to: secondURL) else {
        check(false, "write-failure fixtures")
        return
    }

    let model = EditorModel()
    model.load(url: documentURL)
    check(await waitUntil { model.hasImage && !model.isBusy }, "document loads")
    model.exportFormat = .png

    let folder = workDir.appendingPathComponent("batch-writefail-\(prefix)")
    try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

    // The first file uses the real writer; the second reaches the same write
    // stage and reports failure. A load or render failure would not prove that
    // a failed write is kept out of the saved count.
    let writes = LockedCounter()
    model.batchFileWriteResultOverride = { _ in
        writes.next() == 1 ? nil : false
    }

    model.runBatch([firstURL, secondURL], to: folder)
    check(await waitUntil(180) { !model.isBatchRunning && model.batchHasReport },
          "batch finishes")
    check(writes.next() == 3, "both files reached the write stage")

    check(model.batchSavedCount == 1, "the failed write is not counted",
          "\(model.batchSavedCount)")
    check(model.batchCompleted == 2,
          "the failed file still finishes its turn", "\(model.batchCompleted)")
    check(model.statusToken == .batchFinished(saved: 1, total: 2, cropsSkipped: 0),
          "the report says one of two was saved", "\(model.statusToken)")

    let firstOut = folder.appendingPathComponent("\(prefix)-first-retouched.png")
    let secondOut = folder.appendingPathComponent("\(prefix)-second-retouched.png")
    check(readImage(firstOut) != nil, "the real write produced a readable file")
    check(!FileManager.default.fileExists(atPath: secondOut.path),
          "the failed write produced no file")
    let leftovers = (try? FileManager.default.contentsOfDirectory(atPath: folder.path))?
        .filter { $0.hasSuffix(".tmp") || $0.hasSuffix(".part") } ?? []
    check(leftovers.isEmpty, "no temporary files remain", leftovers.joined(separator: ", "))

    // A later batch is unaffected once the test override is gone.
    model.batchFileWriteResultOverride = nil
    let again = workDir.appendingPathComponent("batch-after-writefail-\(prefix)")
    try? FileManager.default.createDirectory(at: again, withIntermediateDirectories: true)
    model.runBatch([firstURL], to: again)
    check(await waitUntil(180) { !model.isBatchRunning && model.batchHasReport },
          "a batch runs normally after a failed write")
    check(model.batchSavedCount == 1
            && model.statusToken == .batchFinished(saved: 1, total: 1, cropsSkipped: 0),
          "the later batch saved its file", "\(model.statusToken)")
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

// MARK: - M-12

/// An analysis export is lines over a face. With no face there is nothing to
/// draw, so the suggested name must not promise an analysis artifact.
@MainActor
func testAnalysisExportNeedsFace() async {
    print("\n[M-12] the analysis export waits for a detected face")

    let model = EditorModel()
    model.analysis.isEnabled = true
    model.analysis.exportMode = .overlayOnly
    model.exportFormat = .jpeg

    check(model.faces.isEmpty, "no faces before a photo is open")
    let name = model.suggestedFileName()
    check(!name.lowercased().contains("analysis"),
          "the suggested name does not promise analysis", name)
    check(name.hasSuffix(".\(model.exportFormat.fileExtension)"),
          "the ordinary format is kept without a face", name)
}

// MARK: - Milestone 1: data integrity

struct RuntimeTestFailure: Error {}

/// Counts how many times a test hook may still reject a path. A rollback
/// validates the restored copy through the same hook, so a rejection must be
/// one-shot to model a bad new runtime rather than a broken hook.
final class RuntimeVerifyPlan {
    let root: URL
    var armed = false
    var remainingRejections: Int

    init(root: URL, rejections: Int = 1) {
        self.root = root
        self.remainingRejections = rejections
    }

    func shouldReject(_ candidate: URL) -> Bool {
        guard armed, remainingRejections > 0,
              candidate.standardizedFileURL == root.standardizedFileURL else { return false }
        remainingRejections -= 1
        if remainingRejections == 0 { armed = false }
        return true
    }
}

func fileBytes(_ url: URL) -> Data? {
    try? Data(contentsOf: url)
}

/// A fixture that passes the structural contract. It is not a real Python, so
/// tests replace the functional hook; this keeps the transaction tests offline
/// and bounded while still exercising the layout the real runtime must have.
func makeFakeRuntime(at root: URL, marker: String) throws {
    let manager = FileManager.default
    try manager.createDirectory(at: root.appendingPathComponent("bin"),
                                withIntermediateDirectories: true)
    let python = root.appendingPathComponent("bin/python3")
    try Data("#!/bin/sh\nexit 0\n".utf8).write(to: python)
    try manager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: python.path)
    let worker = root.appendingPathComponent("retouch_ai_worker", isDirectory: true)
    try manager.createDirectory(at: worker, withIntermediateDirectories: true)
    for name in ["__main__.py", "server.py", "engine.py"] {
        try Data("# fake\n".utf8).write(to: worker.appendingPathComponent(name))
    }
    try manager.createDirectory(at: root.appendingPathComponent("site-packages",
                                                                isDirectory: true),
                                withIntermediateDirectories: true)
    try manager.createDirectory(
        at: root.appendingPathComponent("Python.framework/Versions/3.13",
                                        isDirectory: true),
        withIntermediateDirectories: true)
    try Data(marker.utf8).write(to: root.appendingPathComponent("marker.txt"))
}

/// Install hooks for fixture runtimes: extraction comes from the test, the
/// structural contract is the real one, and the functional stage is stubbed
/// unless the test supplies its own decision.
func fakeRuntimeHooks(
    extract: @escaping (URL, URL) throws -> Void,
    functional: ((URL) -> RuntimeValidationReport)? = nil
) -> AIRuntime.InstallHooks {
    var hooks = AIRuntime.InstallHooks()
    hooks.extract = extract
    hooks.validateRuntime = { root in
        if let functional { return functional(root) }
        let layout = AIRuntimeValidation.structural(root: root)
        guard layout.ok else { return layout }
        return RuntimeValidationReport.success(.functional)
    }
    return hooks
}

func recoveryHooks(
    functional: ((URL) -> RuntimeValidationReport)? = nil
) -> AIRuntime.InstallHooks {
    fakeRuntimeHooks(extract: { _, _ in throw RuntimeTestFailure() },
                     functional: functional)
}

/// Writes a durable marker exactly as the transaction would, for recovery tests
/// that start from a state a crash left behind.
func writeTransactionMarker(in support: URL, id: String, state: String,
                            hadPrevious: Bool, extra: [String: Any] = [:]) throws {
    var object: [String: Any] = [
        "id": id,
        "state": state,
        "had_previous": hadPrevious,
        "created": "2026-11-10T00:00:00Z",
    ]
    for (key, value) in extra { object[key] = value }
    let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    try data.write(to: support.appendingPathComponent("runtime-transaction.json"),
                   options: .atomic)
}

func transactionMarker(in support: URL) -> [String: Any]? {
    let url = support.appendingPathComponent("runtime-transaction.json")
    guard let data = try? Data(contentsOf: url) else { return nil }
    return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
}

func transactionState(in support: URL) -> String? {
    transactionMarker(in: support)?["state"] as? String
}

func hasBackupDirectory(in support: URL) -> Bool {
    FileManager.default.fileExists(atPath: AIRuntime.backupDirectory(in: support).path)
}

func hasRejectedDirectory(in support: URL) -> Bool {
    let prefix = AIRuntime.installDirectory(in: support).lastPathComponent + "-rejected-"
    let entries = (try? FileManager.default.contentsOfDirectory(
        at: support, includingPropertiesForKeys: nil)) ?? []
    return entries.contains { $0.lastPathComponent.hasPrefix(prefix) }
}

func copyContents(of source: URL, into destination: URL) throws {
    let manager = FileManager.default
    for item in try manager.contentsOfDirectory(at: source,
                                                 includingPropertiesForKeys: nil) {
        try manager.copyItem(at: item,
                             to: destination.appendingPathComponent(item.lastPathComponent))
    }
}

func marker(at root: URL) -> String? {
    guard let data = try? Data(contentsOf: root.appendingPathComponent("marker.txt"))
    else { return nil }
    return String(data: data, encoding: .utf8)
}

func hasStagingDirectory(in support: URL) -> Bool {
    let manager = FileManager.default
    let prefix = AIRuntime.installDirectory(in: support).lastPathComponent + "-installing-"
    let entries = (try? manager.contentsOfDirectory(at: support,
                                                     includingPropertiesForKeys: nil)) ?? []
    return entries.contains { $0.lastPathComponent.hasPrefix(prefix) }
}

/// The production recovery copy's identity, captured before the suite starts
/// and compared at the end. Reading it is safe; nothing here writes to it.
struct RecoveryFingerprint: Equatable {
    let exists: Bool
    let size: Int?
    let modified: Date?
    let hash: String?

    static func capture(_ directory: URL) -> RecoveryFingerprint {
        let url = directory.appendingPathComponent("session.retouch")
        let manager = FileManager.default
        guard manager.fileExists(atPath: url.path) else {
            return RecoveryFingerprint(exists: false, size: nil, modified: nil, hash: nil)
        }
        let attributes = try? manager.attributesOfItem(atPath: url.path)
        return RecoveryFingerprint(
            exists: true,
            size: (attributes?[.size] as? NSNumber)?.intValue,
            modified: attributes?[.modificationDate] as? Date,
            hash: try? AIRuntime.sha256(of: url))
    }
}

/// The model debounces a recovery write by 1.5 s. A task from the previous
/// test can otherwise land in the middle of this one, so wait past the
/// debounce, then clear the scratch copy before installing a fixture.
@MainActor
func settleRecoveryWrites() async {
    try? await Task.sleep(nanoseconds: 1_800_000_000)
    RecoveryStore.clear()
}

@MainActor
func testRecoveryCancelPreservesData() async {
    print("\n[M1-R] recovery survives cancel, Escape, close and a cancelled Locate")

    await settleRecoveryWrites()

    let settings = AppSettings.shared
    let previousRecoverySetting = settings.recoveryEnabled
    settings.recoveryEnabled = true
    defer { settings.recoveryEnabled = previousRecoverySetting }

    let source = workDir.appendingPathComponent("recovery-photo.png")
    check(makeImage(width: 320, height: 400).map { writePNG($0, to: source) } ?? false,
          "recovery fixture written")

    let project = RetouchProject(imagePath: source.path,
                                 adjustments: Adjustments(),
                                 exportFormat: "png",
                                 exportQuality: 0.92,
                                 autoRetouchStrength: 70)
    check(RecoveryStore.write(project), "recovery copy written")

    // Escape and a closed alert both arrive as .abort. Only the explicit
    // third button may be destructive.
    check(EditorModel.missingSourceChoice(for: .abort) == .cancel,
          "Escape/close on the Locate prompt cancels")
    check(EditorModel.restoreChoice(for: .abort) == .cancel,
          "Escape/close on the Restore prompt cancels")
    check(EditorModel.missingSourceChoice(for: .alertSecondButtonReturn) == .cancel,
          "the Cancel button on the Locate prompt cancels")
    check(EditorModel.restoreChoice(for: .alertSecondButtonReturn) == .cancel,
          "the Cancel button on the Restore prompt cancels")
    check(EditorModel.missingSourceChoice(for: .alertThirdButtonReturn) == .discard,
          "the explicit Discard response is recognized")
    check(EditorModel.restoreChoice(for: .alertThirdButtonReturn) == .discard,
          "the explicit Discard response is recognized")

    var prompts = 0
    let cancelModel = EditorModel()
    cancelModel.recoveryChoiceHandler = { _, _ in
        prompts += 1
        return .cancel
    }
    cancelModel.offerRecoveryIfNeeded()
    check(RecoveryStore.read() != nil, "Cancel keeps recovery data")
    check(prompts == 1, "recovery prompt shown once", "\(prompts)")
    cancelModel.offerRecoveryIfNeeded()
    check(prompts == 1, "recovery prompt does not repeat in one session", "\(prompts)")

    let missing = workDir.appendingPathComponent("recovery-missing.png")
    let relocated = workDir.appendingPathComponent("recovery-relocated.png")
    check(makeImage(width: 320, height: 400).map { writePNG($0, to: relocated) } ?? false,
          "relocated fixture written")
    let missingProject = RetouchProject(imagePath: missing.path,
                                        adjustments: Adjustments(),
                                        exportFormat: "png",
                                        exportQuality: 0.92,
                                        autoRetouchStrength: 70)
    check(RecoveryStore.write(missingProject), "missing-photo recovery written")
    var locatePrompts = 0
    var restorePrompts = 0
    let locateModel = EditorModel()
    locateModel.recoveryChoiceHandler = { missingSource, _ in
        if missingSource { locatePrompts += 1 } else { restorePrompts += 1 }
        return missingSource ? .locate : .cancel
    }
    locateModel.recoveryLocateHandler = { _ in relocated }
    locateModel.offerRecoveryIfNeeded()
    check(RecoveryStore.read() != nil, "cancelled Locate keeps recovery data")
    check(RecoveryStore.read()?.imagePath == missing.path,
          "Locate then Cancel keeps the original recovery path")
    check(locatePrompts == 1, "Locate prompt shown once", "\(locatePrompts)")
    check(restorePrompts == 1, "a successful Locate is followed by the Restore prompt",
          "\(restorePrompts)")

    check(RecoveryStore.write(project), "recovery copy rewritten for discard")
    let discardModel = EditorModel()
    discardModel.recoveryChoiceHandler = { _, _ in .discard }
    discardModel.offerRecoveryIfNeeded()
    check(RecoveryStore.read() == nil, "explicit Discard deletes recovery data")
}

@MainActor
func testRecoveryRestoresAfterSimulatedRelaunch() async {
    print("\n[M1-R2] recovery survives a simulated relaunch and restores the document")

    await settleRecoveryWrites()

    let settings = AppSettings.shared
    let previousRecoverySetting = settings.recoveryEnabled
    settings.recoveryEnabled = true
    defer { settings.recoveryEnabled = previousRecoverySetting }

    let source = workDir.appendingPathComponent("relaunch-photo.png")
    check(makeImage(width: 320, height: 400).map { writePNG($0, to: source) } ?? false,
          "relaunch fixture written")
    let project = RetouchProject(imagePath: source.path,
                                 adjustments: Adjustments(),
                                 exportFormat: "png",
                                 exportQuality: 0.92,
                                 autoRetouchStrength: 70)
    check(RecoveryStore.write(project), "recovery copy written")

    // Simulated relaunch: a new model and a new session flag. This proves the
    // file survives a terminated process; it is not a real crash test.
    check(RecoveryStore.read() != nil, "recovery data survives the simulated termination")
    let restored = EditorModel()
    restored.recoveryChoiceHandler = { missingSource, _ in
        missingSource ? .cancel : .restore
    }
    restored.offerRecoveryIfNeeded()
    check(await waitUntil(60) { restored.hasImage && !restored.isBusy },
          "document restored on the next launch")
    check(restored.imageName == source.lastPathComponent,
          "restored document keeps the photo name", restored.imageName)
    check(restored.imageURL?.standardizedFileURL == source.standardizedFileURL,
          "restored document keeps the photo URL")
}

@MainActor
func testRecoveryLocatePathWaitsForRestore() async {
    print("\n[M1-R3] a located path is recorded only after Restore")

    await settleRecoveryWrites()

    let settings = AppSettings.shared
    let previousRecoverySetting = settings.recoveryEnabled
    settings.recoveryEnabled = true
    defer { settings.recoveryEnabled = previousRecoverySetting }

    let missing = workDir.appendingPathComponent("locate-missing.png")
    let actual = workDir.appendingPathComponent("locate-actual.png")
    check(makeImage(width: 320, height: 400).map { writePNG($0, to: actual) } ?? false,
          "located fixture written")

    var adjustments = Adjustments()
    adjustments.exposure = 0.4
    let project = RetouchProject(imagePath: missing.path,
                                 adjustments: adjustments,
                                 exportFormat: "png",
                                 exportQuality: 0.92,
                                 autoRetouchStrength: 70)
    check(RecoveryStore.write(project), "missing-path recovery written")

    var prompts: [Bool] = []
    let model = EditorModel()
    model.recoveryChoiceHandler = { missingSource, _ in
        prompts.append(missingSource)
        return missingSource ? .locate : .restore
    }
    model.recoveryLocateHandler = { _ in actual }
    model.offerRecoveryIfNeeded()
    check(prompts == [true, false], "Locate is followed by the Restore prompt")
    check(RecoveryStore.read()?.imagePath == missing.path,
          "the recovery path is untouched before the Restore answer")
    check(await waitUntil(60) { model.hasImage && !model.isBusy },
          "the located photo restores")
    check(await waitUntil(10) { RecoveryStore.read()?.imagePath == actual.path },
          "the recovery path is updated after Restore")
}

@MainActor
func testFailedLoadPreservesDocument() async {
    print("\n[M1-L] a failed open leaves the current document intact")

    let good = workDir.appendingPathComponent("failedload-good.png")
    check(makeImage(width: 400, height: 500).map { writePNG($0, to: good) } ?? false,
          "good fixture written")
    let bad = workDir.appendingPathComponent("failedload-bad.png")
    check((try? Data("not an image".utf8).write(to: bad)) != nil, "corrupt fixture written")

    let model = EditorModel()
    model.load(url: good)
    check(await waitUntil { model.hasImage && !model.isBusy }, "good fixture loads")
    model.adjustments.smooth = 30
    check(model.adjustments.smooth == 30, "an edit is made before the failed open")
    check(model.canUndo, "the edit is in the undo history")
    let name = model.imageName
    let url = model.imageURL
    let suggested = model.suggestedFileName()
    let title = model.windowTitle

    model.load(url: bad)
    check(await waitUntil { model.status == L10n.current.couldNotRead },
          "the failure is reported")
    check(model.hasImage, "the previous image remains open")
    check(model.imageName == name, "the previous name remains", model.imageName)
    check(model.imageURL == url, "the previous URL remains")
    check(model.adjustments.smooth == 30, "the previous adjustments remain")
    check(model.canUndo, "the previous undo history remains")
    check(model.suggestedFileName() == suggested,
          "the export name still describes the previous photo")
    check(model.windowTitle == title, "the title still describes the previous photo")
    model.undo()
    check(model.adjustments.smooth == 0, "undo still reaches the edit made before the failure")

    let empty = EditorModel()
    empty.load(url: bad)
    check(await waitUntil { empty.status == L10n.current.couldNotRead },
          "the failure is reported with no document")
    check(!empty.hasImage, "the failed image does not become the document")
    check(empty.imageName.isEmpty, "the failed image does not become the title")
    check(empty.imageURL == nil, "the failed image does not become the URL")
    check(empty.windowTitle == L10n.current.appName, "the window keeps the app title")
    check(!empty.suggestedFileName().contains("failedload-bad"),
          "the suggested export name does not use the failed file")
}

@MainActor
func testExportProtectsSource() async {
    print("\n[M1-X] export refuses the source path and every alias")

    let source = workDir.appendingPathComponent("export-source.png")
    check(makeImage(width: 480, height: 600).map { writePNG($0, to: source) } ?? false,
          "source fixture written")
    guard let before = fileBytes(source) else {
        check(false, "source bytes are readable")
        return
    }

    let model = EditorModel()
    model.load(url: source)
    model.exportFormat = .png
    check(await waitUntil { model.hasImage && !model.isBusy }, "source fixture loads")

    model.export(to: source)
    check(!model.isBusy, "same-path export is refused before rendering")
    check(model.status == L10n.current.exportRefusedOriginal,
          "the same-path refusal is reported", model.status)
    check(fileBytes(source) == before, "the source is unchanged after the same-path refusal")

    let symlink = workDir.appendingPathComponent("export-symlink.png")
    try? FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: source)
    model.export(to: symlink)
    check(!model.isBusy, "the symlink alias is refused before rendering")
    check(fileBytes(source) == before, "the source is unchanged after the symlink refusal")

    let hardlink = workDir.appendingPathComponent("export-hardlink.png")
    let linked = (try? FileManager.default.linkItem(at: source, to: hardlink)) != nil
    if linked {
        model.export(to: hardlink)
        check(!model.isBusy, "the hard-link alias is refused before rendering")
        check(fileBytes(source) == before, "the source is unchanged after the hard-link refusal")
    } else {
        print("  · hard links are not available here; NOT RUN")
    }

    // The writer itself refuses too: this is the check immediately before the
    // replace, independent of the UI's early check.
    if let image = makeImage(width: 32, height: 32) {
        let rendered = RenderedExport(image: CIImage(cgImage: image),
                                      carriesSourceMetadata: false)
        var snapshot = ExportSnapshot()
        snapshot.format = .png
        let direct = ExportService.writeResult(rendered, snapshot: snapshot, to: source,
                                               colorSpace: sRGB, metadata: [:],
                                               protecting: source)
        check(direct == .refusedOriginal, "the writer refuses the source at commit time")
        let directAlias = ExportService.writeResult(rendered, snapshot: snapshot, to: symlink,
                                                    colorSpace: sRGB, metadata: [:],
                                                    protecting: source)
        check(directAlias == .refusedOriginal, "the writer refuses a symlink at commit time")
        if linked {
            let directHardlink = ExportService.writeResult(rendered, snapshot: snapshot,
                                                           to: hardlink, colorSpace: sRGB,
                                                           metadata: [:], protecting: source)
            check(directHardlink == .refusedOriginal,
                  "the writer refuses a hard link at commit time")
        }
    }

    let valid = workDir.appendingPathComponent("export-valid.png")
    model.export(to: valid)
    check(await waitUntil(120) {
        FileManager.default.fileExists(atPath: valid.path) && !model.isBusy
    }, "a valid destination still exports")
    check(fileBytes(source) == before, "the source is unchanged after a valid export")
}

@MainActor
func testBatchDoesNotOverwriteSource() async {
    print("\n[M1-B] batch output cannot replace a source image")

    let source = workDir.appendingPathComponent("batch-source.png")
    check(makeImage(width: 480, height: 600).map { writePNG($0, to: source) } ?? false,
          "batch source written")
    guard let before = fileBytes(source) else {
        check(false, "batch source bytes are readable")
        return
    }

    let model = EditorModel()
    model.load(url: source)
    model.exportFormat = .png
    check(await waitUntil { model.hasImage && !model.isBusy }, "batch source loads")

    model.runBatch([source], to: workDir)
    check(await waitUntil(120) {
        !model.isBatchRunning && model.batchCompleted == 1
    }, "batch finishes")
    check(fileBytes(source) == before,
          "the batch leaves the source byte-for-byte unchanged")
    check(model.batchSavedCount == 1, "the batch saves a distinct output",
          "\(model.batchSavedCount)")

    let entries = (try? FileManager.default.contentsOfDirectory(
        at: workDir, includingPropertiesForKeys: nil)) ?? []
    check(entries.contains { $0.lastPathComponent.hasPrefix("batch-source-retouched") },
          "the batch output exists under a different name")
}

@MainActor
func testRuntimeTransactionalInstall() {
    print("\n[M1-AI] runtime installation is transactional")

    let manager = FileManager.default
    let oldFixture = workDir.appendingPathComponent("runtime-old-\(UUID().uuidString)")
    let newFixture = workDir.appendingPathComponent("runtime-new-\(UUID().uuidString)")
    do {
        try makeFakeRuntime(at: oldFixture, marker: "old")
        try makeFakeRuntime(at: newFixture, marker: "new")
    } catch {
        check(false, "runtime fixtures written", "\(error)")
        return
    }

    func makeSupport(_ label: String) -> URL {
        let url = workDir.appendingPathComponent("runtime-\(label)-\(UUID().uuidString)",
                                                isDirectory: true)
        try? manager.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    func seedLive(_ support: URL, _ fixture: URL) {
        let install = AIRuntime.installDirectory(in: support)
        try? manager.createDirectory(at: install, withIntermediateDirectories: true)
        try? copyContents(of: fixture, into: install)
    }
    func extractNew(_ archive: URL, _ staging: URL) throws {
        try copyContents(of: newFixture, into: staging)
    }

    // A. A first install has no previous runtime to protect.
    let firstSupport = makeSupport("first")
    do {
        try AIRuntime.install(archive: newFixture, support: firstSupport,
                              hooks: fakeRuntimeHooks(extract: extractNew))
        let install = AIRuntime.installDirectory(in: firstSupport)
        check(AIRuntime.isStructurallyValid(root: install), "A: a first install lands")
        check(marker(at: install) == "new", "A: the first install is the new runtime")
        check(transactionState(in: firstSupport) == "committed",
              "A: the marker records a committed install")
        check(!hasBackupDirectory(in: firstSupport), "A: no backup after a first install")
        check(!hasStagingDirectory(in: firstSupport), "A: no staging after a first install")
    } catch {
        check(false, "A: first install", "\(error)")
    }

    // B. Replacing a runtime: the old copy is a backup until the new one has
    // passed the full contract.
    let replaceSupport = makeSupport("replace")
    seedLive(replaceSupport, oldFixture)
    do {
        try AIRuntime.install(archive: newFixture, support: replaceSupport,
                              hooks: fakeRuntimeHooks(extract: extractNew))
        let install = AIRuntime.installDirectory(in: replaceSupport)
        check(marker(at: install) == "new", "B: a replacement installs the new runtime")
        check(transactionState(in: replaceSupport) == "committed",
              "B: the replacement is committed")
        check(!hasBackupDirectory(in: replaceSupport),
              "B: the old runtime is deleted only after the new one is committed")
        check(!hasStagingDirectory(in: replaceSupport),
              "B: no staging remains after a replacement")
    } catch {
        check(false, "B: replacement install", "\(error)")
    }

    // C. A corrupt archive is rejected by extraction and changes nothing.
    let corruptSupport = makeSupport("corrupt")
    seedLive(corruptSupport, oldFixture)
    let corruptArchive = workDir.appendingPathComponent(
        "runtime-corrupt-\(UUID().uuidString).zip")
    try? Data("not a zip".utf8).write(to: corruptArchive)
    var corruptHooks = AIRuntime.InstallHooks()
    corruptHooks.validateRuntime = { _ in RuntimeValidationReport.success(.functional) }
    var corruptThrew = false
    do {
        try AIRuntime.install(archive: corruptArchive, support: corruptSupport,
                              hooks: corruptHooks)
    } catch {
        corruptThrew = true
    }
    check(corruptThrew, "C: a corrupt archive is rejected")
    check(marker(at: AIRuntime.installDirectory(in: corruptSupport)) == "old",
          "C: the old runtime survives a corrupt archive")
    check(!hasBackupDirectory(in: corruptSupport), "C: no backup is created for a corrupt archive")
    check(!hasStagingDirectory(in: corruptSupport),
          "C: the failed extraction leaves no staging")

    // D. A staged tree with no worker package fails the structural contract.
    let layoutSupport = makeSupport("layout")
    seedLive(layoutSupport, oldFixture)
    let incomplete = workDir.appendingPathComponent("runtime-incomplete-\(UUID().uuidString)")
    try? manager.createDirectory(at: incomplete.appendingPathComponent("bin"),
                                 withIntermediateDirectories: true)
    let incompletePython = incomplete.appendingPathComponent("bin/python3")
    try? Data("#!/bin/sh\nexit 0\n".utf8).write(to: incompletePython)
    try? manager.setAttributes([.posixPermissions: 0o755],
                               ofItemAtPath: incompletePython.path)
    var layoutThrew = false
    do {
        try AIRuntime.install(archive: incomplete, support: layoutSupport,
                              hooks: fakeRuntimeHooks(extract: { _, staging in
                                  try copyContents(of: incomplete, into: staging)
                              }))
    } catch {
        layoutThrew = true
    }
    check(layoutThrew, "D: a runtime without the worker package is rejected")
    check(marker(at: AIRuntime.installDirectory(in: layoutSupport)) == "old",
          "D: the old runtime survives a structural failure")
    check(!hasStagingDirectory(in: layoutSupport),
          "D: a structural failure leaves no staging")

    // E. A tree that is structurally complete but fails the core contract is
    // rejected before the swap.
    let functionalSupport = makeSupport("functional")
    seedLive(functionalSupport, oldFixture)
    let functionalHooks = fakeRuntimeHooks(extract: extractNew, functional: { root in
        if marker(at: root) == "new" {
            return RuntimeValidationReport.failure(.functional, "core-dependency",
                                                   "numpy: ImportError")
        }
        return RuntimeValidationReport.success(.functional)
    })
    var functionalThrew = false
    do {
        try AIRuntime.install(archive: newFixture, support: functionalSupport,
                              hooks: functionalHooks)
    } catch {
        functionalThrew = true
    }
    check(functionalThrew, "E: a runtime that fails its core imports is rejected")
    check(marker(at: AIRuntime.installDirectory(in: functionalSupport)) == "old",
          "E: the old runtime survives a functional failure")
    check(transactionState(in: functionalSupport) == "committed",
          "E: a pre-swap failure restores the previous marker state")
    check(!hasStagingDirectory(in: functionalSupport),
          "E: a pre-swap failure leaves no staging")

    // F. Crash before the old runtime is moved aside: the old copy is still
    // live, the marker says swapping, and recovery keeps the old copy.
    let crashBeforeSupport = makeSupport("crash-before")
    seedLive(crashBeforeSupport, oldFixture)
    var crashBeforeHooks = fakeRuntimeHooks(extract: extractNew)
    crashBeforeHooks.checkpoint = { point in
        if point == .beforeBackupMove { throw SimulatedRuntimeCrash() }
    }
    var crashBeforeInjected = false
    do {
        try AIRuntime.install(archive: newFixture, support: crashBeforeSupport,
                              hooks: crashBeforeHooks)
    } catch is SimulatedRuntimeCrash {
        crashBeforeInjected = true
    } catch {
        crashBeforeInjected = false
    }
    check(crashBeforeInjected, "F: the crash before the backup move is injected")
    check(transactionState(in: crashBeforeSupport) == "swapping",
          "F: the crash leaves a durable swapping marker")
    check(hasStagingDirectory(in: crashBeforeSupport), "F: the staging tree survives the crash")
    let crashBeforeRecovery = AIRuntime.recoverInterruptedInstall(
        in: crashBeforeSupport, hooks: recoveryHooks())
    check(crashBeforeRecovery.isSuccess, "F: recovery after the crash succeeds",
          crashBeforeRecovery.logLine)
    check(marker(at: AIRuntime.installDirectory(in: crashBeforeSupport)) == "old",
          "F: the old runtime stays live")
    check(transactionState(in: crashBeforeSupport) == "committed",
          "F: recovery commits the runtime it kept")
    check(!hasStagingDirectory(in: crashBeforeSupport), "F: recovery removes the staging tree")

    // G. Crash after the old runtime moved to the backup and before the new one
    // moved in: the live directory is missing, so recovery restores the backup.
    let crashBackupSupport = makeSupport("crash-backup")
    seedLive(crashBackupSupport, oldFixture)
    var crashBackupHooks = fakeRuntimeHooks(extract: extractNew)
    crashBackupHooks.checkpoint = { point in
        if point == .afterBackupMove { throw SimulatedRuntimeCrash() }
    }
    var crashBackupInjected = false
    do {
        try AIRuntime.install(archive: newFixture, support: crashBackupSupport,
                              hooks: crashBackupHooks)
    } catch is SimulatedRuntimeCrash {
        crashBackupInjected = true
    } catch {
        crashBackupInjected = false
    }
    check(crashBackupInjected, "G: the crash after the backup move is injected")
    check(!manager.fileExists(atPath: AIRuntime.installDirectory(in: crashBackupSupport).path),
          "G: the crash leaves no live runtime")
    check(marker(at: AIRuntime.backupDirectory(in: crashBackupSupport)) == "old",
          "G: the old runtime is in the backup")
    let crashBackupRecovery = AIRuntime.recoverInterruptedInstall(
        in: crashBackupSupport, hooks: recoveryHooks())
    check(crashBackupRecovery.isSuccess, "G: recovery restores the backup",
          crashBackupRecovery.logLine)
    check(marker(at: AIRuntime.installDirectory(in: crashBackupSupport)) == "old",
          "G: the old runtime is live again")
    check(!hasBackupDirectory(in: crashBackupSupport), "G: the consumed backup is gone")

    // H. Crash after the new runtime moved in but before commit: the old copy
    // is still the last known-good runtime, so recovery prefers it.
    let crashLiveSupport = makeSupport("crash-live")
    seedLive(crashLiveSupport, oldFixture)
    var crashLiveHooks = fakeRuntimeHooks(extract: extractNew)
    crashLiveHooks.checkpoint = { point in
        if point == .afterLiveMove { throw SimulatedRuntimeCrash() }
    }
    var crashLiveInjected = false
    do {
        try AIRuntime.install(archive: newFixture, support: crashLiveSupport,
                              hooks: crashLiveHooks)
    } catch is SimulatedRuntimeCrash {
        crashLiveInjected = true
    } catch {
        crashLiveInjected = false
    }
    check(crashLiveInjected, "H: the crash after the live move is injected")
    check(marker(at: AIRuntime.installDirectory(in: crashLiveSupport)) == "new",
          "H: the new runtime is momentarily live")
    let crashLiveRecovery = AIRuntime.recoverInterruptedInstall(
        in: crashLiveSupport, hooks: recoveryHooks())
    check(crashLiveRecovery.isSuccess, "H: recovery after the live move succeeds",
          crashLiveRecovery.logLine)
    check(marker(at: AIRuntime.installDirectory(in: crashLiveSupport)) == "old",
          "H: the last known-good runtime is restored")
    check(!hasBackupDirectory(in: crashLiveSupport), "H: the old backup becomes live")
    check(!hasRejectedDirectory(in: crashLiveSupport),
          "H: the uncommitted new copy is removed")

    // I. Crash after commit: the new runtime is proven, so recovery keeps it and
    // only then deletes the backup.
    let crashCommitSupport = makeSupport("crash-commit")
    seedLive(crashCommitSupport, oldFixture)
    var crashCommitHooks = fakeRuntimeHooks(extract: extractNew)
    crashCommitHooks.checkpoint = { point in
        if point == .afterCommit { throw SimulatedRuntimeCrash() }
    }
    var crashCommitInjected = false
    do {
        try AIRuntime.install(archive: newFixture, support: crashCommitSupport,
                              hooks: crashCommitHooks)
    } catch is SimulatedRuntimeCrash {
        crashCommitInjected = true
    } catch {
        crashCommitInjected = false
    }
    check(crashCommitInjected, "I: the crash after commit is injected")
    check(transactionState(in: crashCommitSupport) == "committed",
          "I: the committed marker survived the crash")
    let crashCommitRecovery = AIRuntime.recoverInterruptedInstall(
        in: crashCommitSupport, hooks: recoveryHooks())
    check(crashCommitRecovery.isSuccess, "I: recovery accepts the committed runtime",
          crashCommitRecovery.logLine)
    check(marker(at: AIRuntime.installDirectory(in: crashCommitSupport)) == "new",
          "I: the committed runtime stays live")
    check(hasBackupDirectory(in: crashCommitSupport),
          "I: a verified live copy keeps the old backup until the next install")
    check(crashCommitRecovery.warnings.contains {
              $0.contains("kept until the next install")
          }, "I: recovery reports the deferred backup cleanup",
          crashCommitRecovery.warnings.joined(separator: "; "))

    // J. A new runtime that moves in and then fails its post-swap check is
    // rolled back to the old copy.
    let postSupport = makeSupport("post")
    seedLive(postSupport, oldFixture)
    let postInstall = AIRuntime.installDirectory(in: postSupport)
    let postPlan = RuntimeVerifyPlan(root: postInstall)
    var postHooks = fakeRuntimeHooks(extract: extractNew)
    postHooks.move = { source, destination in
        try manager.moveItem(at: source, to: destination)
        if destination.standardizedFileURL == postInstall.standardizedFileURL {
            postPlan.armed = true
        }
    }
    postHooks.validateRuntime = { root in
        if postPlan.shouldReject(root) {
            return RuntimeValidationReport.failure(.functional, "startup",
                                                   "the helper did not answer")
        }
        return RuntimeValidationReport.success(.functional)
    }
    var postFailure: AIRuntimeFailure?
    do {
        try AIRuntime.install(archive: newFixture, support: postSupport,
                              hooks: postHooks)
    } catch let error as AIRuntimeFailure {
        postFailure = error
    } catch {
        postFailure = nil
    }
    check(postFailure?.code == .validation, "J: a post-swap failure is a validation failure")
    check(postFailure?.previous == .kept, "J: the error knows the old runtime was kept")
    check(marker(at: postInstall) == "old", "J: the old runtime is restored after a failed swap")
    check(transactionState(in: postSupport) == "committed",
          "J: the restored runtime is committed")
    check(!hasBackupDirectory(in: postSupport), "J: the backup is consumed by the rollback")
    check(!hasStagingDirectory(in: postSupport), "J: the failed post-swap leaves no staging")

    // K. If moving the old runtime to the backup fails, it never left its place
    // and the message must not claim it was lost.
    let keptSupport = makeSupport("kept")
    seedLive(keptSupport, oldFixture)
    let keptBackup = AIRuntime.backupDirectory(in: keptSupport)
    var keptHooks = fakeRuntimeHooks(extract: extractNew)
    keptHooks.move = { source, destination in
        if destination.standardizedFileURL == keptBackup.standardizedFileURL {
            throw RuntimeTestFailure()
        }
        try manager.moveItem(at: source, to: destination)
    }
    var keptFailure: AIRuntimeFailure?
    do {
        try AIRuntime.install(archive: newFixture, support: keptSupport, hooks: keptHooks)
    } catch let error as AIRuntimeFailure {
        keptFailure = error
    } catch {
        keptFailure = nil
    }
    check(keptFailure?.code == .install, "K: a failed backup move is an install failure")
    check(keptFailure?.previous == .kept, "K: the error knows the old runtime never moved")
    check(keptFailure?.localizedDescription == L10n.current.aiRuntimeInstallFailed,
          "K: the message says the previous runtime was kept",
          keptFailure?.localizedDescription ?? "")
    check(marker(at: AIRuntime.installDirectory(in: keptSupport)) == "old",
          "K: the old runtime remains live")
    check(transactionState(in: keptSupport) == "committed",
          "K: the marker records the still-live runtime")

    // L. A first install that fails after the swap leaves nothing live and must
    // not claim a previous runtime was kept.
    let firstFailSupport = makeSupport("first-fail")
    let firstFailInstall = AIRuntime.installDirectory(in: firstFailSupport)
    let firstFailPlan = RuntimeVerifyPlan(root: firstFailInstall)
    var firstFailHooks = fakeRuntimeHooks(extract: extractNew)
    firstFailHooks.move = { source, destination in
        try manager.moveItem(at: source, to: destination)
        if destination.standardizedFileURL == firstFailInstall.standardizedFileURL {
            firstFailPlan.armed = true
        }
    }
    firstFailHooks.validateRuntime = { root in
        if firstFailPlan.shouldReject(root) {
            return RuntimeValidationReport.failure(.functional, "startup",
                                                   "the helper did not answer")
        }
        return RuntimeValidationReport.success(.functional)
    }
    var firstFailFailure: AIRuntimeFailure?
    do {
        try AIRuntime.install(archive: newFixture, support: firstFailSupport,
                              hooks: firstFailHooks)
    } catch let error as AIRuntimeFailure {
        firstFailFailure = error
    } catch {
        firstFailFailure = nil
    }
    check(firstFailFailure?.code == .validation, "L: a first install failure is reported")
    check(firstFailFailure?.previous == AIRuntimeFailure.PreviousRuntime.none,
          "L: the error knows there was no previous runtime")
    check(firstFailFailure?.localizedDescription == L10n.current.aiRuntimeInstallFailedNothing,
          "L: the message does not claim a previous runtime was kept",
          firstFailFailure?.localizedDescription ?? "")
    check(!manager.fileExists(atPath: firstFailInstall.path),
          "L: a failed first install leaves nothing live")
    check(transactionMarker(in: firstFailSupport) == nil,
          "L: a failed first install leaves no marker")
    check(!hasStagingDirectory(in: firstFailSupport),
          "L: a failed first install leaves no staging")

    // M. If the rollback itself cannot restore the backup, it must say so and
    // keep the old runtime in the backup for a later recovery.
    let rollbackSupport = makeSupport("rollback")
    seedLive(rollbackSupport, oldFixture)
    let rollbackInstall = AIRuntime.installDirectory(in: rollbackSupport)
    let rollbackBackup = AIRuntime.backupDirectory(in: rollbackSupport)
    let rollbackPlan = RuntimeVerifyPlan(root: rollbackInstall)
    var rollbackHooks = fakeRuntimeHooks(extract: extractNew)
    rollbackHooks.move = { source, destination in
        if destination.standardizedFileURL == rollbackInstall.standardizedFileURL {
            rollbackPlan.armed = true
        }
        if source.standardizedFileURL == rollbackBackup.standardizedFileURL {
            throw RuntimeTestFailure()
        }
        try manager.moveItem(at: source, to: destination)
    }
    rollbackHooks.validateRuntime = { root in
        if rollbackPlan.shouldReject(root) {
            return RuntimeValidationReport.failure(.functional, "startup",
                                                   "the helper did not answer")
        }
        return RuntimeValidationReport.success(.functional)
    }
    var rollbackFailure: AIRuntimeFailure?
    do {
        try AIRuntime.install(archive: newFixture, support: rollbackSupport,
                              hooks: rollbackHooks)
    } catch let error as AIRuntimeFailure {
        rollbackFailure = error
    } catch {
        rollbackFailure = nil
    }
    check(rollbackFailure?.code == .validation, "M: a failed rollback is reported")
    check(rollbackFailure?.previous == .preserved,
          "M: the error knows the old runtime is preserved, not live")
    check(rollbackFailure?.localizedDescription == L10n.current.aiRuntimeInstallFailedPreserved,
          "M: the message says the previous runtime was preserved for recovery",
          rollbackFailure?.localizedDescription ?? "")
    check(marker(at: rollbackBackup) == "old",
          "M: the old runtime is preserved in the backup")
    check(!manager.fileExists(atPath: rollbackInstall.path),
          "M: no unverified runtime is left live")
    check(hasRejectedDirectory(in: rollbackSupport),
          "M: the rejected new copy is kept for inspection")
    check(transactionState(in: rollbackSupport) == "rollingBack",
          "M: the marker stays honest after a failed rollback")
}

@MainActor
func testRuntimeMarkerAndRecoverySafety() {
    print("\n[M1-AI2] a damaged marker or a symlink cannot reach outside the runtime folder")

    let manager = FileManager.default
    let oldFixture = workDir.appendingPathComponent("runtime-old-\(UUID().uuidString)")
    do {
        try makeFakeRuntime(at: oldFixture, marker: "old")
    } catch {
        check(false, "runtime fixture written", "\(error)")
        return
    }

    func makeSupport(_ label: String) -> URL {
        let url = workDir.appendingPathComponent("runtime-\(label)-\(UUID().uuidString)",
                                                isDirectory: true)
        try? manager.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    func seedLive(_ support: URL) {
        let install = AIRuntime.installDirectory(in: support)
        try? manager.createDirectory(at: install, withIntermediateDirectories: true)
        try? copyContents(of: oldFixture, into: install)
    }

    // The marker is treated as untrusted input: unreadable JSON, a JSON object
    // with unexpected fields, a non-UUID id and a directory in its place are all
    // rejected without touching any runtime file.
    let brokenJSON = makeSupport("broken-json")
    seedLive(brokenJSON)
    try? Data("{not json".utf8).write(to: brokenJSON.appendingPathComponent(
        "runtime-transaction.json"))
    let brokenResult = AIRuntime.recoverInterruptedInstall(in: brokenJSON,
                                                           hooks: recoveryHooks())
    check(brokenResult.failure?.code == .invalidMarker,
          "N: unreadable marker JSON is rejected")
    check(marker(at: AIRuntime.installDirectory(in: brokenJSON)) == "old",
          "N: the live runtime is untouched when the marker is unreadable")
    check(!hasRejectedDirectory(in: brokenJSON),
          "N: no directory is moved for an unreadable marker")

    let canary = workDir.appendingPathComponent("canary-\(UUID().uuidString)")
    try? Data("keep".utf8).write(to: canary)

    let absoluteID = makeSupport("absolute-id")
    try? writeTransactionMarker(in: absoluteID, id: canary.path,
                                state: "swapping", hadPrevious: true)
    let absoluteResult = AIRuntime.recoverInterruptedInstall(in: absoluteID,
                                                             hooks: recoveryHooks())
    check(absoluteResult.failure?.code == .invalidMarker,
          "N: a path in the id field is rejected")
    check(fileBytes(canary) != nil,
          "N: a path in the id cannot delete a file outside the runtime folder")

    let extraField = makeSupport("extra-field")
    try? writeTransactionMarker(in: extraField,
                                id: UUID().uuidString,
                                state: "swapping", hadPrevious: true,
                                extra: ["path": canary.path])
    let extraResult = AIRuntime.recoverInterruptedInstall(in: extraField,
                                                          hooks: recoveryHooks())
    check(extraResult.failure?.code == .invalidMarker,
          "N: unexpected fields in the marker are rejected")
    check(fileBytes(canary) != nil,
          "N: an unexpected path field cannot reach outside the runtime folder")

    let malformedID = makeSupport("malformed-id")
    try? writeTransactionMarker(in: malformedID, id: "../outside",
                                state: "swapping", hadPrevious: true)
    let malformedResult = AIRuntime.recoverInterruptedInstall(in: malformedID,
                                                              hooks: recoveryHooks())
    check(malformedResult.failure?.code == .invalidMarker,
          "N: a traversal id is rejected")

    let directoryMarker = makeSupport("directory-marker")
    try? manager.createDirectory(
        at: directoryMarker.appendingPathComponent("runtime-transaction.json"),
        withIntermediateDirectories: true)
    let directoryResult = AIRuntime.recoverInterruptedInstall(in: directoryMarker,
                                                              hooks: recoveryHooks())
    check(directoryResult.failure?.code == .invalidMarker,
          "N: a directory in place of the marker is rejected")

    // A symlinked live or backup directory is never followed, even when the
    // marker is otherwise valid.
    let outside = workDir.appendingPathComponent("outside-\(UUID().uuidString)")
    try? manager.createDirectory(at: outside, withIntermediateDirectories: true)
    try? copyContents(of: oldFixture, into: outside)

    let symlinkBackup = makeSupport("symlink-backup")
    try? manager.createSymbolicLink(at: AIRuntime.backupDirectory(in: symlinkBackup),
                                    withDestinationURL: outside)
    try? writeTransactionMarker(in: symlinkBackup, id: UUID().uuidString,
                                state: "swapping", hadPrevious: true)
    let symlinkBackupResult = AIRuntime.recoverInterruptedInstall(
        in: symlinkBackup, hooks: recoveryHooks())
    check(symlinkBackupResult.failure?.code == .unsafePath,
          "N: a symlinked backup is rejected")
    check(marker(at: outside) == "old",
          "N: the symlink target is never moved or modified")

    let symlinkLive = makeSupport("symlink-live")
    try? manager.createSymbolicLink(at: AIRuntime.installDirectory(in: symlinkLive),
                                    withDestinationURL: outside)
    let symlinkLiveResult = AIRuntime.recoverInterruptedInstall(
        in: symlinkLive, hooks: recoveryHooks())
    check(symlinkLiveResult.failure?.code == .unsafePath,
          "N: a symlinked live runtime is rejected")
    check(marker(at: outside) == "old",
          "N: the live symlink target is never modified")

    // A committed runtime whose files are gone is a failure, not a silent
    // "installed" answer.
    let missing = makeSupport("missing")
    try? writeTransactionMarker(in: missing, id: UUID().uuidString,
                                state: "committed", hadPrevious: false)
    let missingResult = AIRuntime.recoverInterruptedInstall(in: missing,
                                                            hooks: recoveryHooks())
    check(missingResult.failure?.code == .liveInvalid,
          "N: a committed marker with no live runtime is a failure")

    // A committed live copy that no longer passes the contract is replaced by
    // the validated backup instead of deleting the backup first.
    let committedBroken = makeSupport("committed-broken")
    let brokenInstall = AIRuntime.installDirectory(in: committedBroken)
    try? manager.createDirectory(at: brokenInstall, withIntermediateDirectories: true)
    try? Data("half".utf8).write(to: brokenInstall.appendingPathComponent("half"))
    let brokenBackup = AIRuntime.backupDirectory(in: committedBroken)
    try? manager.createDirectory(at: brokenBackup, withIntermediateDirectories: true)
    try? copyContents(of: oldFixture, into: brokenBackup)
    try? writeTransactionMarker(in: committedBroken, id: UUID().uuidString,
                                state: "committed", hadPrevious: true)
    let committedBrokenResult = AIRuntime.recoverInterruptedInstall(
        in: committedBroken, hooks: recoveryHooks())
    check(committedBrokenResult.isSuccess, "N: a broken committed runtime is repaired",
          committedBrokenResult.logLine)
    check(marker(at: brokenInstall) == "old",
          "N: the validated backup replaces the broken live copy")
    check(!hasBackupDirectory(in: committedBroken),
          "N: the backup is consumed only after the restored copy validates")

    // A fresh staging folder with no marker could belong to an older install,
    // so it is left alone; an old one is swept.
    let freshStaging = makeSupport("fresh-staging")
    let stagingPrefix = AIRuntime.installDirectory(in: freshStaging)
        .lastPathComponent + "-installing-"
    let fresh = freshStaging.appendingPathComponent(stagingPrefix + "fresh")
    try? manager.createDirectory(at: fresh, withIntermediateDirectories: true)
    let freshResult = AIRuntime.recoverInterruptedInstall(in: freshStaging,
                                                          hooks: recoveryHooks())
    check(freshResult.isSuccess, "N: a marker-less support folder recovers cleanly")
    check(manager.fileExists(atPath: fresh.path),
          "N: a fresh marker-less staging folder is not deleted")

    let staleStaging = makeSupport("stale-staging")
    let stale = staleStaging.appendingPathComponent(
        AIRuntime.installDirectory(in: staleStaging).lastPathComponent + "-installing-stale")
    try? manager.createDirectory(at: stale, withIntermediateDirectories: true)
    try? manager.setAttributes([.modificationDate: Date().addingTimeInterval(-7200)],
                               ofItemAtPath: stale.path)
    _ = AIRuntime.recoverInterruptedInstall(in: staleStaging, hooks: recoveryHooks())
    check(!manager.fileExists(atPath: stale.path),
          "N: stale marker-less staging data is swept")
}

@MainActor
func testRuntimeRecoveryBeforeUse() {
    print("\n[M1-AI3] a failed recovery is retried, a good one is cached, and AI use waits for it")

    let manager = FileManager.default
    let oldFixture = workDir.appendingPathComponent("runtime-old-\(UUID().uuidString)")
    do {
        try makeFakeRuntime(at: oldFixture, marker: "old")
    } catch {
        check(false, "runtime fixture written", "\(error)")
        return
    }

    // The worker recovers an update interrupted while the app was closed before
    // it reports a runtime.
    let useSupport = workDir.appendingPathComponent("runtime-use-\(UUID().uuidString)",
                                                   isDirectory: true)
    try? manager.createDirectory(at: useSupport, withIntermediateDirectories: true)
    let useBackup = AIRuntime.backupDirectory(in: useSupport)
    try? manager.createDirectory(at: useBackup, withIntermediateDirectories: true)
    try? copyContents(of: oldFixture, into: useBackup)
    let useResult = AIWorker.recoverRuntimeIfNeeded(force: true, support: useSupport,
                                                    hooks: recoveryHooks())
    check(useResult.isSuccess, "R: the worker recovers before looking up a helper",
          useResult.logLine)
    check(marker(at: AIRuntime.installDirectory(in: useSupport)) == "old",
          "R: the old runtime is restored before use")
    check(AIRuntime.isStructurallyValid(root: AIRuntime.installDirectory(in: useSupport)),
          "R: the recovered runtime passes the layout contract")
    check(!hasBackupDirectory(in: useSupport), "R: the backup is consumed after a good restore")

    // A failed recovery is not cached as done: the next use retries.
    let retrySupport = workDir.appendingPathComponent("runtime-retry-\(UUID().uuidString)",
                                                     isDirectory: true)
    try? manager.createDirectory(at: retrySupport, withIntermediateDirectories: true)
    try? Data("{bad".utf8).write(to: retrySupport.appendingPathComponent(
        "runtime-transaction.json"))
    let firstAttempt = AIWorker.recoverRuntimeIfNeeded(force: true, support: retrySupport,
                                                       hooks: recoveryHooks())
    check(!firstAttempt.isSuccess, "R: a failed recovery is reported")
    try? manager.removeItem(at: retrySupport.appendingPathComponent("runtime-transaction.json"))
    let retryInstall = AIRuntime.installDirectory(in: retrySupport)
    try? manager.createDirectory(at: retryInstall, withIntermediateDirectories: true)
    try? copyContents(of: oldFixture, into: retryInstall)
    let secondAttempt = AIWorker.recoverRuntimeIfNeeded(support: retrySupport,
                                                        hooks: recoveryHooks())
    check(secondAttempt.isSuccess, "R: the next use retries a failed recovery",
          secondAttempt.logLine)
    check(marker(at: retryInstall) == "old", "R: the retry adopts the live runtime")

    // AIWorker's gate: a runtime that passes the functional contract is usable;
    // the answer is cached until the runtime changes.
    let gateSupport = workDir.appendingPathComponent("runtime-gate-\(UUID().uuidString)",
                                                    isDirectory: true)
    try? manager.createDirectory(at: gateSupport, withIntermediateDirectories: true)
    let gateInstall = AIRuntime.installDirectory(in: gateSupport)
    try? manager.createDirectory(at: gateInstall, withIntermediateDirectories: true)
    try? copyContents(of: oldFixture, into: gateInstall)
    AIWorker.runtimeDidChange(support: gateSupport)
    check(AIWorker.downloadedRuntimeUsable(support: gateSupport, hooks: recoveryHooks()),
          "P: a runtime that passes the functional contract is usable")
    let refusing = recoveryHooks(functional: { _ in
        RuntimeValidationReport.failure(.functional, "startup", "refused by the test")
    })
    check(AIWorker.downloadedRuntimeUsable(support: gateSupport, hooks: refusing),
          "P: the validated answer is cached for this process")
    AIWorker.runtimeDidChange(support: gateSupport)
    check(!AIWorker.downloadedRuntimeUsable(support: gateSupport, hooks: refusing),
          "P: an invalid runtime is refused after the cache is cleared")
    check(AIWorker.runtimeProblem(support: gateSupport) != nil,
          "P: the refusal is available to the error message")

    let capsSupport = workDir.appendingPathComponent("runtime-caps-\(UUID().uuidString)",
                                                    isDirectory: true)
    try? manager.createDirectory(at: capsSupport, withIntermediateDirectories: true)
    let capsInstall = AIRuntime.installDirectory(in: capsSupport)
    try? manager.createDirectory(at: capsInstall, withIntermediateDirectories: true)
    try? copyContents(of: oldFixture, into: capsInstall)
    AIWorker.runtimeDidChange(support: capsSupport)
    let capsHooks = recoveryHooks(functional: { _ in
        RuntimeValidationReport.success(.functional,
                                        capabilities: ["segmentation": false,
                                                       "image-generation": true])
    })
    check(AIWorker.downloadedRuntimeUsable(support: capsSupport, hooks: capsHooks),
          "P: a missing optional backend does not invalidate the runtime")

    let blockedSupport = workDir.appendingPathComponent("runtime-blocked-\(UUID().uuidString)",
                                                       isDirectory: true)
    try? manager.createDirectory(at: blockedSupport, withIntermediateDirectories: true)
    let blockedInstall = AIRuntime.installDirectory(in: blockedSupport)
    try? manager.createDirectory(at: blockedInstall, withIntermediateDirectories: true)
    try? copyContents(of: oldFixture, into: blockedInstall)
    try? Data("{bad".utf8).write(to: blockedSupport.appendingPathComponent(
        "runtime-transaction.json"))
    AIWorker.runtimeDidChange(support: blockedSupport)
    check(!AIWorker.downloadedRuntimeUsable(support: blockedSupport, hooks: recoveryHooks()),
          "P: an unresolved transaction blocks runtime selection")
}

@MainActor
func testRuntimeConcurrentInstall() {
    print("\n[M1-AI4] concurrent installs serialize on one shared transaction lock")

    let manager = FileManager.default
    let support = workDir.appendingPathComponent("runtime-concurrent-\(UUID().uuidString)",
                                                isDirectory: true)
    try? manager.createDirectory(at: support, withIntermediateDirectories: true)

    var fixtures: [URL] = []
    for index in 0..<4 {
        let fixture = workDir.appendingPathComponent(
            "runtime-concurrent-\(index)-\(UUID().uuidString)")
        do {
            try makeFakeRuntime(at: fixture, marker: "v\(index)")
            fixtures.append(fixture)
        } catch {
            check(false, "O: concurrent fixtures written", "\(error)")
            return
        }
    }

    let errors = NSLock()
    var collected: [String] = []
    let group = DispatchGroup()
    for fixture in fixtures {
        DispatchQueue.global().async(group: group) {
            var hooks = fakeRuntimeHooks(extract: { _, staging in
                try copyContents(of: fixture, into: staging)
            })
            hooks.validateRuntime = { root in
                let layout = AIRuntimeValidation.structural(root: root)
                guard layout.ok else { return layout }
                return RuntimeValidationReport.success(.functional)
            }
            do {
                try AIRuntime.install(archive: fixture, support: support, hooks: hooks)
            } catch {
                errors.lock()
                collected.append("\(error)")
                errors.unlock()
            }
        }
    }
    group.wait()

    check(collected.isEmpty, "O: every concurrent install finishes", collected.joined(separator: "; "))
    let install = AIRuntime.installDirectory(in: support)
    check(AIRuntime.isStructurallyValid(root: install),
          "O: the surviving runtime passes the layout contract")
    check(transactionState(in: support) == "committed",
          "O: the final marker is committed")
    check(!hasStagingDirectory(in: support), "O: no staging is left behind")
    check(!hasBackupDirectory(in: support), "O: no backup is left behind")
    check(!hasRejectedDirectory(in: support), "O: no rejected copy is left behind")
    let lockPath = support.appendingPathComponent("runtime.lock")
    var isDirectory: ObjCBool = false
    let lockIsFile = manager.fileExists(atPath: lockPath.path, isDirectory: &isDirectory)
        && !isDirectory.boolValue
    var info = stat()
    let notSymlink = lockPath.path.withCString { lstat($0, &info) } == 0
        && (info.st_mode & S_IFMT) == S_IFREG
    check(lockIsFile && notSymlink, "O: the lock file is a persistent regular file")
}

@MainActor
func testRealRuntimeValidation() {
    print("\n[M1-AI-R] the real runtime passes the functional contract")

    guard ProcessInfo.processInfo.environment["RETOUCH_REAL_RUNTIME"] == "1" else {
        print("  · skipped (set RETOUCH_REAL_RUNTIME=1 to probe an installed runtime)")
        return
    }

    var candidates: [URL] = []
    if let bundled = AIWorker.bundledRoot { candidates.append(bundled) }
    let installed = AIRuntime.installDirectory
    if FileManager.default.fileExists(atPath: installed.path) {
        candidates.append(installed)
    }
    guard let root = candidates.first(where: { AIRuntime.isStructurallyValid(root: $0) }) else {
        check(false, "a structurally valid real runtime is available")
        return
    }

    func fingerprint(_ root: URL) -> String {
        ["bin/python3", "retouch_ai_worker", "site-packages"].map { name in
            let url = root.appendingPathComponent(name)
            let values = try? url.resourceValues(forKeys: [.contentModificationDateKey,
                                                            .fileSizeKey])
            return "\(name):\(values?.contentModificationDate?.timeIntervalSince1970 ?? 0):\(values?.fileSize ?? 0)"
        }.joined(separator: "|")
    }

    let before = fingerprint(root)
    let report = AIRuntimeValidation.functional(root: root)
    check(report.ok, "the real runtime starts, imports its core and answers health",
          report.logLine)
    check(report.capabilities["segmentation"] != nil,
          "optional capability availability is reported separately")
    check(AIRuntime.isStructurallyValid(root: root),
          "the functional probe leaves the real runtime valid")
    check(fingerprint(root) == before,
          "the functional probe does not modify the runtime")
}

@MainActor
func testRecoveryIsolation(productionBefore: RecoveryFingerprint) async {
    print("\n[M1-R5] the suite never writes the production recovery copy")

    await settleRecoveryWrites()

    check(RecoveryStore.directory.standardizedFileURL
            != RecoveryStore.productionDirectory.standardizedFileURL,
          "recovery writes are redirected away from Application Support")
    check(RecoveryStore.directory.path.hasPrefix(workDir.path),
          "the test recovery root is inside the scratch directory")

    let settings = AppSettings.shared
    let previousRecoverySetting = settings.recoveryEnabled
    settings.recoveryEnabled = true
    defer { settings.recoveryEnabled = previousRecoverySetting }

    let source = workDir.appendingPathComponent("isolation-photo.png")
    check(makeImage(width: 320, height: 400).map { writePNG($0, to: source) } ?? false,
          "isolation fixture written")
    let model = EditorModel()
    model.load(url: source)
    check(await waitUntil(60) { model.hasImage && !model.isBusy }, "isolation fixture loads")
    model.adjustments.exposure = 0.3
    check(await waitUntil(10) { RecoveryStore.read()?.imagePath == source.path },
          "the delayed autosave lands in the test directory")

    let productionAfter = RecoveryFingerprint.capture(RecoveryStore.productionDirectory)
    check(productionAfter == productionBefore,
          "the production recovery copy is untouched by the whole suite")
}

// MARK: - runner

@MainActor
func runAll() async {
    await testExportDoesNotSave()
    await testSmartKeepsUnmeasuredFields()
    await testResetAllClearsEverything()
    await testCropIsUndoable()
    await testOrientationKeepsEditsAttached()
    testBatchExportPolicy()
    await testBatchMatchesSingleExport()
    await testBatchKeepsCropAfterQuarterTurn()
    await testProjectRelink()
    await testProjectVersionGuard()
    await testOperationCoordination()
    await testBatchCancellationStopsInFlightFile()
    await testBatchWriteFailureIsNotCounted()
    await testPreviewStaysAtPreviewResolution()
    await testPrivacySettingDefaults()
    await testAIEditBoundaries()
    await testAIProjectRoundTrip()
    await testAIEditUndoAndExport()
    await testAIMaskRenderer()
    await testQuickEditSelectionGating()
    await testFullFrameReimagine()
    await testExportUpscalePolicy()
    await testAnalysisExportNeedsFace()
    await testRecoveryCancelPreservesData()
    await testRecoveryRestoresAfterSimulatedRelaunch()
    await testRecoveryLocatePathWaitsForRestore()
    await testFailedLoadPreservesDocument()
    await testExportProtectsSource()
    await testBatchDoesNotOverwriteSource()
    testRuntimeTransactionalInstall()
    testRuntimeMarkerAndRecoverySafety()
    testRuntimeRecoveryBeforeUse()
    testRuntimeConcurrentInstall()
    testRealRuntimeValidation()
    await testRecoveryIsolation(productionBefore: productionRecoveryBefore)

    // Give the last delayed autosave time to land before its directory goes.
    try? await Task.sleep(nanoseconds: 1_800_000_000)

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