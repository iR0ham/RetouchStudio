using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using RetouchStudio.Core.IO;

namespace RetouchStudio.Core.Project;

/// <summary>
/// The photo a snapshot was made against, recorded when the snapshot was
/// written. Size and modification time together tell "the same photo" from
/// "something else now lives at that path" without hashing a large file on
/// every autosave.
/// </summary>
public readonly record struct RecoverySourceIdentity(long Bytes, DateTimeOffset Modified)
{
    public static RecoverySourceIdentity? Of(string? path)
    {
        if (string.IsNullOrEmpty(path))
        {
            return null;
        }
        try
        {
            var file = new FileInfo(path);
            if (!file.Exists)
            {
                return null;
            }
            return new RecoverySourceIdentity(file.Length,
                                              new DateTimeOffset(file.LastWriteTimeUtc, TimeSpan.Zero));
        }
        catch (Exception)
        {
            return null;
        }
    }
}

/// <summary>How the photo a snapshot points at looks now.</summary>
public enum RecoverySourceState
{
    /// <summary>The snapshot records no photo, or the photo is gone.</summary>
    Missing,
    /// <summary>The photo exists and is the one the snapshot was taken against.</summary>
    Available,
    /// <summary>The photo exists but its size or modification time changed.</summary>
    Changed,
}

/// <summary>
/// One recovery copy: exactly what an autosave would have written. The project
/// and the write context are the two byte ranges the C ABI hands back, kept as
/// JSON so the file stays readable and unknown keys survive the round trip.
/// </summary>
public sealed class RecoverySnapshot
{
    /// <summary>Bumped only if the wrapper's meaning changes.</summary>
    public const int CurrentVersion = 1;

    public int Version { get; init; } = CurrentVersion;
    public DateTimeOffset SavedAt { get; init; }
    public byte[] Project { get; init; } = Array.Empty<byte>();
    public byte[] Context { get; init; } = Array.Empty<byte>();
    public RecoverySourceIdentity? Source { get; init; }

    /// <summary>
    /// Records the identity of the photo the project points at. A photo already
    /// missing records no identity, which is also what a legacy copy decodes to.
    /// </summary>
    public static RecoverySnapshot Capture(byte[] project, byte[] context,
                                           string? imagePath, DateTimeOffset savedAt)
        => new()
        {
            SavedAt = savedAt,
            Project = project,
            Context = context,
            Source = RecoverySourceIdentity.Of(imagePath),
        };

    public byte[] ToUtf8()
    {
        var root = new JsonObject
        {
            ["version"] = Version,
            ["savedAt"] = SavedAt.UtcDateTime.ToString("O"),
            ["project"] = JsonNode.Parse(Project)
                ?? throw new JsonException("the snapshot project is empty"),
            ["context"] = JsonNode.Parse(Context),
        };
        if (Source is { } source)
        {
            root["source"] = new JsonObject
            {
                ["bytes"] = source.Bytes,
                ["modified"] = source.Modified.UtcDateTime.ToString("O"),
            };
        }
        return Encoding.UTF8.GetBytes(root.ToJsonString());
    }

    /// <summary>Null when the copy is not a snapshot; the caller quarantines it.</summary>
    public static RecoverySnapshot? FromUtf8(byte[] utf8)
    {
        try
        {
            if (JsonNode.Parse(utf8) is not JsonObject root ||
                root["project"] is not JsonObject project ||
                !DateTimeOffset.TryParse(root["savedAt"]?.GetValue<string>(), out var savedAt))
            {
                return null;
            }
            RecoverySourceIdentity? source = null;
            if (root["source"] is JsonObject recorded &&
                recorded["bytes"]?.GetValue<long>() is { } bytes &&
                DateTimeOffset.TryParse(recorded["modified"]?.GetValue<string>(), out var modified))
            {
                source = new RecoverySourceIdentity(bytes, modified.ToUniversalTime());
            }
            return new RecoverySnapshot
            {
                Version = root["version"]?.GetValue<int>() ?? 0,
                SavedAt = savedAt.ToUniversalTime(),
                Project = Encoding.UTF8.GetBytes(project.ToJsonString()),
                Context = root["context"] is { } context
                    ? Encoding.UTF8.GetBytes(context.ToJsonString())
                    : Encoding.UTF8.GetBytes("""{"version":4}"""),
                Source = source,
            };
        }
        catch (Exception error) when (error is JsonException or InvalidOperationException or FormatException)
        {
            return null;
        }
    }

