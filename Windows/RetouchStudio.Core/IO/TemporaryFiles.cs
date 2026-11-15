namespace RetouchStudio.Core.IO;

/// <summary>
/// The sibling temporary files the save and export paths write next to their
/// destination. A write lands in a dot-prefixed sibling with a fresh GUID and is
/// renamed into place, so a crash can only leave the temp behind, never a
/// half-written destination. The sweep removes those leftovers once they are old
/// enough that no live write can still own them.
/// </summary>
public static class TemporaryFiles
{
    /// <summary>
    /// How old a leftover sibling must be before a sweep may remove it. A day
    /// is far longer than any write this host performs, so a temp a second
    /// instance is still filling in is never swept away.
    /// </summary>
    public static readonly TimeSpan StaleAge = TimeSpan.FromHours(24);

    private const string Suffix = ".tmp";

    /// <summary>
    /// A hidden sibling of <paramref name="destination"/> with a unique name, so
    /// two writers into one folder cannot collide and a stale temp is never
    /// reused.
    /// </summary>
    public static string SiblingTempPath(string destination)
    {
        var fullDestination = Path.GetFullPath(destination);
        var directory = Path.GetDirectoryName(fullDestination)
            ?? throw new InvalidOperationException("the destination has no directory");
        return Path.Combine(
            directory,
            "." + Path.GetFileName(fullDestination) + "." + Guid.NewGuid().ToString("N") + Suffix);
    }

    /// <summary>
    /// True only when <paramref name="candidateFileName"/> is exactly
    /// <c>.&lt;destination&gt;.&lt;32 hex digits&gt;.tmp</c>.
    /// </summary>
    public static bool IsSiblingTemp(string candidateFileName, string destinationFileName)
    {
        if (string.IsNullOrEmpty(destinationFileName))
        {
            return false;
        }
        var prefix = "." + destinationFileName + ".";
        if (!candidateFileName.StartsWith(prefix, StringComparison.Ordinal) ||
            !candidateFileName.EndsWith(Suffix, StringComparison.Ordinal) ||
            candidateFileName.Length < prefix.Length + Suffix.Length)
        {
            return false;
        }
        var middle = candidateFileName.Substring(
            prefix.Length, candidateFileName.Length - prefix.Length - Suffix.Length);
        return Guid.TryParseExact(middle, "N", out _);
    }

    /// <summary>
    /// Deletes the leftover siblings of <paramref name="destination"/> whose
    /// write ended before <paramref name="utcNow"/> minus
    /// <paramref name="minAge"/>. Only regular files in the destination's own
    /// folder that pass <see cref="IsSiblingTemp"/> are considered; nothing
    /// recurses and no other name is touched. Returns how many files were
    /// removed.
    /// </summary>
    public static int SweepStaleSiblings(string destination, DateTime utcNow, TimeSpan minAge)
    {
        var fullDestination = Path.GetFullPath(destination);
        var directory = Path.GetDirectoryName(fullDestination);
        if (directory is null || !Directory.Exists(directory))
        {
            return 0;
        }
        var destinationName = Path.GetFileName(fullDestination);
        var threshold = utcNow - minAge;
        var deleted = 0;
        try
        {
            foreach (var candidate in Directory.EnumerateFiles(directory))
            {
                try
                {
                    if (!IsSiblingTemp(Path.GetFileName(candidate), destinationName) ||
                        File.GetLastWriteTimeUtc(candidate) >= threshold)
                    {
                        continue;
                    }
                    File.Delete(candidate);
                    deleted++;
                }
                catch (IOException)
                {
                    // One temp that cannot be removed must not stop the rest;
                    // the next sweep retries it.
                }
                catch (UnauthorizedAccessException)
                {
                }
            }
        }
        catch (IOException)
        {
        }
        catch (UnauthorizedAccessException)
        {
        }
        return deleted;
    }

    /// <summary>A sweep with the production clock and <see cref="StaleAge"/>.</summary>
    public static int SweepStaleSiblings(string destination)
        => SweepStaleSiblings(destination, DateTime.UtcNow, StaleAge);
}
