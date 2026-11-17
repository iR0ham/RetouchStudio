using System.IO.Pipes;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;

namespace RetouchStudio.AI;

/// <summary>
/// A typed worker failure. The JSON-RPC code is kept for diagnostics; the
/// stable string is what the host switches on (W5-0 §3.4).
/// </summary>
public sealed class AIWorkerException : Exception
{
    public int Code { get; }
    public string TypedCode { get; }
    public JsonObject? Data { get; }

    public AIWorkerException(string typedCode, string message, int code = -32000,
        JsonObject? data = null) : base(message)
    {
        TypedCode = typedCode;
        Code = code;
        Data = data;
    }

    public static AIWorkerException FromRpc(JsonObject error)
    {
        var code = error["code"] is JsonValue value && value.TryGetValue<int>(out var number)
            ? number : Protocol.InternalError;
        var message = error["message"] is JsonValue text &&
                      text.TryGetValue<string>(out var detail)
            ? detail : "the worker failed";
        var data = error["data"] as JsonObject;
        return new AIWorkerException(TypedCodeFor(code), message, code, data);
    }

    public static AIWorkerException WorkerMissing(string detail) =>
        new("E_WORKER_MISSING", detail);

    public static string TypedCodeFor(int code) => code switch
    {
        -32000 => "E_WORKER_MISSING",
        -32010 => "E_LICENCE_REFUSED",
        -32011 => "E_MODEL_MISSING",
        -32012 => "E_MODEL_LEASED",
        -32013 => "E_TIMEOUT",
        -32014 => "E_CANCELLED",
        -32015 => "E_INVALID_INPUT",
        -32016 => "E_MODEL_MISSING",
        -32019 => "E_MODEL_UNVERIFIED",
        -32020 => "E_UNSUPPORTED",
        -32602 => "E_INVALID_INPUT",
        _ => "E_INTERNAL",
    };
}

/// <summary>
/// Protocol-2 JSON-RPC over the worker's named pipe. One connection per call:
/// a stopped worker fails as E_WORKER_MISSING instead of waiting for a job
/// timeout, and a crashed connection cannot leave a half-read frame behind.
/// </summary>
public sealed class WorkerClient
{
    private readonly string _pipeName;

    public WorkerClient(string pipeName)
    {
        _pipeName = pipeName;
    }

    public async Task<JsonObject> CallAsync(string method, JsonObject? parameters = null,
        TimeSpan? timeout = null)
    {
        var limit = timeout ?? TimeSpan.FromSeconds(20);
        using var cancellation = new CancellationTokenSource(limit);
        using var pipe = new NamedPipeClientStream(".", _pipeName,
            PipeDirection.InOut, PipeOptions.Asynchronous);
        try
        {
            await pipe.ConnectAsync(cancellation.Token);
        }
        catch (OperationCanceledException)
        {
            throw AIWorkerException.WorkerMissing(
                "the local AI worker is not running");
        }
        catch (TimeoutException)
        {
            throw AIWorkerException.WorkerMissing(
                "the local AI worker did not accept a connection");
        }
        catch (IOException error)
        {
            throw AIWorkerException.WorkerMissing(
                $"the local AI worker is not reachable: {error.Message}");
        }
        catch (UnauthorizedAccessException error)
        {
            throw AIWorkerException.WorkerMissing(
                $"the local AI worker pipe is not accessible: {error.Message}");
        }

        try
        {
            var request = new JsonObject
            {
                ["jsonrpc"] = "2.0",
                ["id"] = 1,
                ["contractVersion"] = Protocol.ContractVersion,
                ["method"] = method,
                ["params"] = parameters ?? new JsonObject(),
            };
            var bytes = Encoding.UTF8.GetBytes(request.ToJsonString() + "\n");
            await pipe.WriteAsync(bytes, cancellation.Token);
            await pipe.FlushAsync(cancellation.Token);

            using var reader = new StreamReader(pipe, new UTF8Encoding(false),
                detectEncodingFromByteOrderMarks: false, leaveOpen: true);
            var frame = await reader.ReadLineAsync(cancellation.Token)
                ?? throw AIWorkerException.WorkerMissing(
                    "the local AI worker closed the connection");
            if (frame.Length > Protocol.MaxFrameBytes)
                throw new AIWorkerException("E_INTERNAL", "the worker frame is too large");
            var reply = JsonNode.Parse(frame) as JsonObject
                ?? throw new AIWorkerException("E_INTERNAL",
                    "the worker sent an unreadable reply");
            if (reply["error"] is JsonObject error)
                throw AIWorkerException.FromRpc(error);
            var echoed = reply["contractVersion"] is JsonValue version &&
                         version.TryGetValue<string>(out var text) ? text : null;
            if (echoed != Protocol.ContractVersion)
                throw new AIWorkerException("E_INTERNAL",
                    "the worker did not echo the contract version");
            return reply["result"] as JsonObject
                ?? throw new AIWorkerException("E_INTERNAL",
                    "the worker returned no result object");
        }
        catch (OperationCanceledException)
        {
            throw new AIWorkerException("E_TIMEOUT",
                "the worker did not answer in time", -32013);
        }
        catch (IOException error)
        {
            throw AIWorkerException.WorkerMissing(
                $"the worker connection failed: {error.Message}");
        }
        catch (JsonException error)
        {
            throw new AIWorkerException("E_INTERNAL",
                $"the worker sent invalid JSON: {error.Message}");
        }
    }
}
