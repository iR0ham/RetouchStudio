import Foundation
import StudioCore

/// A document state is a history step. Both the value and the history rules
/// live in StudioCore (`DocumentState`, `DocumentHistory`); this name and the
/// zero-argument initializer are the app's shorthand for them.
///
/// The undo history of one open document, shared with every platform. The
/// editor still owns the 350 ms coalescing timer, the busy guards, status
/// tokens, applying a restored state to the published values and reloading
/// pixels after a crop or turn; it supplies the current state at each explicit
/// transaction boundary.
typealias DocumentSession = DocumentHistory<DocumentState>

extension DocumentHistory where State == DocumentState {
    init() { self.init(DocumentState()) }
}
