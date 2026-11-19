import Foundation
import StudioCore

// The export sheet's upscale estimate must not under-promise the wall time
// this machine measures. The rates come from
// Docs/W5_UPSCALER_ACCEPTANCE.md §12.5 (banded path at 77951c3,
// developer-machine MPS, 2026-11-19). Like Tests/StudioCoreTests.swift this
// file is top-level code: Foundation and StudioCore only.

var failures: [String] = []
var checks = 0

func check(_ condition: Bool, _ label: String, _ detail: String = "") {
    checks += 1
    if condition {
        print("  ✓ \(label)\(detail.isEmpty ? "" : " — \(detail)")")
    } else {
        print("  ✗ \(label)\(detail.isEmpty ? "" : " — \(detail)")")
        failures.append(label)
    }
}

/// The four measured first jobs: a square source whose 4x output is the
/// listed mega-pixel count, and the wall time the worker reported.
let measured: [(side: Int, outputMegapixels: Double, wallSeconds: Double)] = [
    (500, 4.000, 46.94),
    (790, 9.9856, 100.22),
    (1120, 20.0704, 176.48),
    (1580, 39.9424, 354.84),
]

for row in measured {
    let side = Double(row.side)
    let size = StudioSize(width: side, height: side)
    let produced = side * side * RenderUpscale.factor * RenderUpscale.factor / 1_000_000
    let estimate = RenderUpscale.estimatedSeconds(for: size)
    check(abs(produced - row.outputMegapixels) < 0.0001,
          "\(row.side)x\(row.side) writes \(row.outputMegapixels) MP",
          "\(produced)")
    check(Double(estimate) >= row.wallSeconds,
          "the estimate covers the measured \(row.outputMegapixels) MP job",
          "estimate \(estimate) s vs measured \(row.wallSeconds) s")
}

// The warm repeat at 20.070 MP ran slower than its cold peers; a planning
// ceiling has to cover it too.
let warm = StudioSize(width: 1120, height: 1120)
check(Double(RenderUpscale.estimatedSeconds(for: warm)) >= 189.68,
      "the estimate covers the warm 20.070 MP repeat",
      "\(RenderUpscale.estimatedSeconds(for: warm)) s vs 189.68 s")

var previous = 0
for step in 0...40 {
    let side = Double(16 + step * 39)
    let estimate = RenderUpscale.estimatedSeconds(for: StudioSize(width: side, height: side))
    check(estimate >= previous,
          "the estimate never falls as the output grows",
          "\(Int(side))x\(Int(side)) -> \(estimate) s")
    previous = estimate
}

// A 2.5 MP source is exactly the 40 MP output ceiling; the projection there
// must stay inside the host's 1500 s wait
// (Sources/RetouchStudio/Core/ExportService.swift:225).
let ceiling = StudioSize(width: 1250, height: 2000)
check(RenderUpscale.canHandle(ceiling), "the 40 MP output ceiling is still accepted")
let ceilingEstimate = RenderUpscale.estimatedSeconds(for: ceiling)
check(ceilingEstimate < 1500,
      "the 40 MP ceiling projects inside the 1500 s host wait",
      "\(ceilingEstimate) s")

print("")
print(failures.isEmpty
      ? "Upscale ETA: \(checks) checks passed"
      : "Upscale ETA: \(checks - failures.count)/\(checks) passed, \(failures.count) failed")
if !failures.isEmpty {
    for failure in failures { print("  failed: \(failure)") }
    exit(1)
}
