import Foundation

/// The two facts a manager row used to state as one.
///
/// The store answers whether weights are on disk. Only the worker runtime
/// answers whether the helper on this Mac can execute them. A shipped light
/// build carries no Python runtime and no package metadata, so a version can
/// be installed and verified while no AI job can run; calling that row
/// "Installed" alone implied the model would run.
enum ModelRunState: Equatable {
    /// No version of this model is on disk.
    case missing
    /// Weights are on disk, but the helper cannot start here, so nothing can
    /// execute them. Installing, verifying and removing are still meaningful.
    case installedNotRunnable
    /// Weights are on disk and the helper can start.
    case runnable

    static func resolve(weightsInstalled: Bool, helperCanRun: Bool) -> ModelRunState {
        guard weightsInstalled else { return .missing }
        return helperCanRun ? .runnable : .installedNotRunnable
    }

    var hasWeights: Bool { self != .missing }
    var isRunnable: Bool { self == .runnable }
}
