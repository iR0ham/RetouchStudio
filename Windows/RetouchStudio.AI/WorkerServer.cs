using System.IO.Pipes;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;

namespace RetouchStudio.AI;

/// <summary>
/// Protocol 2 line server over a named pipe. One connection at a time, one JSON
/// object per line, a hard 1 MiB frame cap. State is only changed after the
/// contract version in the request is accepted.
/// </summary>
public sealed class WorkerServer
{
    private readonly string _pipeName;
    private readonly string? _generation;
    private readonly string? _nonce;

    public WorkerServer(string pipeName, string? generation, string? nonce)
    {
        _pipeName = pipeName;
        _generation = generation;
        _nonce = nonce;
    }

    public async Task RunAsync(Action listening, CancellationToken cancellationToken)
    {
        var announced = false;
        while (!cancellationToken.IsCancellationRequested)
        {
            await using var pipe = new NamedPipeServerStream(_pipeName,
                PipeDirection.InOut, 1, PipeTransmissionMode.Byte,
                PipeOptions.Asynchronous | PipeOptions.CurrentUserOnly);
            if (!announced)
            {
                announced = true;
                listening();
            }
            await pipe.WaitForConnectionAsync(cancellationToken);
            if (await Serve(pipe, cancellationToken)) return;
        }
    }

    private async Task<bool> Serve(Stream pipe, CancellationToken cancellationToken)
    {
        var buffer = new byte[16 * 1024];
        var frame = new MemoryStream();
        while (!cancellationToken.IsCancellationRequested)
        {
            int read;
            try
            {
                read = await pipe.ReadAsync(buffer, cancellationToken);
            }
            catch (IOException)
            {
                return false;
            }
            if (read == 0) return false;

            for (var offset = 0; offset < read; offset++)
            {
                var value = buffer[offset];
                if (value == (byte)'\n')
                {
                    if (frame.Length > 0)
                    {
                        var stop = await Handle(pipe, frame.ToArray(), cancellationToken);
                        frame.SetLength(0);
                        if (stop) return true;
                    }
                    continue;
                }
                frame.WriteByte(value);
                if (frame.Length > Protocol.MaxFrameBytes)
                {
                    await Respond(pipe, Protocol.Failure(null, Protocol.InvalidRequest,
                        "frame exceeds 1 MiB"), cancellationToken);
                    return true;
                }
            }
        }
        return false;
    }

    private async Task<bool> Handle(Stream pipe, byte[] utf8, CancellationToken cancellationToken)
    {
        JsonObject? request = null;
        JsonNode? id = null;
        try
        {
            request = JsonNode.Parse(utf8) as JsonObject;
        }
        catch (JsonException)
        {
            await Respond(pipe, Protocol.Failure(null, Protocol.ParseError,
                "invalid JSON"), cancellationToken);
            return false;
        }
        if (request is null)
        {
            await Respond(pipe, Protocol.Failure(null, Protocol.InvalidRequest,
                "request must be an object"), cancellationToken);
            return false;
        }

        id = request["id"]?.DeepClone();
        var isNotification = !request.ContainsKey("id");
        JsonObject? response = null;
        string? method = null;

        if (String(request["jsonrpc"]) != "2.0" ||
            (method = String(request["method"])) is null)
        {
            response = Protocol.Failure(id, Protocol.InvalidRequest,
                "a JSON-RPC 2.0 method is required");
        }
        else if (request.ContainsKey("contractVersion") &&
                 String(request["contractVersion"]) != Protocol.ContractVersion)
        {
            response = Protocol.Failure(id, Protocol.InvalidRequest,
                "unsupported contract version",
                new JsonObject { ["contractVersion"] = String(request["contractVersion"]) });
        }

        var dispatched = response is null;
        response ??= Dispatch(method!, id);
        if (!isNotification && response is not null)
        {
            await Respond(pipe, response, cancellationToken);
        }
        return dispatched && method == "shutdown";
    }

    private JsonObject? Dispatch(string method, JsonNode? id)
    {
        var provider = ProviderRecord();
        switch (method)
        {
            case "hello":
                return Protocol.Success(id, new JsonObject
                {
                    ["contractVersion"] = Protocol.ContractVersion,
                    ["protocol"] = "2",
                    ["protocol_version"] = Protocol.ProtocolVersion,
                    ["worker"] = Providers.Id,
                    ["pid"] = Environment.ProcessId,
                    ["helper_generation"] = _generation,
                    ["launch_nonce"] = _nonce,
                    ["providers"] = new JsonArray(provider.DeepClone()),
                });
            case "health":
                return Protocol.Success(id, new JsonObject
                {
                    ["contractVersion"] = Protocol.ContractVersion,
                    ["protocol"] = "2",
                    ["protocol_version"] = Protocol.ProtocolVersion,
                    ["pid"] = Environment.ProcessId,
                    ["helper_generation"] = _generation,
                    ["launch_nonce"] = _nonce,
                    ["providers"] = new JsonArray(provider.DeepClone()),
                });
            case "provider.list":
                return Protocol.Success(id, new JsonObject
                {
                    ["contractVersion"] = Protocol.ContractVersion,
                    ["providers"] = new JsonArray(provider.DeepClone()),
                });
            case "ping":
                return Protocol.Success(id, new JsonObject { ["pong"] = true });
            case "shutdown":
                return Protocol.Success(id, new JsonObject { ["stopping"] = true });
            default:
                return Protocol.Failure(id, Protocol.MethodNotFound,
                    $"unknown method: {method}");
        }
    }

    private static JsonObject ProviderRecord()
    {
        var result = Providers.Ensure();
        var record = new JsonObject
        {
            ["id"] = Providers.Id,
            ["state"] = result.Available ? "available" : "unavailable",
            ["execution_providers"] = result.Available
                ? new JsonArray("CPU")
                : new JsonArray(),
        };
        if (!result.Available) record["error"] = result.Error;
        return record;
    }

    private static string? String(JsonNode? node) =>
        node is JsonValue value && value.TryGetValue<string>(out var text) ? text : null;

    private static async Task Respond(Stream pipe, JsonObject response,
        CancellationToken cancellationToken)
    {
        var bytes = Encoding.UTF8.GetBytes(response.ToJsonString() + "\n");
        await pipe.WriteAsync(bytes, cancellationToken);
        await pipe.FlushAsync(cancellationToken);
    }
}
