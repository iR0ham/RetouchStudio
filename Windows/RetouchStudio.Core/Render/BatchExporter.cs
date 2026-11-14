using RetouchStudio.Core.Imaging;
using RetouchStudio.Core.Project;

namespace RetouchStudio.Core.Render;

/// <summary>
/// The settings for one batch run: the sources, where the results go, and the
/// export choices. Every source is rendered with the edits of one document, so
/// the crop and the sliders apply to the whole selection.
/// </summary>
public sealed record BatchExportRequest(
    IReadOnlyList<string> Sources,
    string DestinationDirectory,
    string Format,
    double Quality,
    int LongEdge,
    bool StripPrivacyMetadata);

/// <summary>
/// What happened to one source. A destination of null means the file failed and
/// <see cref="Error"/> says why; the rest of the batch still runs.
/// </summary>
public sealed record BatchExportItem(string Source, string? Destination, string? Error);

/// <summary>
/// Exports several photos with one document. Each file goes through
/// <see cref="ExportRunner.ExportSourceAsync"/>, which is the same path a single
/// export takes, so a batch cannot produce a different rendering than exporting
/// the files one by one.
/// </summary>
public static class BatchExporter
{
    public static async Task<IReadOnlyList<BatchExportItem>> ExportAsync(
        DocumentModel document, IImageCodec codec, BatchExportRequest request,
        IProgress<BatchExportItem>? progress = null)
    {
        Directory.CreateDirectory(request.DestinationDirectory);
        var taken = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        var results = new List<BatchExportItem>(request.Sources.Count);
        foreach (var source in request.Sources)
        {
            BatchExportItem item;
            try
            {
                var destination = NextDestination(request.DestinationDirectory, source,
                                                  request.Format, taken);
                await ExportRunner.ExportSourceAsync(document, codec, source, destination,
                    request.Format, request.Quality, request.LongEdge,
                    request.StripPrivacyMetadata);
                taken.Add(destination);
                item = new BatchExportItem(source, destination, null);
            }
            catch (Exception error)
            {
                // A missing or unreadable file is the caller's data, not a host
                // fault: the batch reports it and keeps the other files.
                item = new BatchExportItem(source, null, error.Message);
            }
            results.Add(item);
            progress?.Report(item);
        }
        return results;
    }

    /// <summary>
    /// The result name for one source: its own name plus <c>-retouched</c>, in
    /// the format's extension. A name already on disk or claimed earlier in this
    /// run gets a number, so a batch never overwrites a file it did not create.
    /// </summary>
    private static string NextDestination(string directory, string source,
                                          string format, HashSet<string> taken)
    {
        var extension = format switch
        {
            "png" => ".png",
            "tiff" => ".tif",
            _ => ".jpg",
        };
        var stem = Path.GetFileNameWithoutExtension(source) + "-retouched";
        var candidate = Path.Combine(directory, stem + extension);
        for (var number = 2; taken.Contains(candidate) || File.Exists(candidate); number++)
        {
            candidate = Path.Combine(directory, $"{stem}-{number}{extension}");
        }
        return candidate;
    }
}
