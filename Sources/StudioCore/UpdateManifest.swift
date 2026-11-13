import Foundation

/// The portable half of the update system: what a signed update manifest says,
/// which release applies to this host, and exactly which bytes an Ed25519
/// signature must cover. Downloading, verifying and swapping the bundle belong
/// to the host; nothing here imports a networking or crypto framework.
public struct UpdateManifest: Codable, Equatable, Sendable {
    public static let supportedSchema = 1

    public var schema: Int
    public var channel: String
    public var generatedAt: String?
    public var releases: [UpdateRelease]

    public init(schema: Int = UpdateManifest.supportedSchema,
                channel: String = "stable",
                generatedAt: String? = nil,
                releases: [UpdateRelease]) {
        self.schema = schema
        self.channel = channel
        self.generatedAt = generatedAt
        self.releases = releases
    }
}

public struct UpdateRelease: Codable, Equatable, Sendable {
    /// Marketing version, three numeric components: "1.1.0".
    public var version: String
    /// Monotonic build number inside the version.
    public var build: Int
    public var publishedAt: String?
    public var notes: String?
    /// Oldest macOS/Windows version this release supports, three components.
    /// A release without one inherits the platform minimum.
    public var minimumSystemVersion: String?
    public var artifacts: [UpdateArtifact]

    public init(version: String, build: Int, publishedAt: String? = nil,
                notes: String? = nil, minimumSystemVersion: String? = nil,
                artifacts: [UpdateArtifact]) {
        self.version = version
        self.build = build
        self.publishedAt = publishedAt
        self.notes = notes
        self.minimumSystemVersion = minimumSystemVersion
        self.artifacts = artifacts
    }
}

public struct UpdateArtifact: Codable, Equatable, Sendable {
    /// "macos" or "windows".
    public var platform: String
    /// "arm64", "x86_64" or "universal".
    public var architecture: String
    /// The only container the installer knows how to unpack.
    public var format: String
    public var url: String
    public var size: Int
    public var sha256: String
    /// Base64 Ed25519 signature over `UpdatePolicy.descriptor`.
    public var signature: String

    public init(platform: String, architecture: String, format: String = "zip",
                url: String, size: Int, sha256: String, signature: String) {
        self.platform = platform
        self.architecture = architecture
        self.format = format
        self.url = url
        self.size = size
        self.sha256 = sha256
        self.signature = signature
    }
}

/// Three numeric components. Build numbers are compared separately, so a
/// rebuild of the same marketing version is still an update.
public struct SemanticVersion: Comparable, Equatable, Sendable, CustomStringConvertible {
    public var major: Int
    public var minor: Int
    public var patch: Int

    public init?(_ text: String) {
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3,
              let major = Int(parts[0]), let minor = Int(parts[1]), let patch = Int(parts[2]),
              major >= 0, minor >= 0, patch >= 0,
              parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isNumber) })
        else { return nil }
        self.major = major
        self.minor = minor
        self.patch = patch
    }

    public var description: String { "\(major).\(minor).\(patch)" }

    public static func < (lhs: SemanticVersion, rhs: SemanticVersion) -> Bool {
        (lhs.major, lhs.minor, lhs.patch) < (rhs.major, rhs.minor, rhs.patch)
    }
}

/// A platform version, two or three numeric components: macOS reports "14.5",
/// Windows can report "10.0.22631". Marketing versions stay stricter above.
public struct SystemVersion: Comparable, Equatable, Sendable, CustomStringConvertible {
    public var major: Int
    public var minor: Int
    public var patch: Int

    public init?(_ text: String) {
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 2 || parts.count == 3,
              parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isNumber) }),
              let major = Int(parts[0]), let minor = Int(parts[1])
        else { return nil }
        let patch = parts.count == 3 ? Int(parts[2]) : 0
        guard let patch else { return nil }
        self.major = major
        self.minor = minor
        self.patch = patch
    }

    public var description: String { "\(major).\(minor).\(patch)" }

    public static func < (lhs: SystemVersion, rhs: SystemVersion) -> Bool {
        (lhs.major, lhs.minor, lhs.patch) < (rhs.major, rhs.minor, rhs.patch)
    }
}

/// A release and the one artifact that fits this host, plus the exact bytes the
/// artifact signature covers.
public struct UpdatePlan: Equatable, Sendable {
    public var release: UpdateRelease
    public var artifact: UpdateArtifact
    public var descriptor: String
}