    /// <summary>The document record, read through the codec's parser.</summary>
    public DocumentModel Document() => DocumentModel.Parse(Project);

    public RecoverySourceState SourceState()
    {
        if (Source is not { } recorded)
        {
            return RecoverySourceState.Missing;
        }
        var current = RecoverySourceIdentity.Of(Document().ImagePath);
        if (current is null)
        {
            return RecoverySourceState.Missing;
        }
        return current.Value == recorded
            ? RecoverySourceState.Available
            : RecoverySourceState.Changed;
    }
}

/// <summary>
/// Crash recovery with independent candidates, the same shape macOS uses.
///
/// <c>working.retouch</c> is the only mutable slot: autosave owns it and it
/// always describes the document on screen. Every candidate is a separate,
/// immutable file named <c>&lt;milliseconds&gt;-&lt;uuid&gt;.retouch</c>, so no
/// decision about one copy can overwrite or delete another. At launch the
/// working slot is lifted into <c>candidates/</c> before any new document can
/// autosave, which is what makes "decide later" safe for every unresolved copy.
///
/// Restoring is ordered <c>write working -&gt; verify working -&gt; delete
/// candidate</c>. A crash before the write leaves the candidate, a crash
/// between the two leaves both complete copies, and a crash after the delete
/// leaves the durable working copy. No step deletes the only recoverable copy.
///
/// Writes are serialized by the host: autosave runs on its dispatcher and the
/// launch path runs before the editor exists.
/// </summary>
public sealed class RecoveryStore
{
    /// <summary>Deterministic failure points used by the data-preservation tests.</summary>
    public enum Failure
    {
        WorkingWrite,
        WorkingRemove,
        CandidateRemove,
        Quarantine,
        Migrate,
    }

    public const string WorkingFileName = "working.retouch";
    private const string CandidatesFolderName = "candidates";
    private const string QuarantineFolderName = "quarantine";
    private const string Extension = ".retouch";
    private static readonly DateTimeOffset Epoch = DateTimeOffset.UnixEpoch;

    private DateTimeOffset _lastSavedAt = Epoch;

    /// <summary>
    /// True while the working slot still holds a copy the launch could not
    /// lift. It is then the only copy of that document, so an autosave must
    /// leave the file alone until the owner restores or discards it.
    /// </summary>
    private bool _workingLocked;

    public RecoveryStore(string directory)
    {
        Directory = directory;
    }

    /// <summary>Where every copy lives. Tests point this at a scratch folder.</summary>
    public string Directory { get; }

    public string WorkingPath => Path.Combine(Directory, WorkingFileName);

    private string CandidatesDirectory => Path.Combine(Directory, CandidatesFolderName);

    private string QuarantineDirectory => Path.Combine(Directory, QuarantineFolderName);

    /// <summary>Set by the data-preservation tests; empty in production.</summary>
    public HashSet<Failure> InjectedFailures { get; } = new();

    public readonly record struct Candidate(string Path, RecoverySnapshot Snapshot);

