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
    case settingsReset
    case backdropFailed
    case recentMissing(String)
    case renderingExport
    case upscaling(Int, Int)
    case saved(String)
    case exportFailed
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
    case batchFinished(saved: Int, total: Int, cropsSkipped: Int)
    case batchCancelled
}
