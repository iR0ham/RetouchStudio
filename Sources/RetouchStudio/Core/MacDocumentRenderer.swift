import CoreGraphics
import Foundation
import StudioCore
import UniformTypeIdentifiers

// The macOS side of the renderer port. Everything below the port still runs on
// the existing Core Image pipeline; only the decisions and the request cross
// the boundary.

extension ExportFormat {
    var utType: UTType {
        switch self {
        case .jpeg: return .jpeg
        case .png: return .png
        case .tiff: return .tiff
        case .heic: return .heic
        }
    }
}

extension RenderColorSpace {
    /// The concrete profile for a decision. `.source` means the caller supplies
    /// the decoded photo's own profile, so it has no value of its own.
    var cgColorSpace: CGColorSpace? {
        switch self {
        case .sRGB:
            return CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        case .source:
            return nil
        }
    }
}

/// Turns a portable request into pixels with the macOS pipeline and writes the
/// result through the same source-protecting writer as before.
struct MacDocumentRenderer: DocumentRenderPipeline {
    typealias Source = ExportSource
    typealias Output = RenderedExport

    /// What a direct `write` asks at the commit point. A batch leaves this
    /// false: a cancel that arrives while a file is being written must not
    /// throw that file away — the loop stops before the next one. A single
    /// export goes through `renderAndWrite`, which forwards its own job's
    /// cancellation instead.
    var commitCancellation: @Sendable () -> Bool = { false }

    func render(_ request: RenderRequest, source: ExportSource,
                progress: ((RenderProgress) -> Void)?) throws -> RenderedExport {
        if Task.isCancelled { throw RenderError.cancelled }
        let plan = RenderPolicy.plan(request, source: source.renderDescription)
        do {
            guard let rendered = try ExportService.renderFinal(
                request, source: source, plan: plan,
                progress: { done, total in
                    progress?(RenderProgress(stage: .upscaling,
                                             completed: done, total: total))
                }) else { throw RenderError.renderFailed }
            return rendered
        } catch let error as RenderError {
            throw error
        } catch {
            throw Self.map(error)
        }
    }

    /// The batch's entry point. `EditorModel.exportOne` has already checked
    /// cancellation before calling this, so a cancel seen only at the commit
    /// point still finishes the file in flight.
    func write(_ output: RenderedExport, request: RenderRequest,
               source: ExportSource, to destination: URL,
               protecting protectedURL: URL?) throws -> RenderResult {
        try write(output, request: request, source: source, to: destination,
                  protecting: protectedURL, isCancelled: commitCancellation)
    }

    /// The single-export entry point: the job's own cancellation decides
    /// whether bytes already written may land.
    func renderAndWrite(_ request: RenderRequest, source: ExportSource,
                        to destination: URL, protecting protectedURL: URL? = nil,
                        progress: ((RenderProgress) -> Void)? = nil) throws -> RenderResult {
        let output = try render(request, source: source, progress: progress)
        return try write(output, request: request, source: source, to: destination,
                         protecting: protectedURL, isCancelled: { Task.isCancelled })
    }

    private func write(_ output: RenderedExport, request: RenderRequest,
                       source: ExportSource, to destination: URL,
                       protecting protectedURL: URL?,
                       isCancelled: () -> Bool) throws -> RenderResult {
        if Task.isCancelled { throw RenderError.cancelled }
        let plan = RenderPolicy.plan(request, source: source.renderDescription)
        let colorSpace = plan.colorSpace == .sRGB
            ? RenderColorSpace.sRGB.cgColorSpace
            : source.colorSpace
        switch ExportService.writeResult(output, snapshot: request, to: destination,
                                         colorSpace: colorSpace,
                                         metadata: source.metadata,
                                         xmp: source.xmp,
                                         protecting: protectedURL,
                                         isCancelled: isCancelled) {
        case .written:
            return RenderResult(destination: destination,
                                pixelSize: plan.pixelSize,
                                format: plan.format,
                                colorSpace: plan.colorSpace,
                                colorProfileName: colorSpace?.name as String?,
                                // Stripping keeps the allowlisted technical
                                // keys, so the file still carries metadata.
                                carriedSourceMetadata: output.carriesSourceMetadata)
        case .refusedOriginal:
            throw RenderError.sourceIsDestination
        case .cancelled:
            throw RenderError.cancelled
        case .failed:
            throw RenderError.writeFailed
        }
    }

    private static func map(_ error: Error) -> RenderError {
        guard let failure = error as? AIWorkerFailure else { return .renderFailed }
        switch failure.code {
        case -32014: return .cancelled
        case -32602: return .imageTooLarge
        case -32603: return .upscaleFailed
        default: return .renderFailed
        }
    }
}