    /// <summary>
    /// Writes the working slot atomically. The temporary file is replaced, so a
    /// crash never leaves half a project and the previous copy stays whole.
    /// The saved time is monotonic within one store, so candidate order cannot
    /// flip when the clock does.
    /// </summary>
    public bool WriteWorking(RecoverySnapshot snapshot, out RecoverySnapshot? written)
    {
        written = null;
        if (_workingLocked || InjectedFailures.Contains(Failure.WorkingWrite))
        {
            return false;
        }
        var savedAt = snapshot.SavedAt > _lastSavedAt ? snapshot.SavedAt : _lastSavedAt.AddMilliseconds(1);
        var current = new RecoverySnapshot
        {
            SavedAt = savedAt,
            Project = snapshot.Project,
            Context = snapshot.Context,
            Source = snapshot.Source,
        };
        var bytes = current.ToUtf8();
        var temporary = TemporaryFiles.SiblingTempPath(WorkingPath);
        try
        {
            System.IO.Directory.CreateDirectory(Directory);
            File.WriteAllBytes(temporary, bytes);
            TemporaryFiles.Publish(temporary, WorkingPath);
        }
        catch (Exception)
        {
            // The failed bytes only ever lived in the sibling; removing it
            // leaves the previous working copy whole.
            try
            {
                File.Delete(temporary);
            }
            catch (Exception)
            {
            }
            return false;
        }
        _lastSavedAt = savedAt;
        written = current;
        return true;
    }

    public RecoverySnapshot? ReadWorking() => TryReadFile(WorkingPath);

    /// <summary>
    /// Drops the working copy. A caller that only owns one document passes its
    /// photo path, so a slot another document already wrote survives. A slot
    /// that could not be lifted is never removed: it is the only copy of an
    /// unresolved document until the owner restores or discards it.
    /// </summary>
    public bool RemoveWorking(string? ifSourcePath = null)
    {
        // The macOS store refuses this outright (Recovery.swift's
        // removeWorking): an unresolved slot outlives the document that is
        // open, so closing or replacing that document cannot delete it.
        if (_workingLocked || InjectedFailures.Contains(Failure.WorkingRemove))
        {
            return false;
        }
        if (ifSourcePath is not null && ReadWorking() is { } working &&
            !string.Equals(working.Document().ImagePath, ifSourcePath, StringComparison.OrdinalIgnoreCase))
        {
            return false;
        }
        try
        {
            if (File.Exists(WorkingPath))
            {
                File.Delete(WorkingPath);
            }
            return true;
        }
        catch (Exception)
        {
            return false;
        }
    }

    /// <summary>
    /// Prepares the folder for a launch: the working slot becomes a candidate
    /// before any new document can overwrite it, unreadable copies are
    /// quarantined rather than deleted, and what remains is listed oldest
    /// first.
    /// </summary>
    public IReadOnlyList<Candidate> PrepareForLaunch()
    {
        System.IO.Directory.CreateDirectory(Directory);
        // A crash during an autosave can leave its sibling temp behind. Only
        // those old temps are removed: the working slot, candidates and
        // quarantine are never swept.
        TemporaryFiles.SweepStaleSiblings(WorkingPath);
        if (File.Exists(WorkingPath))
        {
            if (TryReadFile(WorkingPath) is { } working)
            {
                if (!InjectedFailures.Contains(Failure.Migrate))
                {
                    var destination = CandidatePath(working.SavedAt);
                    try
                    {
                        File.Move(WorkingPath, destination);
                    }
                    catch (Exception)
                    {
                        // A copy that cannot move stays as the working slot,
                        // which is still a complete copy and is listed below.
                    }
                }
            }
            else
            {
                // An unreadable slot moves aside with its bytes; if it cannot
                // move it stays, and the next launch retries.
                Quarantine(WorkingPath);
            }
        }

        var list = new List<Candidate>();
        // A slot that survived the lift is an unresolved copy and the only
        // one there is: autosave must not overwrite it for this session.
        _workingLocked = File.Exists(WorkingPath);
        if (TryReadFile(WorkingPath) is { } stuck)
        {
            // The lift failed, so the slot is offered as-is. No new document is
            // opened over it until the owner has decided, which is the same
            // guarantee a moved candidate gives.
            list.Add(new Candidate(WorkingPath, stuck));
        }
        if (System.IO.Directory.Exists(CandidatesDirectory))
        {
            foreach (var path in System.IO.Directory.GetFiles(CandidatesDirectory, "*" + Extension))
            {
                if (!IsCandidateFileName(Path.GetFileName(path)))
                {
                    continue;
                }
                if (TryReadFile(path) is not { } snapshot)
                {
                    Quarantine(path);
                    continue;
                }
                list.Add(new Candidate(path, snapshot));
            }
        }
        list.Sort((left, right) => left.Snapshot.SavedAt.CompareTo(right.Snapshot.SavedAt));
        return list;
    }