public enum UpdateDecision: Equatable, Sendable {
    case upToDate(current: String)
    /// A newer release exists but cannot be installed on this host. The reason
    /// is surfaced, never hidden: silently skipping a security release is worse
    /// than telling the owner their system is too old.
    case incompatible(reasons: [String])
    case available(UpdatePlan)
}

public enum UpdatePolicy {
    public static let macOS = "macos"
    public static let windows = "windows"
    public static let universal = "universal"
    public static let zip = "zip"

    /// Everything that names a file or a release, in a fixed order, with the
    /// hash lowercased. The signature covers this string and nothing implicit:
    /// changing the URL, the hash, the size or the version invalidates it.
    public static func descriptor(release: UpdateRelease, artifact: UpdateArtifact) -> String {
        [
            "retouchstudio-update-v1",
            "version=\(release.version)",
            "build=\(release.build)",
            "platform=\(artifact.platform)",
            "architecture=\(artifact.architecture)",
            "format=\(artifact.format)",
            "size=\(artifact.size)",
            "sha256=\(artifact.sha256.lowercased())",
            "url=\(artifact.url)"
        ].joined(separator: "\n")
    }

    /// Chooses the newest release above `currentVersion` that this host can
    /// install. `expectedChannel` is compared when given; an unknown schema is
    /// refused rather than guessed.
    public static func evaluate(manifest: UpdateManifest,
                                channel expectedChannel: String? = nil,
                                currentVersion: String,
                                currentBuild: Int,
                                platform: String,
                                architecture: String,
                                systemVersion: String) -> UpdateDecision {
        guard manifest.schema == UpdateManifest.supportedSchema else {
            return .incompatible(reasons: ["unsupported manifest schema \(manifest.schema)"])
        }
        if let expectedChannel, manifest.channel != expectedChannel {
            return .incompatible(reasons: ["manifest channel is \(manifest.channel), expected \(expectedChannel)"])
        }
        guard let current = SemanticVersion(currentVersion) else {
            return .incompatible(reasons: ["current version \(currentVersion) is not numeric"])
        }
        guard let host = SystemVersion(systemVersion) else {
            return .incompatible(reasons: ["system version \(systemVersion) is not numeric"])
        }

        let newer = manifest.releases.filter { release in
            guard let version = SemanticVersion(release.version) else { return false }
            return version > current || (version == current && release.build > currentBuild)
        }
        guard let release = newer.max(by: { lhs, rhs in
            // Both versions parsed in the filter above, so the force is safe.
            let left = SemanticVersion(lhs.version)!
            let right = SemanticVersion(rhs.version)!
            return left == right ? lhs.build < rhs.build : left < right
        }) else {
            return .upToDate(current: currentVersion)
        }

        var reasons: [String] = []
        if let minimum = release.minimumSystemVersion {
            if let minimumVersion = SystemVersion(minimum) {
                if host < minimumVersion {
                    reasons.append("release \(release.version) needs system \(minimum), this host has \(systemVersion)")
                }
            } else {
                reasons.append("release \(release.version) has an unreadable minimum system version")
            }
        }
        let matching = release.artifacts.filter {
            $0.platform == platform
                && ($0.architecture == architecture || $0.architecture == universal)
        }
        if matching.isEmpty {
            reasons.append("release \(release.version) has no \(platform) \(architecture) artifact")
        }
        let valid = matching.filter { artifact in
            artifact.format == zip
                && artifact.size > 0
                && isHTTPS(artifact.url)
                && isSHA256(artifact.sha256)
                && !artifact.signature.isEmpty
        }
        if matching.isEmpty == false, valid.isEmpty {
            reasons.append("release \(release.version) has no valid signed artifact for this host")
        }
        guard reasons.isEmpty, let artifact = valid.first else {
            return .incompatible(reasons: reasons)
        }
        return .available(UpdatePlan(release: release, artifact: artifact,
                                     descriptor: descriptor(release: release, artifact: artifact)))
    }

    static func isHTTPS(_ text: String) -> Bool {
        guard let url = URL(string: text), url.scheme?.lowercased() == "https", url.host != nil else {
            return false
        }
        return true
    }

    static func isSHA256(_ text: String) -> Bool {
        text.count == 64 && text.allSatisfy { $0.isHexDigit }
    }
}
