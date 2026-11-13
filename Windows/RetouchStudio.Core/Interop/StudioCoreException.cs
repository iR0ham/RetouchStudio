using System.Text.Json;

namespace RetouchStudio.Core.Interop;

/// <summary>
/// The status codes from <c>studioscore_core.h</c>. The numbers are the C ABI,
/// not an implementation detail.
/// </summary>
public enum StudioCoreStatus
{
    Ok = 0,
    InvalidArgument = 1,
    InvalidJson = 2,
    ProjectTooNew = 3,
    UnsupportedFeature = 4,
    InvalidDocument = 5,
    Internal = 6,
}

/// <summary>
/// A refused call. <see cref="Code"/> is the stable field from the error JSON;
/// <see cref="Message"/> is English diagnostics and must not be shown to the
/// owner untranslated.
/// </summary>
public sealed class StudioCoreException : Exception
{
    public StudioCoreException(StudioCoreStatus status, string code, string message,
                              string? detail = null)
        : base(detail is null ? message : $"{message} ({detail})")
    {
        Status = status;
        Code = code;
        Detail = detail;
    }

    public StudioCoreStatus Status { get; }
    public string Code { get; }
    public string? Detail { get; }
}

internal static class ErrorPayload
{
    public static StudioCoreException Parse(StudioCoreStatus status, byte[] payload)
    {
        if (payload.Length == 0)
        {
            return new StudioCoreException(status, "internal", "the call failed without a payload");
        }
        try
        {
            using var document = JsonDocument.Parse(payload);
            var root = document.RootElement;
            var code = root.TryGetProperty("code", out var c) ? c.GetString() ?? "internal" : "internal";
            var message = root.TryGetProperty("message", out var m) ? m.GetString() ?? "the call failed" : "the call failed";
            var detail = root.TryGetProperty("detail", out var d) ? d.GetString() : null;
            return new StudioCoreException(status, code, message, detail);
        }
        catch (JsonException)
        {
            return new StudioCoreException(status, "internal", "the error payload was not JSON");
        }
    }
}
