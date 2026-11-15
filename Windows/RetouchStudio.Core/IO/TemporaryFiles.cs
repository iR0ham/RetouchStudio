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
    /// The tail the codec's metadata splice adds to a temp while it rewrites
    /// the container (<c>MetadataCarry</c> writes <c>&lt;temp&gt;.metadata-&lt;guid&gt;</c>).
    /// </summary>
    private const string MetadataMarker = ".metadata-";

    /// <summary>The length of a <c>"N"</c>-format GUID: 32 hex digits, either case.</summary>
    private const int GuidTextLength = 32;

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
    /// <c>.&lt;destination&gt;.&lt;32 hex digits&gt;.tmp</c>, optionally with one
    /// <c>.metadata-&lt;32 hex digits&gt;</c> tail — the second sibling the
    /// codec's metadata splice writes next to a temp, which a crash there can
    /// also leave behind.
    /// </summary>
    public static bool IsSiblingTemp(string candidateFileName, string destinationFileName)
    {
        if (string.IsNullOrEmpty(destinationFileName))
        {
            return false;
        }
        var prefix = "." + destinationFileName + ".";
        if (!candidateFileName.StartsWith(prefix, StringComparison.Ordinal) ||
            candidateFileName.Length < prefix.Length + GuidTextLength + Suffix.Length)
        {
            return false;
        }
        var tail = candidateFileName.Substring(prefix.Length);
        if (!Guid.TryParseExact(tail.Substring(0, GuidTextLength), "N", out _))
        {
            return false;
        }
        var afterGuid = tail.Substring(GuidTextLength);
        if (string.Equals(afterGuid, Suffix, StringComparison.Ordinal))
        {
            return true;
        }
        if (afterGuid.Length != Suffix.Length + MetadataMarker.Length + GuidTextLength ||
            !afterGuid.StartsWith(Suffix + MetadataMarker, StringComparison.Ordinal))
        {
            return false;
        }
        return Guid.TryParseExact(
            afterGuid.Substring(Suffix.Length + MetadataMarker.Length), "N", out _);
    }

    /// <summary>
    /// Marks a written temp hidden. Windows ignores the leading dot, so the
    /// attribute is what actually keeps a leftover out of the folder's normal
    /// view.
    /// </summary>
    public static void Hide(string path)
        => File.SetAttributes(path, File.GetAttributes(path) | FileAttributes.Hidden);

    /// <summary>
    /// Clears the hidden flag before a temp is published. Renames carry the
    /// source's attributes, so the final file must go in unhidden.
    /// </summary>
    public static void Unhide(string path)
        => File.SetAttributes(path, File.GetAttributes(path) & ~FileAttributes.Hidden);

    /// <summary>
    /// Deletes the leftover siblings of <paramref name="destination"/> whose
    /// write ended before <paramref name="utcNow"/> minus
    /// <paramref name="minAge"/>. Only regular files in the destination's own
    /// folder that pass <see cref="IsSiblingTemp"/> are considered: nothing
    /// recurses, no wildcard is used, and the recovery working slot, its
    /// candidates and quarantine are never eligible. A temp can hold at most
    /// the bytes of one interrupted write, so removing one loses at most one
    /// autosave interval. Returns how many files were removed.
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
