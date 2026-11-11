import CoreGraphics
import Foundation
import StudioCore

/// The document values one undo step covers. It is a plain value: the editor
/// still owns editing, history, dirty tracking, saving, autosave and recovery;
/// this type only carries the eight fields those features agree on.
///
/// It stays in the application layer for now. Several field types still live
/// beside rendering helpers, so moving the value into StudioCore needs those
/// types to be independently portable first.
struct DocumentState: Equatable {
    var adjustments = Adjustments()
    var healSpots: [HealSpot] = []
    var stickers: [Sticker] = []
    var aiEdits: [AIEdit] = []
    var analysis = AnalysisSettings()
    var crop: CGRect?
    var orientation = DocumentOrientation.identity
    var selectedFaceIndex: Int?
}
