import CoreGraphics
import CoreImage
import Darwin
import Foundation
import ImageIO
import StudioCore
import UniformTypeIdentifiers

/// An explicit, headless proof that the packaged host can run the real 4×
/// upscaler. It is never part of an ordinary launch or the cheap worker ping.
struct PackagedUpscaleSelfTest {
    struct Options {
        let model: URL
        let output: URL
    }

    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    private struct ReferenceFixture {
        let outputs: [String: Data]
    }

    private static let modelID = "swin2sr-x4"
    private static let modelVersion = "1.0.0"
    private static let catalogAggregate = "e0da6778bbcffbb26d61fda450648998e22f66d5867924706fee6d929aa50cdf"
    private static let sourceSize = CGSize(width: 64, height: 48)

    /// `nil` means this is an ordinary launch. An requested inference test
    /// without both explicit paths is an error, never a silent skipped check.
    static func parse(_ arguments: [String]) throws -> Options? {
        var requested = false
        var model: String?
        var output: String?
        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            switch argument {
            case "--upscale-selftest":
                requested = true
            case "--model", "--out":
                guard index + 1 < arguments.count,
                      !arguments[index + 1].hasPrefix("--"),
                      !arguments[index + 1].isEmpty else {
                    throw Failure(message: "\(argument) requires a non-empty path")
                }
                if argument == "--model" {
                    guard model == nil else {
                        throw Failure(message: "--model may be supplied only once")
                    }
                    model = arguments[index + 1]
                } else {
                    guard output == nil else {
                        throw Failure(message: "--out may be supplied only once")
                    }
                    output = arguments[index + 1]
                }
                index += 1
            default:
                break
            }
            index += 1
        }
        guard requested else { return nil }
        guard let model, let output else {
            throw Failure(message: "--upscale-selftest requires --model and --out")
        }
        let modelURL = canonical(URL(fileURLWithPath: model))
        let outputURL = canonical(URL(fileURLWithPath: output))
        guard !outputURL.path.hasPrefix(modelURL.path + "/"),
              !modelURL.path.hasPrefix(outputURL.path + "/") else {
            throw Failure(message: "--out and --model must be separate directory trees")
        }
        try validateOutputSocketPath(outputURL)
        return Options(model: modelURL, output: outputURL)
    }

    private static func runtimeProbeDirectory(_ output: URL) -> URL {
        output.appendingPathComponent("ai-worker-state", isDirectory: true)
            .appendingPathComponent("probe", isDirectory: true)
    }

    /// `sockaddr_un.sun_path` is a fixed UTF-8 byte buffer. Validate both exact
    /// output-owned sockets before `run` creates a directory, writes the source
    /// PNG or copies the checkpoint; otherwise a long `--out` fails only after
    /// persistent artifacts have already been produced.
    static func validateOutputSocketPath(_ output: URL) throws {
        let state = output.appendingPathComponent("ai-worker-state", isDirectory: true)
        try validateSocketPath(state.appendingPathComponent("worker.sock"), label: "worker")
        try validateSocketPath(runtimeProbeDirectory(output).appendingPathComponent("worker.sock"),
                               label: "runtime probe")
    }

    private static func validateSocketPath(_ socket: URL, label: String) throws {
        let capacity = MemoryLayout.size(ofValue: sockaddr_un().sun_path)
        let bytes = socket.path.utf8.count
        guard bytes < capacity else {
            throw Failure(message: "the \(label) socket path is too long for AF_UNIX (\(bytes) UTF-8 bytes; maximum \(capacity - 1))")
        }
    }

    /// The worker reports the device twice: once as the job result's execution
    /// device and once as its provider label. Only an exact, supported agreement
    /// is observable evidence; a missing, contradictory or unknown value is not
    /// a reason to guess from the machine or from the output pixels.
    static func inferenceProvider(from payload: [String: Any]) -> String? {
        guard let provider = payload["provider"] as? String,
              let device = payload["device"] as? String,
              provider == device, provider == "mps" || provider == "cpu" else {
            return nil
        }
        return provider
    }

    /// The production bundle lookup is separate from the test-only checkout
    /// lookup so regressions can exercise the real packaged policy without
    /// compiling the app entry point or launching its UI.
    static func resolvePackagedReferenceDirectory(in bundle: Bundle) throws -> URL {
        guard let manifest = bundle.url(forResource: "manifest", withExtension: "json",
                                        subdirectory: "Tests/Fixtures/upscale-m3") else {
            throw Failure(message: "the app bundle does not contain the independent M3 reference fixture")
        }
        return manifest.deletingLastPathComponent()
    }

    /// Test builds read the checkout fixture explicitly. A packaged diagnostic
    /// resolves only its sealed bundle copy; it never searches the owner's
    /// filesystem or infers a reference from the machine it happens to run on.
    private static func resolveReferenceDirectory(explicit: URL?) throws -> URL {
        if let explicit { return explicit }
        #if RETOUCH_TESTING
        let testsRoot = ProcessInfo.processInfo.environment["RETOUCH_TESTS_ROOT"]
            ?? FileManager.default.currentDirectoryPath
        return URL(fileURLWithPath: testsRoot)
            .appendingPathComponent("Tests/Fixtures/upscale-m3", isDirectory: true)
        #else
        return try resolvePackagedReferenceDirectory(in: .main)
        #endif
    }

    /// Loads the small, reviewed fixture set and binds it to the trusted catalog
    /// entry and the exact RGB8 bytes submitted by the host. Every payload is a
    /// regular non-symlink file whose measured size and SHA-256 match the
    /// manifest. The manifest is not a tolerance grant: this build accepts only
    /// its explicit `NOT SET` value and compares final RGB8 bytes exactly.
    private static func loadReferenceFixture(model: ModelCatalogEntry,
                                             sourceSize: CGSize,
                                             inputSHA256: String,
                                             directory: URL) throws -> ReferenceFixture {
        guard sourceSize.width == Self.sourceSize.width,
              sourceSize.height == Self.sourceSize.height,
              inputSHA256.count == 64,
              inputSHA256.allSatisfy(\.isHexDigit) else {
            throw Failure(message: "the independent reference requires the exact 64×48 RGB8 fixture")
        }
        let required = Set(["config.json", "preprocessor_config.json", "pytorch_model.bin"])
        guard model.id == modelID, model.version == modelVersion,
              model.format == "pytorch",
              model.capabilities.contains(AICapabilityReport.upscale4x),
              model.sha256 == catalogAggregate,
              model.unverifiableReason == nil,
              model.files.count == required.count else {
            throw Failure(message: "the independent reference has no exact trusted Swin2SR catalog context")
        }
        var trustedFiles: [String: ModelCatalogFile] = [:]
        for file in model.files {
            guard required.contains(file.path), file.isVerifiable,
                  trustedFiles[file.path] == nil else {
                throw Failure(message: "the independent reference catalog has invalid checkpoint pins")
            }
            trustedFiles[file.path] = file
        }
        guard Set(trustedFiles.keys) == required else {
            throw Failure(message: "the independent reference catalog is missing a checkpoint file")
        }

        let directoryFD = try SecureFileIO.openDirectory(directory)
        defer { close(directoryFD) }
        let manifestData = try SecureFileIO.readFile(in: directoryFD, name: "manifest.json")
        guard let manifest = (try? JSONSerialization.jsonObject(with: manifestData)) as? [String: Any],
              manifest["schema"] as? String == "retouchstudio.m3-reference-fixture/1",
              manifest["status"] as? String == "COMPLETE",
              manifest["evidence_class"] as? String
                == "developer-runtime; not packaged-app or clean-install evidence",
              manifest["final_tolerance"] as? String == "NOT SET",
              let modelRecord = manifest["model"] as? [String: Any],
              modelRecord["id"] as? String == modelID,
              modelRecord["version"] as? String == modelVersion,
              modelRecord["format"] as? String == "pytorch",
              modelRecord["capability"] as? String == AICapabilityReport.upscale4x,
              manifest["catalog_aggregate_sha256"] as? String == catalogAggregate,
              let fixture = manifest["fixture"] as? [String: Any],
              let sourceRecord = fixture["source_rgb"] as? [String: Any],
              let inputRecord = fixture["input_f32"] as? [String: Any],
              let contract = manifest["fixture_contract"] as? [String: Any],
              contract["source_rgb_shape"] as? [Int] == [48, 64, 3],
              contract["input_f32_shape"] as? [Int] == [1, 3, 48, 64],
              contract["expected_output_shape"] as? [Int] == [192, 256, 3],
              let outputs = manifest["outputs"] as? [String: Any],
              Set(outputs.keys) == Set(["mps", "cpu"]),
              let bicubic = manifest["bicubic"] as? [String: Any],
              bicubic["resampling"] as? String == "Pillow BICUBIC" else {
            throw Failure(message: "the independent M3 reference manifest is incomplete or unbound")
        }

        func readAsset(_ record: [String: Any], path: String, bytes: Int) throws -> Data {
            guard record["path"] as? String == path,
                  record["bytes"] as? Int == bytes,
                  let digest = record["sha256"] as? String,
                  digest.count == 64, digest.allSatisfy(\.isHexDigit) else {
                throw Failure(message: "the independent reference manifest has an invalid \(path) pin")
            }
            let data = try SecureFileIO.readFile(in: directoryFD, name: path)
            guard data.count == bytes, SecureFileIO.sha256(of: data) == digest else {
                throw Failure(message: "the independent reference asset \(path) does not match its pin")
            }
            return data
        }

        guard let checkpoint = manifest["checkpoint"] as? [[String: Any]],
              checkpoint.count == required.count else {
            throw Failure(message: "the independent reference does not pin the exact three-file checkpoint")
        }
        var seenCheckpoint = Set<String>()
        for record in checkpoint {
            guard Set(record.keys) == Set(["path", "sha256", "sizeBytes"]),
                  let path = record["path"] as? String,
                  let trusted = trustedFiles[path],
                  record["sizeBytes"] as? Int == trusted.sizeBytes,
                  record["sha256"] as? String == trusted.sha256,
                  seenCheckpoint.insert(path).inserted else {
                throw Failure(message: "the independent reference checkpoint differs from the trusted catalog")
            }
        }
        guard seenCheckpoint == required else {
            throw Failure(message: "the independent reference checkpoint is incomplete")
        }

        _ = try readAsset(sourceRecord, path: "source.rgb", bytes: 64 * 48 * 3)
        _ = try readAsset(inputRecord, path: "input.f32", bytes: 1 * 3 * 48 * 64 * 4)
        _ = try readAsset(bicubic, path: "bicubic.rgb", bytes: 192 * 256 * 3)
        guard let sourceDigest = sourceRecord["sha256"] as? String,
              inputSHA256 == sourceDigest else {
            throw Failure(message: "the submitted RGB8 input is not the independent reference source")
        }

        var references: [String: Data] = [:]
        for provider in ["mps", "cpu"] {
            guard let record = outputs[provider] as? [String: Any],
                  record["provider"] as? String == provider else {
                throw Failure(message: "the independent reference has no truthful \(provider) output record")
            }
            references[provider] = try readAsset(
                record, path: "reference.\(provider).rgb", bytes: 192 * 256 * 3)
        }
        return ReferenceFixture(outputs: references)
    }

    /// Resolves every existing ancestor, so a temporary-directory alias or any
    /// other symlink alias cannot make two overlapping trees look disjoint.
    private static func canonical(_ url: URL) -> URL {
        let manager = FileManager.default
        var existing = url
        var missing: [String] = []
        while !manager.fileExists(atPath: existing.path) {
            let parent = existing.deletingLastPathComponent()
            guard parent.path != existing.path else { break }
            missing.insert(existing.lastPathComponent, at: 0)
            existing = parent
        }
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        if let resolved = realpath(existing.path, &buffer) {
            var result = URL(fileURLWithPath: String(cString: resolved))
            for component in missing { result.appendPathComponent(component) }
            return result
        }
        return url.resolvingSymlinksInPath()
    }

    /// Validates the exact active checkpoint and copies only its active version
    /// into test-owned support. The owner's tree is never opened for writing.
    static func copyModel(from source: URL, to destination: URL) throws {
        let catalog = try ModelCatalog.bundled()
        guard let entry = catalog.entry(id: modelID) else {
            throw Failure(message: "the bundled catalog does not contain \(modelID)")
        }
        try copyModel(from: source, to: destination, entry: entry)
    }

    /// The entry is explicit so command-line tests can load the same bundled
    /// catalog from the checkout without pretending their scratch executable is
    /// an app bundle. Production admission always enters through the overload
    /// above and therefore always uses `ModelCatalog.bundled()`.
    static func copyModel(from source: URL, to destination: URL,
                          entry: ModelCatalogEntry) throws {
        let manager = FileManager.default
        guard source.lastPathComponent == modelID else {
            throw Failure(message: "--model must name a real \(modelID) directory")
        }
        let sourceDirectory = try SecureFileIO.openDirectory(source)
        defer { close(sourceDirectory) }
        let versionDirectory = try SecureFileIO.openDirectory(
            in: sourceDirectory, name: modelVersion)
        defer { close(versionDirectory) }
        let manifestData = try SecureFileIO.readFile(
            in: versionDirectory, name: "manifest.json")
        let activeData = try SecureFileIO.readFile(
            in: sourceDirectory, name: "active.json")
        guard let manifest = (try? JSONSerialization.jsonObject(with: manifestData)) as? [String: Any],
              let active = (try? JSONSerialization.jsonObject(with: activeData)) as? [String: Any] else {
            throw Failure(message: "the active model records are not valid JSON")
        }
        guard entry.id == modelID,
              entry.version == modelVersion,
              entry.format == "pytorch",
              entry.sha256 == "e0da6778bbcffbb26d61fda450648998e22f66d5867924706fee6d929aa50cdf",
              entry.unverifiableReason == nil else {
            throw Failure(message: "the bundled catalog does not pin exact \(modelID) \(modelVersion)")
        }
        let required = Set(["config.json", "preprocessor_config.json", "pytorch_model.bin"])
        var trustedFiles: [String: ModelCatalogFile] = [:]
        for file in entry.files {
            guard required.contains(file.path), file.isVerifiable,
                  trustedFiles[file.path] == nil else {
                throw Failure(message: "the bundled Swin2SR catalog has an invalid file pin")
            }
            trustedFiles[file.path] = file
        }
        guard Set(trustedFiles.keys) == required,
              manifest["schema"] as? String == "retouchstudio.model-manifest/1",
              manifest["modelId"] as? String == modelID,
              manifest["version"] as? String == modelVersion,
              manifest["manifestSha256"] as? String == entry.sha256,
              active["schema"] as? String == "retouchstudio.model-active/1",
              active["modelId"] as? String == modelID,
              active["version"] as? String == modelVersion,
              active["manifestSha256"] as? String == entry.sha256 else {
            throw Failure(message: "the active record does not identify the trusted \(modelID) \(modelVersion)")
        }
        guard let files = manifest["files"] as? [[String: Any]], files.count == required.count else {
            throw Failure(message: "the Swin2SR manifest does not contain the exact three-file checkpoint")
        }
        var seen = Set<String>()
        for file in files {
            guard let path = file["path"] as? String,
                  let trusted = trustedFiles[path],
                  let size = file["sizeBytes"] as? Int,
                  let digest = file["sha256"] as? String,
                  size == trusted.sizeBytes,
                  digest == trusted.sha256,
                  !seen.contains(path) else {
                throw Failure(message: "the Swin2SR manifest does not match the trusted file pins")
            }
            seen.insert(path)
        }
        guard seen == required else {
            throw Failure(message: "the active Swin2SR version is incomplete")
        }

        try manager.createDirectory(at: destination.deletingLastPathComponent(),
                                    withIntermediateDirectories: true)
        let parent = try SecureFileIO.openDirectory(destination.deletingLastPathComponent())
        defer { close(parent) }
        var createdDestination = false
        do {
            let modelDestination = try SecureFileIO.createDirectory(
                in: parent, name: destination.lastPathComponent)
            createdDestination = true
            defer { close(modelDestination) }
            let versionDestination = try SecureFileIO.createDirectory(
                in: modelDestination, name: modelVersion)
            defer { close(versionDestination) }
            for path in required.sorted() {
                let trusted = trustedFiles[path]!
                let file = try SecureFileIO.openRegularFile(
                    in: versionDirectory, name: path)
                defer { close(file.descriptor) }
                try SecureFileIO.copy(
                    file.descriptor, info: file.info, toDirectory: versionDestination,
                    name: path, expectedSize: trusted.sizeBytes,
                    expectedSHA256: trusted.sha256)
            }
            try SecureFileIO.write(manifestData,
                                                  toDirectory: versionDestination, name: "manifest.json")
            try SecureFileIO.write(activeData,
                                                  toDirectory: modelDestination, name: "active.json")
        } catch {
            // EEXIST is a refusal, not ownership of the existing tree. Only a
            // destination this invocation created may be removed on rollback.
            if createdDestination { try? manager.removeItem(at: destination) }
            throw error
        }
    }

    /// Runs the same submission, wait and provenance-adoption implementation as
    /// export. A successful verdict therefore means a real helper produced a
    /// verified artifact; a stub or nearest-neighbour resize cannot pass it.
    static func run(_ options: Options) throws {
        try validateOutputSocketPath(options.output)
        let manager = FileManager.default
        guard !manager.fileExists(atPath: options.output.path) else {
            throw Failure(message: "--out must name a new directory")
        }
        try manager.createDirectory(at: options.output, withIntermediateDirectories: true)
        let source = syntheticImage()
        let sourceURL = options.output.appendingPathComponent("source.png")
        try writePNG(source, to: sourceURL)
        let sourceDigest = try ExportService.rgb8SHA256(of: sourceURL)
        let referenceDirectory = try resolveReferenceDirectory(explicit: nil)
        _ = try loadReferenceFixture(model: try ExportService.trustedUpscaleEntry(),
                                     sourceSize: sourceSize, inputSHA256: sourceDigest,
                                     directory: referenceDirectory)
        print("UPSCALE SELFTEST: independent M3 reference fixture verified")
        let support = options.output.appendingPathComponent("ai-worker-state", isDirectory: true)
        try copyModel(from: options.model,
                      to: support.appendingPathComponent("models/\(modelID)", isDirectory: true))

        guard let root = AIWorker.bundledRoot else {
            throw Failure(message: "this app does not contain its required bundled Worker")
        }
        unsetenv("RETOUCH_AI_PYTHON")
        unsetenv("RETOUCH_AI_WORKER_ROOT")
        setenv("RETOUCH_AI_MODELS", support.appendingPathComponent("models").path, 1)
        AIWorker.supportDirectoryOverride = support
        AIWorker.workingDirectoryOverride = support.appendingPathComponent("working", isDirectory: true)
        WorkerClient.selectSocket(support.appendingPathComponent("worker.sock").path)
        defer {
            AIWorker.terminate()
            WorkerClient.selectSocket(nil)
            AIWorker.workingDirectoryOverride = nil
            AIWorker.supportDirectoryOverride = nil
        }

        let validation = AIRuntimeValidation.functional(
            root: root, timeout: 120, stateRoot: support,
            handshakeProbeDirectory: runtimeProbeDirectory(options.output))
        guard validation.ok else {
            throw Failure(message: "packaged runtime validation failed: \(validation.logLine)")
        }
        print("UPSCALE SELFTEST: submitting \(Int(sourceSize.width))×\(Int(sourceSize.height)) real 4× job")
        let result = try ExportService.upscaleArtifact(source) { done, total in
            print("UPSCALE SELFTEST: tile \(done)/\(total)")
        }
        guard let problem = validateOutput(result.image, inputSize: sourceSize, source: source) else {
            try adopt(result, sourceSize: sourceSize, outputDirectory: options.output,
                      referenceDirectory: referenceDirectory)
            print("UPSCALE SELFTEST: PASS")
            print("UPSCALE SELFTEST: output \(options.output.appendingPathComponent("upscaled.png").path)")
            return
        }
        throw Failure(message: problem)
    }

    /// The real diagnostic always supplies `referenceDirectory`. Leaving it
    /// nil is a foundation-only test seam for the earlier provenance/adoption
    /// checks; it cannot be reached from `run(_:)`.
    static func adopt(_ result: ExportService.UpscaleArtifact,
                      sourceSize: CGSize, outputDirectory: URL,
                      referenceDirectory: URL? = nil) throws {
        let outputName = "upscaled.png"
        let sidecarName = outputName + AIProvenance.sidecarSuffix
        guard let jobID = result.jobID, let inputSHA256 = result.inputSHA256,
              let model = result.model else {
            throw Failure(message: "the upscale result has no trusted submission context")
        }
        let reference: Data?
        if let referenceDirectory {
            guard let provider = result.provider, provider == "mps" || provider == "cpu" else {
                throw Failure(message: "the real inference provider cannot be observed truthfully")
            }
            let fixture = try loadReferenceFixture(model: model, sourceSize: sourceSize,
                                                   inputSHA256: inputSHA256,
                                                   directory: referenceDirectory)
            guard let selected = fixture.outputs[provider] else {
                throw Failure(message: "the independent reference has no output for \(provider)")
            }
            reference = selected
        } else {
            reference = nil
        }
        let outputDirectoryFD = try SecureFileIO.openDirectory(outputDirectory)
        defer { close(outputDirectoryFD) }
        let artifactParent = try SecureFileIO.openDirectory(
            result.artifact.deletingLastPathComponent())
        defer { close(artifactParent) }
        let artifactFile = try SecureFileIO.openRegularFile(
            in: artifactParent, name: result.artifact.lastPathComponent)
        defer { close(artifactFile.descriptor) }
        let sidecarParent = try SecureFileIO.openDirectory(
            result.provenance.deletingLastPathComponent())
        defer { close(sidecarParent) }
        let sidecarFile = try SecureFileIO.openRegularFile(
            in: sidecarParent, name: result.provenance.lastPathComponent)
        defer { close(sidecarFile.descriptor) }

        var createdArtifact = false
        var createdSidecar = false
        do {
            try SecureFileIO.copy(
                artifactFile.descriptor, info: artifactFile.info,
                toDirectory: outputDirectoryFD, name: outputName)
            createdArtifact = true
            try SecureFileIO.copy(
                sidecarFile.descriptor, info: sidecarFile.info,
                toDirectory: outputDirectoryFD, name: sidecarName)
            createdSidecar = true

            _ = try ExportService.verifyUpscaleProvenance(
                path: outputDirectory.appendingPathComponent(outputName).path,
                sidecarPath: outputDirectory.appendingPathComponent(sidecarName).path,
                jobID: jobID, inputSHA256: inputSHA256, model: model)
            let outputData = try SecureFileIO.readFile(
                in: outputDirectoryFD, name: outputName)
            guard let copiedSource = CGImageSourceCreateWithData(outputData as CFData, nil),
                  let copiedImage = CGImageSourceCreateImageAtIndex(copiedSource, 0, nil) else {
                throw Failure(message: "the adopted output cannot be decoded")
            }
            let finalImage = CIImage(cgImage: copiedImage)
            if let problem = validateOutput(finalImage, inputSize: sourceSize) {
                throw Failure(message: problem)
            }
            guard let expectedPixels = rgba(result.image, size: finalImage.extent.size),
                  let finalPixels = rgba(finalImage, size: finalImage.extent.size),
                  expectedPixels == finalPixels else {
                throw Failure(message: "the adopted output pixels differ from the validated worker result")
            }
            if let reference {
                guard let finalRGB = rgb8(finalPixels), Data(finalRGB) == reference else {
                    throw Failure(message: "the final decoded RGB8 output differs from the independent reference")
                }
            }
            let sidecarData = try SecureFileIO.readFile(
                in: outputDirectoryFD, name: sidecarName)
            guard let record = (try? JSONSerialization.jsonObject(with: sidecarData)) as? [String: Any],
                  record["schema"] as? String == AIProvenance.schema,
                  record["capabilityId"] as? String == AICapabilityReport.upscale4x,
                  record["state"] as? String == "succeeded",
                  let geometry = record["output"] as? [String: Any],
                  geometry["width"] as? Int == Int(sourceSize.width * 4),
                  geometry["height"] as? Int == Int(sourceSize.height * 4) else {
                throw Failure(message: "the real output provenance does not identify exact Swin2SR 4×")
            }
            if referenceDirectory != nil {
                let sidecarProvider = (record["model"] as? [String: Any])?["provider"] as? String
                guard sidecarProvider == result.provider,
                      let input = record["input"] as? [String: Any],
                      input["width"] as? Int == 64,
                      input["height"] as? Int == 48,
                      input["bitDepth"] as? Int == 8,
                      input["channels"] as? Int == 3 else {
                    throw Failure(message: "the real output provenance cannot forge the provider or source geometry")
                }
                if let provider = result.provider {
                    print("UPSCALE SELFTEST: independent \(provider) RGB8 reference matched exactly")
                }
            }
            print("UPSCALE SELFTEST: provenance \(AICapabilityReport.upscale4x), \(modelID) \(modelVersion), scale 4")
            print("UPSCALE SELFTEST: sha256 \(SecureFileIO.sha256(of: outputData))")
        } catch {
            // Remove only names this invocation created. A same-user attacker
            // replacing a pathname between creation and cleanup remains a
            // residual race; descriptor checks do not make directory ownership
            // a security boundary.
            if createdSidecar { SecureFileIO.unlink(in: outputDirectoryFD, name: sidecarName) }
            if createdArtifact { SecureFileIO.unlink(in: outputDirectoryFD, name: outputName) }
            throw error
        }
    }

    /// A deterministic RGB edge/texture fixture. It is detailed enough that a
    /// nearest-neighbour 4× resize is observably not the model's result.
    static func syntheticImage() -> CIImage {
        let width = Int(sourceSize.width), height = Int(sourceSize.height)
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let offset = (y * width + x) * 4
                let checker = ((x / 4) + (y / 4)) % 2 == 0 ? 1.0 : 0.0
                let edge = x % 16 < 2 || y % 12 < 2 ? 1.0 : 0.0
                let red = 20.0 + Double(x * 3) + 150.0 * edge
                let green = 30.0 + Double(y * 4) + 130.0 * checker
                let blue = 220.0 - Double(x * 2 + y) + 100.0 * edge * checker
                bytes[offset] = UInt8(max(0, min(255, Int(red.rounded()))))
                bytes[offset + 1] = UInt8(max(0, min(255, Int(green.rounded()))))
                bytes[offset + 2] = UInt8(max(0, min(255, Int(blue.rounded()))))
                bytes[offset + 3] = 255
            }
        }
        let data = Data(bytes) as CFData
        guard let provider = CGDataProvider(data: data),
              let image = CGImage(width: width, height: height, bitsPerComponent: 8,
                                 bitsPerPixel: 32, bytesPerRow: width * 4,
                                 space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                 bitmapInfo: [.byteOrder32Big, CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)],
                                 provider: provider,
                                 decode: nil, shouldInterpolate: false,
                                 intent: .defaultIntent) else {
            fatalError("the deterministic upscale fixture could not be created")
        }
        return CIImage(cgImage: image)
    }

    /// Returns nil only for exact 4× geometry, non-degenerate pixels and a
    /// measurable difference from a nearest-neighbour resize of the input.
    static func validateOutput(_ image: CIImage, inputSize: CGSize,
                               source: CIImage? = nil) -> String? {
        let expected = CGSize(width: inputSize.width * 4, height: inputSize.height * 4)
        guard image.extent.origin == .zero,
              image.extent.size.width == expected.width,
              image.extent.size.height == expected.height else {
            return "the output is not exactly 4× the input dimensions"
        }
        guard let pixels = rgba(image, size: expected) else {
            return "the output pixels could not be decoded"
        }
        var minimum = 255, maximum = 0
        for offset in stride(from: 0, to: pixels.count, by: 4) {
            for channel in pixels[offset..<offset + 3] {
                minimum = min(minimum, Int(channel))
                maximum = max(maximum, Int(channel))
            }
        }
        guard maximum - minimum > 1 else { return "the output is a constant image" }
        if let source, let input = rgba(source, size: expected, interpolation: .none) {
            var total = 0
            for offset in stride(from: 0, to: pixels.count, by: 4) {
                for channel in 0..<3 {
                    total += abs(Int(pixels[offset + channel]) - Int(input[offset + channel]))
                }
            }
            let mean = Double(total) / Double(expected.width * expected.height * 3)
            guard mean > 0.05 else {
                return String(format: "the output matches nearest-neighbour 4× (mean delta %.4f)", mean)
            }
            print(String(format: "UPSCALE SELFTEST: nearest-neighbour mean pixel delta %.4f", mean))
        }
        return nil
    }

    private static func rgb8(_ rgba: [UInt8]) -> [UInt8]? {
        guard rgba.count % 4 == 0 else { return nil }
        var rgb = [UInt8]()
        rgb.reserveCapacity(rgba.count / 4 * 3)
        for offset in stride(from: 0, to: rgba.count, by: 4) {
            rgb.append(contentsOf: rgba[offset..<offset + 3])
        }
        return rgb
    }

    private static func rgba(_ image: CIImage, size: CGSize,
                             interpolation: CGInterpolationQuality = .default) -> [UInt8]? {
        guard let source = CIContext().createCGImage(image, from: image.extent) else { return nil }
        let width = Int(size.width), height = Int(size.height)
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        guard let context = CGContext(data: &bytes, width: width, height: height,
                                      bitsPerComponent: 8, bytesPerRow: width * 4,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: [.byteOrder32Big, CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)]) else { return nil }
        context.interpolationQuality = interpolation
        context.draw(source, in: CGRect(origin: .zero, size: size))
        return bytes
    }

    private static func writePNG(_ image: CIImage, to url: URL) throws {
        guard let cgImage = CIContext().createCGImage(image, from: image.extent),
              let destination = CGImageDestinationCreateWithURL(
                url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw Failure(message: "the synthetic source PNG could not be created")
        }
        CGImageDestinationAddImage(destination, cgImage, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw Failure(message: "the synthetic source PNG could not be written")
        }
    }

    private static func regularFile(_ url: URL) -> Bool {
        guard let values = try? url.resourceValues(
            forKeys: [.isRegularFileKey, .isSymbolicLinkKey]),
              values.isRegularFile == true, values.isSymbolicLink != true else {
            return false
        }
        return true
    }

    private static func json(_ url: URL) throws -> [String: Any] {
        guard let data = try? Data(contentsOf: url),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw Failure(message: "could not read JSON record \(url.lastPathComponent)")
        }
        return object
    }
}
