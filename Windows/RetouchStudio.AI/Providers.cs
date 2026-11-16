using Microsoft.ML.OnnxRuntime;

namespace RetouchStudio.AI;

/// <summary>
/// Loads ONNX Runtime and reports CPU only after its native library and CPU
/// execution provider initialise. No model is downloaded or required.
/// </summary>
public static class Providers
{
    private static readonly Lazy<Result> Loaded = new(Initialise,
        LazyThreadSafetyMode.ExecutionAndPublication);

    public sealed record Result(bool Available, string? Error);

    public static Result Ensure() => Loaded.Value;

    public static string Id => "windows-onnxruntime";

    public static IReadOnlyList<string> ExecutionProviders =>
        Loaded.Value.Available ? new[] { "CPU" } : Array.Empty<string>();

    private static Result Initialise()
    {
        try
        {
            // OrtEnv is a process-wide singleton; disposing it would make every
            // later session in this worker fail.
            var environment = OrtEnv.Instance();
            using var options = new SessionOptions();
            options.AppendExecutionProvider_CPU(0);
            if (!environment.GetAvailableProviders().Contains("CPU",
                    StringComparer.Ordinal))
            {
                return new Result(false, "the native runtime does not expose CPU");
            }
            return new Result(true, null);
        }
        catch (Exception error)
        {
            return new Result(false, error.Message);
        }
    }
}
