import CoreGraphics
import Foundation
import UniformTypeIdentifiers

/// The sidecar document for one photo. The photo itself is never copied or
/// modified; the project records how it should be edited so the work can be
/// resumed later.
struct RetouchProject: Codable {
    static let currentVersion = 1
    static let fileExtension = "retouch"

    /// The app declares this type in Info.plist, so the panel filters to real
    /// project files instead of any JSON.
    static var contentType: UTType {
        UTType(exportedAs: "local.retouchstudio.project", conformingTo: .json)
    }

    var version = currentVersion
    var imagePath: String
    var adjustments: Adjustments
    var exportFormat: String
    var exportQuality: Double
    var autoRetouchStrength: Double
    /// Strength for Auto Color & Light. Projects written before it existed
    /// decode as `nil` and the editor falls back to applying the analysis
    /// exactly as measured.
    var autoColorStrength: Double? = nil
    /// Normalized top-left crop applied to the original photo, if any. Projects
    /// written before crop existed decode as `nil`.
    var crop: CGRect? = nil
    /// Manual healing stamps, in the same original-photo coordinates as `crop`.
    /// Empty is written as `nil` so older projects and older readers are
    /// unaffected.
    var healSpots: [HealSpot]? = nil
}
