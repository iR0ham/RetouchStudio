using System.Diagnostics;
using System.IO.Pipes;
using System.Text;
using System.Text.Json.Nodes;
using RetouchStudio.AI;
using RetouchStudio.AI.Tests;

RetouchStudio.AI.Tests.ModelStoreChecks.RunChildIfRequested(args);

var failures = new List<string>();
void Check(bool condition, string label, string? detail = null)
{
    if (condition)
    {
        Console.WriteLine($"  OK {label}");
        return;
    }
    Console.WriteLine($"  FAIL {label}{(detail is null ? "" : $" — {detail}")}");
    failures.Add(label);
}

var fixture = FindFixture();
Console.WriteLine("[A] the shared contract fixture");
Check(fixture is not null, "the protocol-2 fixture is readable");
var contract = fixture is null ? null : JsonNode.Parse(File.ReadAllText(fixture))!.AsObject();
var requiredMethods = contract?["requiredMethods"]?.AsArray()
    .Select(node => node!.GetValue<string>()).ToArray() ?? Array.Empty<string>();
Check(requiredMethods.Contains("health") && requiredMethods.Contains("provider.list"),
    "the fixture lists the handshake methods");

Console.WriteLine("[B] ONNX Runtime CPU initialises without a model");
var provider = Providers.Ensure();
Check(provider.Available, "the CPU execution provider loaded", provider.Error);
Check(Providers.ExecutionProviders.SequenceEqual(new[] { "CPU" }),
    "only the CPU provider is advertised");

var worker = Environment.GetEnvironmentVariable("RETOUCH_AI_WORKER")
    ?? Path.Combine(AppContext.BaseDirectory, "RetouchStudio.AI.Worker.exe");
