import Foundation

/// What just happened, kept as a fact rather than as a finished sentence.
///
/// The status line is shown next to the photo and stays there until the next
/// action, so it has to survive a language switch. Holding the *event* instead
/// of its wording lets the string table put it into the language that is in
/// force now, instead of leaving the previous language on screen.
enum StatusToken: Equatable {
    case none
    case facesDetected(Int)
    case noFaceColorOnly
    case dropHint
    case readingImage
    case couldNotRead
    case projectOpened
    /// A crash-recovery candidate was restored. It has no project file, so it
    /// must not reuse the project sentence.
    case sessionRestored
    case applyingCrop
    case cropReset
    case cropApplied
    case rotated
    case flipped
    case straightened
    case healCleared
    case healStampRemoved
    case healStampAdded(Int)
    case stickerAdded(Int)
    case stickerRemoved
    case stickersCleared
    case presetSaved(String)
    case analyzingSmart
    case smartFailed
    case smartReady
    case smartApplied
    case smartAppliedReport([String])
    case aiWorking
    case aiApplied
    case aiAssetsMissing(Int)
    /// An AI task was refused because its model is not installed. The sentence
    /// already exists for the inline case; this puts it on the status line.
    case aiModelMissing
    /// An AI task was refused because its installed model is not in a runnable
    /// state. The payload is the worker's capability id, not a sentence.
    case aiCapabilityBlocked(String)
    /// An AI task was refused because the helper cannot load the Python
    /// runtime package its adapter needs. The payload is the capability id, as
    /// for `aiCapabilityBlocked`, plus the package name the refusal reported:
    /// an import failure is all the helper can observe, so the host cannot tell
    /// absent from broken and the package is the only fact worth showing.
    /// Nothing the model manager offers settles it, so it gets its own
    /// sentence.
    case aiCapabilityRuntimeMissing(String, String)
    /// An AI task the adapter does not offer at all: a product answer, not a
    /// queue. Kept as a token so a `-32020` refusal can be routed as data.
    case aiCapabilityUnsupported
    case settingsReset
    case backdropFailed
    case recentMissing(String)
    case renderingExport
    case upscaling(Int, Int)
    case saved(String)
    case exportFailed
    /// The requested 4× pass never started because the local AI helper cannot
    /// run on this machine, so nothing was written. A distinct fact from
    /// `exportFailed`: the photo was never rendered, not lost while saving.
    case exportUpscaleUnavailable
    /// The helper started and ran the 4× pass, but it did not produce a usable
    /// artifact. Nothing was written, and this is not a generic save failure.
    case exportUpscaleFailed
    case exportRefusedOriginal
    case exportCancelled
    case operationBusy
    case projectSaved(String)
    case projectSaveFailed
    case projectPhotoMissing
    case projectOpenFailed
    case projectTooNew(Int)
    case projectRelinked
    case recoveryStorageFailed
    case recoveryQuarantined(Int)
    case recoveryCandidateNotRemoved
    case recoveryNeedsNewerBuild([String])
    case batchStarting
    case batchProgress(Int, Int)
    case batchFinished(saved: Int, total: Int, cropsSkipped: Int, failed: Int)
    case batchCancelled
}
