import Foundation

/// One record from the worker's `capability.list` (W5-0 vocabulary
/// `capabilities/1`). The host validates the whole report instead of trusting
/// it: an unknown or duplicate id, a missing vocabulary entry, support without
/// evidence, or a non-supported state without a reason rejects it outright.
struct AICapability: Equatable, Identifiable {
    enum State: String {
        case supported
        case requiresModel = "requires_model"
        case blocked
        case unsupported
    }

    let id: String
    let state: State
    let provider: String
    let modelId: String?
    let modelVersion: String?
    let evidence: String?
    let reason: String?
}

struct AICapabilityReport: Equatable {
    static let vocabulary = "capabilities/1"
    /// The frozen W5-0 ids. A report that omits one is not the whole answer.
    static let vocabularyIds = [
        "face.analysis", "face.parsing", "mask.subject", "mask.click",
        "matte.fine", "inpaint.spot", "inpaint.object", "generative.edit",
        "generative.reimagine", "generative.outpaint", "background.replace",
        "upscale.2x", "upscale.4x", "enhance.photo", "restore.photo",
        "portrait.ai",
    ]

    let platform: String
    let provider: String
    let capabilities: [AICapability]

    func find(_ id: String) -> AICapability? {
        capabilities.first { $0.id == id }
    }

    init?(payload: [String: Any]) {
        guard payload["vocabulary"] as? String == Self.vocabulary,
              let platform = payload["platform"] as? String,
              let provider = payload["provider"] as? String,
              let records = payload["capabilities"] as? [[String: Any]] else {
            return nil
        }
        var seen = Set<String>()
        var parsed: [AICapability] = []
        for record in records {
            guard let id = record["capabilityId"] as? String,
                  Self.vocabularyIds.contains(id),
                  seen.insert(id).inserted,
                  let raw = record["state"] as? String,
                  let state = AICapability.State(rawValue: raw) else {
                return nil
            }
            let evidence = record["evidence"] as? String
            let reason = record["reason"] as? String
            if state == .supported {
                guard let evidence, !evidence.isEmpty else { return nil }
            } else {
                guard let reason, !reason.isEmpty else { return nil }
            }
            parsed.append(AICapability(
                id: id,
                state: state,
                provider: record["provider"] as? String ?? provider,
                modelId: record["modelId"] as? String,
                modelVersion: record["modelVersion"] as? String,
                evidence: evidence,
                reason: reason))
        }
        guard seen.count == Self.vocabularyIds.count else { return nil }
        self.platform = platform
        self.provider = provider
        self.capabilities = parsed
    }
}

enum AICapabilityClient {
    /// Asks the worker what this adapter can actually run. The worker answers
    /// from installed models, the provider and its recorded evidence; the host
    /// only formats the answer.
    static func fetch(timeout: TimeInterval = 8) throws -> AICapabilityReport {
        let reply = try WorkerClient().call("capability.list", timeout: timeout)
        guard let payload = reply as? [String: Any],
              let report = AICapabilityReport(payload: payload) else {
            throw AIWorkerFailure(code: -32603, message: L10n.current.aiBadReply)
        }
        return report
    }
}

/// The `retouchstudio.ai.provenance/1` sidecar that W5-0 §3.6 requires beside
/// every artifact the host adopts. The helper writes the sidecar first and the
/// artifact second, so a file the host is told about arrives with the record
/// that names its bytes; this is the host half of that agreement.
///
/// A pair that does not agree is refused rather than shown. The sidecar is the
/// only evidence that a rendered file is the output of the job the user asked
/// for, so adopting an artifact whose record is missing, of another schema,
/// filed somewhere other than beside it, or naming different bytes would put
/// an unaccountable edit in front of a user as if it were their own.
enum AIProvenance {
    static let schema = "retouchstudio.ai.provenance/1"
    static let sidecarSuffix = ".provenance.json"

    /// The artifact at `path`, once the sidecar named `sidecarPath` has been
    /// read and the digest it records matched against those bytes.
    static func verifiedArtifact(path: String?,
                                 sidecarPath: String?) throws -> URL {
        guard let path, !path.isEmpty, let sidecarPath, !sidecarPath.isEmpty else {
            throw refusal("the helper returned an artifact with no provenance")
        }
        let artifact = URL(fileURLWithPath: path)
        let sidecar = URL(fileURLWithPath: sidecarPath)
        guard sidecar.lastPathComponent == artifact.lastPathComponent + sidecarSuffix,
              sidecar.deletingLastPathComponent().path
                == artifact.deletingLastPathComponent().path else {
            throw refusal("the provenance is not the sidecar of this artifact")
        }
        guard let data = try? Data(contentsOf: sidecar),
              let record = (try? JSONSerialization.jsonObject(with: data))
                as? [String: Any],
              record["schema"] as? String == schema,
              let recorded = (record["output"] as? [String: Any])?["sha256"]
                as? String,
              let actual = try? AIRuntime.sha256(of: artifact),
              recorded == actual else {
            throw refusal("the provenance does not describe these bytes")
        }
        return artifact
    }

    private static func refusal(_ detail: String) -> AIWorkerFailure {
        AIWorkerFailure(code: -32603, message: detail)
    }
}