Console.WriteLine("[C] a real worker completes the protocol-2 handshake");
Check(File.Exists(worker), "the worker executable is built beside the tests", worker);
if (File.Exists(worker))
{
    var directory = Path.Combine(Path.GetTempPath(), $"rsai-{Guid.NewGuid():N}");
    Directory.CreateDirectory(directory);
    var registryPath = Path.Combine(directory, WorkerRegistry.FileName);
    var pipe = $"retouch-ai-{Guid.NewGuid():N}";
    var generation = Guid.NewGuid().ToString();
    var nonce = Guid.NewGuid().ToString();
    var log = Path.Combine(directory, "worker.log");

    var parent = new ProcessIdentityPlaceholder(Environment.ProcessId);
    File.WriteAllText(registryPath, new JsonObject
    {
        ["schema"] = 2,
        ["protocol_version"] = 2,
        ["generation"] = generation,
        ["launch_nonce"] = nonce,
        ["revision"] = 1,
        ["state"] = "starting",
        ["parent"] = parent.Json,
        ["helper"] = null,
        ["socket"] = pipe,
        ["created_at"] = DateTimeOffset.UtcNow.ToUnixTimeMilliseconds() / 1000.0,
        ["updated_at"] = DateTimeOffset.UtcNow.ToUnixTimeMilliseconds() / 1000.0,
        ["shutdown"] = null,
        ["clients"] = new JsonArray(),
        ["last_error"] = null,
    }.ToJsonString());

    using var child = ContainedWorker.Start(worker, new[]
    {
        "--pipe", pipe,
        "--protocol-version", "2",
        "--helper-generation", generation,
        "--launch-nonce", nonce,
        "--registry", registryPath,
    }, directory, log);

    var ready = WaitForReady(registryPath, generation, nonce, TimeSpan.FromSeconds(30));
    Check(ready is not null, "the helper publishes a ready registry record",
        ready is null ? ReadTail(log) : null);
    if (ready is not null)
    {
        Check(ready["state"]?.GetValue<string>() == "ready", "the record state is ready");
        Check(ready["helper"]?["pid"]?.GetValue<int>() == child.Pid,
            "readiness names the started process");
        Check(ready["parent"]?["pid"]?.GetValue<int>() == Environment.ProcessId,
            "the host's parent identity survives the worker's write");

        using var client = new PipeClient(pipe);
        try
        {
            client.Connect(TimeSpan.FromSeconds(10));
            var health = client.Call("health");
            Check(health?["result"]?["protocol_version"]?.GetValue<int>() == 2,
                "health reports protocol_version 2");
            Check(health?["result"]?["contractVersion"]?.GetValue<string>() == "1",
                "health echoes contractVersion 1");
            Check(health?["result"]?["helper_generation"]?.GetValue<string>() == generation,
                "health echoes the generation");
            Check(health?["result"]?["launch_nonce"]?.GetValue<string>() == nonce,
                "health echoes the launch nonce");
            Check(health?["result"]?["providers"]?[0]?["execution_providers"]?[0]
                    ?.GetValue<string>() == "CPU",
                "health reports an initialised CPU provider");

            foreach (var required in requiredMethods)
            {
                if (required == "shutdown") continue;
                var response = client.Call(required);
                Check(response?["result"] is not null,
                    $"fixture method {required} answers",
                    response?.ToJsonString());
            }

            var healthFields = contract?["health"]?["result"]?.AsObject();
            Check(healthFields is not null && healthFields
                    .All(field => health?["result"]?[field.Key] is not null),
                "health replies with every field the shared fixture requires");

            var listed = client.Call("provider.list");
            var listedResult = listed?["result"];
            Check(listedResult?["contractVersion"]?.GetValue<string>() == "1" &&
                  listedResult?["providers"]?[0]?["id"] is not null,
                "provider.list echoes contractVersion and a provider",
                listed?.ToJsonString());

            var ping = client.Call("ping");
            Check(ping?["result"]?["pong"]?.GetValue<bool>() == true,
                "ping answers pong", ping?.ToJsonString());

            var hello = client.Call("hello");
            Check(hello?["result"]?["pid"]?.GetValue<int>() == child.Pid,
                "hello names the worker pid");

            var rejected = client.Call("ping", contractVersion: "999");
            Check(rejected?["error"]?["code"]?.GetValue<int>() == -32600,
                "a foreign contract version is refused", rejected?.ToJsonString());

            var shutdown = client.Call("shutdown");
            Check(shutdown?["result"]?["stopping"]?.GetValue<bool>() == true,
                "shutdown is acknowledged");
            Check(child.WaitForExit(TimeSpan.FromSeconds(10)),
                "the worker exits after shutdown", ReadTail(log));
        }
        catch (Exception error)
        {
            Check(false, "the pipe handshake completed", error.ToString());
        }
    }
}

Console.WriteLine("[D] the Job Object contains the worker");
if (File.Exists(worker))
{
    var directory = Path.Combine(Path.GetTempPath(), $"rsai-{Guid.NewGuid():N}");
    Directory.CreateDirectory(directory);
    var pipe = $"retouch-ai-{Guid.NewGuid():N}";
    var generation = Guid.NewGuid().ToString();
    var nonce = Guid.NewGuid().ToString();
    var contained = ContainedWorker.Start(worker, new[]
    {
        "--pipe", pipe,
        "--protocol-version", "2",
        "--helper-generation", generation,
        "--launch-nonce", nonce,
        "--registry", Path.Combine(directory, WorkerRegistry.FileName),
    }, directory);
    var started = !contained.HasExited;
    contained.Dispose();
    Check(started, "the contained worker started");
    Check(contained.ContainedExited, "closing the job terminates the worker");
}

Console.WriteLine("[E] an unsupported protocol version is refused");
if (File.Exists(worker))
{
    var directory = Path.Combine(Path.GetTempPath(), $"rsai-{Guid.NewGuid():N}");
    Directory.CreateDirectory(directory);
    using var process = Process.Start(new ProcessStartInfo(worker)
    {
        UseShellExecute = false,
        RedirectStandardError = true,
        WorkingDirectory = directory,
        ArgumentList =
        {
            "--pipe", "unused",
            "--protocol-version", "1",
            "--registry", Path.Combine(directory, WorkerRegistry.FileName),
        },
    })!;
    Check(process.WaitForExit(10000), "the worker exits promptly");
    Check(process.ExitCode == 64, "the worker rejects protocol 1",
        process.StandardError.ReadToEnd());
}

