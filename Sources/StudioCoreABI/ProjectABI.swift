import Foundation
import StudioCore

private func projectFailure(_ error: Error,
                            _ outError: UnsafeMutablePointer<ScCoreBytes>?) -> Int32 {
    if case ProjectCodecError.tooNew(let version) = error {
        return fail(CoreStatus.projectTooNew, "project_too_new",
                    "the project was written by a newer version",
                    detail: "version \(version)", error: outError)
    }
    if case ProjectCodecError.unsupportedFeatures(let features) = error {
        return fail(CoreStatus.unsupportedFeature, "unsupported_feature",
                    "the project requires capabilities this build does not implement",
                    detail: features.joined(separator: ","), error: outError)
    }
    return fail(CoreStatus.invalidDocument, "invalid_document",
                "the project is not a document this build understands",
                detail: String(describing: error), error: outError)
}

@_cdecl("sc_project_read")
public func scProjectRead(_ bytes: UnsafePointer<UInt8>?, _ length: Int,
                          _ outDocument: UnsafeMutableRawPointer?,
                          _ outContext: UnsafeMutableRawPointer?,
                          _ outError: UnsafeMutableRawPointer?) -> Int32 {
    let outDocument = coreBytes(outDocument)
    let outContext = coreBytes(outContext)
    let outError = coreBytes(outError)
    clear(outDocument)
    clear(outContext)
    clear(outError)
    guard let data = inputData(bytes, length) else {
        return fail(CoreStatus.invalidArgument, "invalid_argument",
                    "bytes and length must describe the project file",
                    error: outError)
    }
    guard outDocument != nil, outContext != nil else {
        return fail(CoreStatus.invalidArgument, "invalid_argument",
                    "out_document and out_context are required",
                    error: outError)
    }
    guard isJSON(data) else {
        return fail(CoreStatus.invalidJSON, "invalid_json",
                    "the project bytes are not valid JSON", error: outError)
    }
    do {
        let file = try ProjectCodec.read(data)
        // v4 is a file format, not a second model: the host always edits the
        // current record, and the context decides how the save is written.
        write(outDocument, try ProjectCodec.encodeV4(file.project))
        write(outContext, try canonicalJSON(file.context))
        return CoreStatus.ok
    } catch {
        return projectFailure(error, outError)
    }
}

@_cdecl("sc_project_write")
public func scProjectWrite(_ document: UnsafePointer<UInt8>?, _ documentLength: Int,
                           _ context: UnsafePointer<UInt8>?, _ contextLength: Int,
                           _ outProject: UnsafeMutableRawPointer?,
                           _ outError: UnsafeMutableRawPointer?) -> Int32 {
    let outProject = coreBytes(outProject)
    let outError = coreBytes(outError)
    clear(outProject)
    clear(outError)
    guard let documentData = inputData(document, documentLength),
          let contextData = inputData(context, contextLength) else {
        return fail(CoreStatus.invalidArgument, "invalid_argument",
                    "document and context are required", error: outError)
    }
    guard outProject != nil else {
        return fail(CoreStatus.invalidArgument, "invalid_argument",
                    "out_project is required", error: outError)
    }
    guard isJSON(documentData) else {
        return fail(CoreStatus.invalidJSON, "invalid_json",
                    "the document is not valid JSON", error: outError)
    }
    guard isJSON(contextData) else {
        return fail(CoreStatus.invalidJSON, "invalid_json",
                    "the context is not valid JSON", error: outError)
    }
    let writeContext: ProjectWriteContext
    do {
        writeContext = try JSONDecoder().decode(ProjectWriteContext.self,
                                                from: contextData)
    } catch {
        return fail(CoreStatus.invalidDocument, "invalid_context",
                    "the write context is not a context this build understands",
                    detail: String(describing: error), error: outError)
    }
    do {
        let file = try ProjectCodec.read(documentData)
        write(outProject, try ProjectCodec.encode(file.project, context: writeContext))
        return CoreStatus.ok
    } catch {
        return projectFailure(error, outError)
    }
}
