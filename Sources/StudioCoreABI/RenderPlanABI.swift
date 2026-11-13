import Foundation
import StudioCore

@_cdecl("sc_render_plan")
public func scRenderPlan(_ request: UnsafePointer<UInt8>?, _ requestLength: Int,
                         _ source: UnsafePointer<UInt8>?, _ sourceLength: Int,
                         _ outPlan: UnsafeMutableRawPointer?,
                         _ outError: UnsafeMutableRawPointer?) -> Int32 {
    let outPlan = coreBytes(outPlan)
    let outError = coreBytes(outError)
    clear(outPlan)
    clear(outError)
    guard let requestData = inputData(request, requestLength),
          let sourceData = inputData(source, sourceLength) else {
        return fail(CoreStatus.invalidArgument, "invalid_argument",
                    "request and source are required", error: outError)
    }
    guard outPlan != nil else {
        return fail(CoreStatus.invalidArgument, "invalid_argument",
                    "out_plan is required", error: outError)
    }
    guard isJSON(requestData) else {
        return fail(CoreStatus.invalidJSON, "invalid_json",
                    "the request is not valid JSON", error: outError)
    }
    guard isJSON(sourceData) else {
        return fail(CoreStatus.invalidJSON, "invalid_json",
                    "the source is not valid JSON", error: outError)
    }
    let renderRequest: RenderRequest
    let sourceDescription: RenderSourceDescription
    do {
        renderRequest = try JSONDecoder().decode(RenderRequest.self,
                                                 from: requestData)
    } catch {
        return fail(CoreStatus.invalidDocument, "invalid_request",
                    "the request is not a render request this build understands",
                    detail: String(describing: error), error: outError)
    }
    do {
        sourceDescription = try JSONDecoder().decode(RenderSourceDescription.self,
                                                     from: sourceData)
    } catch {
        return fail(CoreStatus.invalidDocument, "invalid_source",
                    "the source is not a source description this build understands",
                    detail: String(describing: error), error: outError)
    }
    let plan = RenderPolicy.plan(renderRequest, source: sourceDescription)
    do {
        write(outPlan, try canonicalJSON(plan))
        return CoreStatus.ok
    } catch {
        return fail(CoreStatus.invalidDocument, "invalid_plan",
                    "the plan could not be encoded",
                    detail: String(describing: error), error: outError)
    }
}