    /// <summary>
    /// Restores one candidate: write the working slot, verify it, then delete
    /// the candidate. False leaves the candidate in place.
    /// </summary>
    public bool Restore(Candidate candidate)
    {
        if (!File.Exists(candidate.Path))
        {
            return false;
        }
        if (string.Equals(candidate.Path, WorkingPath, StringComparison.OrdinalIgnoreCase))
        {
            // Restoring the stuck slot is the owner's decision about it, so
            // the slot may be written again.
            _workingLocked = false;
        }
        if (!WriteWorking(candidate.Snapshot, out _))
        {
            return false;
        }
        if (ReadWorking() is not { } written ||
            !written.Project.AsSpan().SequenceEqual(candidate.Snapshot.Project) ||
            !written.Context.AsSpan().SequenceEqual(candidate.Snapshot.Context))
        {
            return false;
        }
        if (string.Equals(candidate.Path, WorkingPath, StringComparison.OrdinalIgnoreCase))
        {
            // A slot that could not be lifted was restored onto itself; there
            // is no second copy to drop.
            return true;
        }
        if (InjectedFailures.Contains(Failure.CandidateRemove))
        {
            return false;
        }
        try
        {
            File.Delete(candidate.Path);
        }
        catch (Exception)
        {
            return false;
        }
        return true;
    }

    /// <summary>Drops one copy the owner discarded. Only that file is touched.</summary>
    public bool Discard(Candidate candidate)
    {
        if (InjectedFailures.Contains(Failure.CandidateRemove))
        {
            return false;
        }
        try
        {
            if (File.Exists(candidate.Path))
            {
                File.Delete(candidate.Path);
            }
        }
        catch (Exception)
        {
            return false;
        }
        if (string.Equals(candidate.Path, WorkingPath, StringComparison.OrdinalIgnoreCase))
        {
            // The owner dropped the stuck copy, so the slot is free again.
            _workingLocked = false;
        }
        return true;
    }

    /// <summary>Moves an unreadable copy aside; its bytes are kept, never deleted.</summary>
    public string? Quarantine(string path)
    {
        if (InjectedFailures.Contains(Failure.Quarantine))
        {
            return null;
        }
        var destination = Path.Combine(QuarantineDirectory,
                                       $"{Path.GetFileNameWithoutExtension(path)}-{Guid.NewGuid():N}" + Extension);
        try
        {
            System.IO.Directory.CreateDirectory(QuarantineDirectory);
            File.Move(path, destination);
            return destination;
        }
        catch (Exception)
        {
            return null;
        }
    }

    /// <summary>A candidate file name is <c>&lt;millis&gt;-&lt;uuid&gt;.retouch</c>.</summary>
    public static bool IsCandidateFileName(string name)
    {
        if (!name.EndsWith(Extension, StringComparison.Ordinal))
        {
            return false;
        }
        var stem = name[..^Extension.Length];
        var dash = stem.IndexOf('-');
        if (dash <= 0)
        {
            return false;
        }
        return long.TryParse(stem[..dash], out _) &&
               Guid.TryParseExact(stem[(dash + 1)..], "N", out _);
    }

    private static RecoverySnapshot? TryReadFile(string path)
    {
        try
        {
            return RecoverySnapshot.FromUtf8(File.ReadAllBytes(path));
        }
        catch (Exception)
        {
            return null;
        }
    }

    private string CandidatePath(DateTimeOffset savedAt)
    {
        System.IO.Directory.CreateDirectory(CandidatesDirectory);
        var millis = savedAt.ToUnixTimeMilliseconds();
        return Path.Combine(CandidatesDirectory, $"{millis}-{Guid.NewGuid():N}{Extension}");
    }
}
