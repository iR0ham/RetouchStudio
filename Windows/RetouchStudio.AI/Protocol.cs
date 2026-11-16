using System.Text.Json.Nodes;

namespace RetouchStudio.AI;

/// <summary>Protocol 2 constants shared by the Windows worker and its tests.</summary>
public static class Protocol
{
    public const int ProtocolVersion = 2;
    public const string ContractVersion = "1";
    public const int MaxFrameBytes = 1024 * 1024;

    public const int ParseError = -32700;
    public const int InvalidRequest = -32600;
    public const int MethodNotFound = -32601;
    public const int InvalidParams = -32602;
    public const int InternalError = -32603;

    public static JsonObject Success(JsonNode? id, JsonObject result) => new()
    {
        ["jsonrpc"] = "2.0",
        ["id"] = id?.DeepClone(),
        ["contractVersion"] = ContractVersion,
        ["result"] = result,
    };

    public static JsonObject Failure(JsonNode? id, int code, string message,
        JsonObject? data = null)
    {
        var error = new JsonObject { ["code"] = code, ["message"] = message };
        if (data is not null) error["data"] = data;
        return new JsonObject
        {
            ["jsonrpc"] = "2.0",
            ["id"] = id?.DeepClone(),
            ["contractVersion"] = ContractVersion,
            ["error"] = error,
        };
    }
}
