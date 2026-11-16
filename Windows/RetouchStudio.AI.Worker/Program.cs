using System.Text.Json;
using RetouchStudio.AI;

var options = Parse(args);
if (options is null) return 64;

WorkerRegistry? registry = null;
try
{
    if (options.Generation is not null || options.Nonce is not null)
    {
        if (!Guid.TryParse(options.Generation, out _) ||
            !Guid.TryParse(options.Nonce, out _))
        {
            throw new ArgumentException(
                "--helper-generation and --launch-nonce must be UUIDs");
        }
    }

    registry = new WorkerRegistry(options.Registry!, options.Generation,
        options.Nonce, options.Pipe!);
    registry.Starting();

    using var cancellation = new CancellationTokenSource();
    Console.CancelKeyPress += (_, eventArgs) =>
    {
        eventArgs.Cancel = true;
        cancellation.Cancel();
    };

    var server = new WorkerServer(options.Pipe!, options.Generation, options.Nonce);
    var running = server.RunAsync(() => registry.Ready(), cancellation.Token);
    await running;
    return 0;
}
catch (Exception error)
{
    registry?.Failed(error.Message);
    Console.Error.WriteLine($"worker startup failed: {error}");
    return 1;
}

static Options? Parse(string[] arguments)
{
    var values = new Dictionary<string, string>(StringComparer.Ordinal);
    for (var index = 0; index < arguments.Length; index++)
    {
        var argument = arguments[index];
        if (!argument.StartsWith("--", StringComparison.Ordinal))
            return Missing($"unexpected argument: {argument}");
        if (index + 1 >= arguments.Length)
            return Missing($"missing value for {argument}");
        values[argument] = arguments[++index];
    }

    var pipe = values.GetValueOrDefault("--pipe");
    var registry = values.GetValueOrDefault("--registry");
    var version = values.GetValueOrDefault("--protocol-version");
    if (pipe is null) return Missing("--pipe is required");
    if (registry is null) return Missing("--registry is required");
    if (version != Protocol.ProtocolVersion.ToString())
    {
        return Missing($"unsupported --protocol-version {version ?? "(missing)"}");
    }

    var generation = values.GetValueOrDefault("--helper-generation");
    var nonce = values.GetValueOrDefault("--launch-nonce");
    if ((generation is null) != (nonce is null))
        return Missing("generation and nonce must be supplied together");
    return new Options(pipe, registry, version, generation, nonce);
}

static Options? Missing(string message)
{
    Console.Error.WriteLine($"worker: {message}");
    return null;
}

sealed record Options(string Pipe, string Registry, string Version,
    string? Generation, string? Nonce);
