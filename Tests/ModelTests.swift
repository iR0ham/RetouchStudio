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

// MARK: - runner

@MainActor
func runAll() async {
    await testExportDoesNotSave()

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