ModelStoreChecks.Run(Check);

Console.WriteLine();
if (failures.Count == 0)
{
    Console.WriteLine("AI RUNTIME TESTS: PASS");
    return 0;
}
Console.WriteLine($"AI RUNTIME TESTS: FAIL ({failures.Count})");
foreach (var failure in failures) Console.WriteLine($"  - {failure}");
return 1;

static string? FindFixture()
{
    var root = Environment.GetEnvironmentVariable("RETOUCH_TESTS_ROOT");
    if (root is not null)
    {
        var candidate = Path.Combine(root, "Tests/Contract/protocol2.json");
        if (File.Exists(candidate)) return candidate;
    }
    var directory = new DirectoryInfo(AppContext.BaseDirectory);
    while (directory is not null)
    {
        var candidate = Path.Combine(directory.FullName, "Tests/Contract/protocol2.json");
        if (File.Exists(candidate)) return candidate;
        directory = directory.Parent;
    }
    return null;
}

static JsonObject? WaitForReady(string path, string generation, string nonce,
    TimeSpan timeout)
{
    var deadline = DateTime.UtcNow + timeout;
    while (DateTime.UtcNow < deadline)
    {
        try
        {
            var record = JsonNode.Parse(File.ReadAllText(path))?.AsObject();
            if (record?["state"]?.GetValue<string>() == "ready" &&
                record["generation"]?.GetValue<string>() == generation &&
                record["launch_nonce"]?.GetValue<string>() == nonce)
            {
                return record;
            }
        }
        catch (IOException) { }
        catch (System.Text.Json.JsonException) { }
        Thread.Sleep(50);
    }
    return null;
}

static string ReadTail(string path)
{
    try
    {
        var text = File.ReadAllText(path);
        return text.Length <= 600 ? text : text[^600..];
    }
    catch (IOException)
    {
        return "(no log)";
    }
}

sealed class PipeClient : IDisposable
{
    private readonly NamedPipeClientStream _pipe;
    private readonly StreamReader _reader;
    private readonly StreamWriter _writer;
    private int _next = 1;

    public PipeClient(string name)
    {
        _pipe = new NamedPipeClientStream(".", name, PipeDirection.InOut,
            PipeOptions.Asynchronous);
        _reader = new StreamReader(_pipe, Encoding.UTF8);
        // AutoFlush would write the UTF-8 preamble during construction, which
        // throws until the pipe connects; enable it on connect instead.
        _writer = new StreamWriter(_pipe, new UTF8Encoding(false));
    }

    public void Connect(TimeSpan timeout)
    {
        _pipe.Connect((int)timeout.TotalMilliseconds);
        _writer.AutoFlush = true;
    }

    public JsonObject? Call(string method, string? contractVersion = null)
    {
        var request = new JsonObject
        {
            ["jsonrpc"] = "2.0",
            ["id"] = _next++,
            ["method"] = method,
            ["params"] = new JsonObject(),
        };
        if (contractVersion is not null) request["contractVersion"] = contractVersion;
        _writer.WriteLine(request.ToJsonString());
        var line = _reader.ReadLine();
        return line is null ? null : JsonNode.Parse(line)?.AsObject();
    }

    public void Dispose()
    {
        // Disposing the writer flushes, which throws if the pipe never connected.
        if (_pipe.IsConnected) _writer.Dispose();
        _reader.Dispose();
        _pipe.Dispose();
    }
}

sealed class ProcessIdentityPlaceholder
{
    public ProcessIdentityPlaceholder(int pid)
    {
        var start = ProcessIdentity.Start(pid);
        Json = new JsonObject
        {
            ["pid"] = pid,
            ["start_seconds"] = start.Seconds,
            ["start_microseconds"] = start.Microseconds,
            ["executable"] = Environment.ProcessPath,
        };
    }

    public JsonObject Json { get; }
}
