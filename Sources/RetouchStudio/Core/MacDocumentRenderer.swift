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

    func write(_ output: RenderedExport, request: RenderRequest,
               source: ExportSource, to destination: URL,
               protecting protectedURL: URL?) throws -> RenderResult {
        if Task.isCancelled { throw RenderError.cancelled }
        let plan = RenderPolicy.plan(request, source: source.renderDescription)
        let colorSpace = plan.colorSpace == .sRGB
            ? RenderColorSpace.sRGB.cgColorSpace
            : source.colorSpace
        switch ExportService.writeResult(output, snapshot: request, to: destination,
                                         colorSpace: colorSpace,
                                         metadata: source.metadata,
                                         protecting: protectedURL) {
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
