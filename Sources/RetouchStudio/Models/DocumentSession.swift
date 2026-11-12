import Foundation
import StudioCore

/// A document state is a history step. The history rules live in StudioCore
/// (`DocumentHistory`); the state stays in the application layer until its
/// field types are portable too.
extension DocumentState: HistoryState {}

/// The undo history of one open document, shared with every platform. The
/// editor still owns the 350 ms coalescing timer, the busy guards, status
/// tokens, applying a restored state to the published values and reloading
/// pixels after a crop or turn; it supplies the current state at each explicit
/// transaction boundary.
typealias DocumentSession = DocumentHistory<DocumentState>

extension DocumentHistory where State == DocumentState {
    init() { self.init(DocumentState()) }
}
