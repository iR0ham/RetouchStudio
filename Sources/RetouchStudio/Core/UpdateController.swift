import AppKit
import Combine
import Foundation
import StudioCore

/// The user-facing update flow: check a signed manifest, download only after
/// hash and signature verification, unpack, swap, and offer a relaunch. It
/// never installs without a signed plan and never replaces a bundle it cannot
/// write to. The About window owns the only entry point.
@MainActor
final class UpdateController: ObservableObject {
    enum Phase: Equatable {
        case idle
        case checking
        case upToDate(String)
        case available(UpdatePlan)
        case incompatible(String)
        case failed(String)
        case downloading(String)
        case readyToRelaunch(String)
    }

    @Published private(set) var phase: Phase = .idle

    static var journalURL: URL {
        let support = (try? FileManager.default.url(for: .applicationSupportDirectory,
                                                    in: .userDomainMask,
                                                    appropriateFor: nil,
                                                    create: true))
            ?? FileManager.default.temporaryDirectory
        return support.appendingPathComponent("RetouchStudio", isDirectory: true)
            .appendingPathComponent("update-journal.json")
    }

    init() {
        // A previous launch may have died between the two renames. Finish or
        // undo it before the editor opens.
        try? UpdateInstaller.recover(journalURL: Self.journalURL)
    }

    var isBusy: Bool {
        switch phase {
        case .checking, .downloading: return true
        case .idle, .upToDate, .available, .incompatible, .failed, .readyToRelaunch: return false
        }
    }

    func check() {
        guard !isBusy else { return }
        phase = .checking
        Task { await performCheck() }
    }

    func installAvailableUpdate() {
        guard case .available(let plan) = phase else { return }
        phase = .downloading(plan.release.version)
        Task { await performInstall(plan) }
    }

    func relaunch() {
        NSWorkspace.shared.open(Bundle.main.bundleURL)
        NSApp.terminate(nil)
    }

    private func performCheck() async {
        let feeds = Self.feedURLs
        guard !feeds.isEmpty else {
            phase = .failed(L10n.current.updateFeedMissing)
            return
        }
        var lastError = L10n.current.updateFeedMissing
        for url in feeds {
            do {
                let (data, response) = try await Self.fetch(url)
                guard data.count <= 1_048_576 else {
                    lastError = "The update manifest is larger than 1 MB."
                    continue
                }
                if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                    lastError = "The update feed returned HTTP \(http.statusCode)."
                    continue
                }
                let manifest = try JSONDecoder().decode(UpdateManifest.self, from: data)
                let decision = UpdatePolicy.evaluate(
                    manifest: manifest,
                    currentVersion: DeveloperProfile.version,
                    currentBuild: Int(DeveloperProfile.build) ?? 0,
                    platform: UpdatePolicy.macOS,
                    architecture: Self.architecture,
                    systemVersion: Self.systemVersion)
                switch decision {
                case .upToDate(let current):
                    phase = .upToDate(current)
                case .incompatible(let reasons):
                    phase = .incompatible(reasons.joined(separator: "; "))
                case .available(let plan):
                    // The manifest is unsigned as a document; the plan carries
                    // the exact bytes the artifact signature covers.
                    guard UpdateSignature.verify(descriptor: plan.descriptor,
                                                 signatureBase64: plan.artifact.signature) else {
                        phase = .failed("The update manifest is not signed by the release key.")
                        return
                    }
                    phase = .available(plan)
                }
                return
            } catch {
                lastError = error.localizedDescription
            }
        }
        phase = .failed(lastError)
    }

    private func performInstall(_ plan: UpdatePlan) async {
        // Staging beside the installed bundle keeps the final rename on one
        // volume; a cross-volume move is a copy that a crash can interrupt.
        let parent = Bundle.main.bundleURL.deletingLastPathComponent()
        let workspace = parent.appendingPathComponent(".retouch-update-\(UUID().uuidString)",
                                                      isDirectory: true)
        defer { try? FileManager.default.removeItem(at: workspace) }
        do {
            guard FileManager.default.isWritableFile(atPath: parent.path) else {
                throw UpdateInstallError.parentNotWritable(parent.path)
            }
            try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
            let archive = workspace.appendingPathComponent("update.zip")
            guard UpdateSignature.verify(descriptor: plan.descriptor,
                                         signatureBase64: plan.artifact.signature) else {
                throw UpdateInstallError.unpackFailed("the artifact signature no longer verifies")
            }
            try await UpdateDownloader.download(plan.artifact, to: archive)
            let app = try UpdateInstaller.unpack(archive: archive,
                                                 into: workspace.appendingPathComponent("payload"),
                                                 expectedVersion: plan.release.version,
                                                 bundleIdentifier: Bundle.main.bundleIdentifier ?? "")
            try FileManager.default.createDirectory(at: Self.journalURL.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try UpdateInstaller.swap(stagedApp: app, over: Bundle.main.bundleURL,
                                     journalURL: Self.journalURL)
            phase = .readyToRelaunch(plan.release.version)
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    private static func fetch(_ url: URL) async throws -> (Data, URLResponse) {
        guard url.scheme?.lowercased() == "https" else {
            throw UpdateDownloadError.insecureURL(url.absoluteString)
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        request.cachePolicy = .reloadIgnoringLocalCacheData
        return try await URLSession.shared.data(for: request)
    }

    /// Mirrors can be listed in Info.plist (`RSUpdateFeedURLs`); a single
    /// `RSUpdateFeedURL` is accepted too. No URL is compiled into the binary, so
    /// moving the feed never requires an update to find updates.
    private static var feedURLs: [URL] {
        let info = Bundle.main.infoDictionary
        let listed = info?["RSUpdateFeedURLs"] as? [String] ?? []
        let single = info?["RSUpdateFeedURL"] as? String
        return (listed + (single.map { [$0] } ?? []))
            .compactMap(URL.init(string:))
            .filter { $0.scheme?.lowercased() == "https" }
    }

    static var architecture: String {
        #if arch(arm64)
        return "arm64"
        #else
        return "x86_64"
        #endif
    }

    static var systemVersion: String {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        return "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)"
    }
}
