import Foundation
import StudioCore

/// The document values a load contributes to the editor.
///
/// Pixels, overlays, status and recents belong to the shell. This value keeps
/// the project-to-document mapping in one place so a plain photo load and a
/// project restore cannot drift apart.
struct DocumentRestoration: Equatable {
    /// Nil for a plain photo load: the export and auto settings stay where the
    /// owner left them.
    var exportFormat: ExportFormat?
    var exportQuality: Double?
    var exportLongEdge: Int?
    var autoRetouchStrength: Double?
    var autoColorStrength: Double?
    var state: DocumentState
    var projectURL: URL?
    var isProject: Bool

    static func photo() -> DocumentRestoration {
        DocumentRestoration(exportFormat: nil, exportQuality: nil, exportLongEdge: nil,
                            autoRetouchStrength: nil, autoColorStrength: nil,
                            state: DocumentState(), projectURL: nil, isProject: false)
    }

    static func project(_ project: RetouchProject, url: URL?) -> DocumentRestoration {
        var state = DocumentState()
        state.adjustments = project.adjustments
        state.healSpots = project.healSpots ?? []
        state.stickers = project.stickers ?? []
        state.aiEdits = project.aiEdits ?? []
        state.analysis = project.analysis ?? AnalysisSettings()
        state.crop = project.crop
        state.orientation = project.orientation ?? .identity
        state.selectedFaceIndex = project.selectedFace

        return DocumentRestoration(exportFormat: ExportFormat(rawValue: project.exportFormat) ?? .jpeg,
                                   exportQuality: project.exportQuality,
                                   exportLongEdge: project.exportLongEdge ?? 0,
                                   autoRetouchStrength: project.autoRetouchStrength,
                                   autoColorStrength: project.autoColorStrength ?? 100,
                                   state: state,
                                   projectURL: url,
                                   isProject: true)
    }
}
