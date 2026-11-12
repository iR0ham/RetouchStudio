import CoreGraphics
import Foundation
import StudioCore

/// The analysis value (`AnalysisRegion`, `AnalysisExportMode`, `AnalysisTint`,
/// `AnalysisSettings`) lives in StudioCore, because a document carries it on
/// every platform. The ink colours and the canvas-facing conveniences stay
/// here, beside Core Graphics.

extension AnalysisTint {
    var rgb: (r: CGFloat, g: CGFloat, b: CGFloat) {
        switch self {
        case .chalk: return (1, 1, 1)
        case .lime: return (0.78, 0.97, 0.24)
        case .sky: return (0.36, 0.80, 1)
        case .ember: return (1, 0.62, 0.32)
        case .ink: return (0.06, 0.07, 0.09)
        }
    }
}

extension AnalysisSettings {
    /// The canvas drags pins in CoreGraphics points; the stored value stays
    /// portable.
    mutating func setEndpoint(_ point: CGPoint, for region: AnalysisRegion) {
        setEndpoint(StudioPoint(point), for: region)
    }

    mutating func setAnchor(_ point: CGPoint, for region: AnalysisRegion) {
        setAnchor(StudioPoint(point), for: region)
    }
}
