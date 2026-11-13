using System.Text;
using RetouchStudio.Core.Interop;

namespace RetouchStudio.Core.Project;

/// <summary>
/// One open document: the v4 record, its write context and the StudioCore undo
/// history. The history lives in the shared core, so a project edited here has
/// the same undo rules as one edited on macOS.
/// </summary>
public sealed class ProjectSession : IDisposable
{
    /// <summary>
    /// The smallest v4 record the codec accepts. <see cref="Create"/> reads it
    /// through the C ABI so the document that reaches the editor is the codec's
    /// canonical output, not this literal.
    /// </summary>
    private const string SeedTemplate = """
        {"version":4,"imagePath":"","adjustments":{},"exportFormat":"jpeg","exportQuality":0.92,"autoRetouchStrength":50}
        """;

    /// <summary>A new v4 file has no unknown keys, so an empty context is exact.</summary>
    private static readonly byte[] NewContext = Encoding.UTF8.GetBytes("""{"version":4}""");

    private readonly StudioHistory _history;
    private readonly byte[] _context;

    private ProjectSession(DocumentModel document, byte[] context)
    {
        Document = document;
        _context = context;
        _history = StudioHistory.Create(CurrentState());
        _history.MarkClean(CurrentState());
    }

    public DocumentModel Document { get; }

    public string? ProjectPath { get; private set; }

    public string ImagePath => Document.ImagePath;

    public static ProjectSession Open(string projectPath)
    {
        var (document, context) = StudioCoreApi.ReadProject(File.ReadAllBytes(projectPath));
        return new ProjectSession(DocumentModel.Parse(document), context)
        {
            ProjectPath = projectPath,
        };
    }

    public static ProjectSession Create(string imagePath)
    {
        var seed = Encoding.UTF8.GetBytes(SeedTemplate);
        var (document, _) = StudioCoreApi.ReadProject(seed);
        var model = DocumentModel.Parse(document);
        if (model.ImagePath.Length == 0)
        {
            // The seed path is empty by construction; the read above is only
            // there to canonicalize the record.
            model.ImagePath = imagePath;
        }
        return new ProjectSession(model, NewContext);
    }

    public byte[] CurrentState() => Document.ToUtf8();

    public (bool CanUndo, bool CanRedo) HistoryFlags() => _history.Flags(CurrentState());

    public bool IsDirty() => _history.IsDirty(CurrentState());

    /// <summary>Records the current document as one undo step.</summary>
    public void Commit() => _history.Commit(CurrentState());

    /// <summary>Steps back. False when there is nothing to undo.</summary>
    public bool Undo()
    {
        var state = _history.Undo(CurrentState());
        if (state is null)
        {
            return false;
        }
        Document.Adopt(state);
        return true;
    }

    /// <summary>Steps forward. False when there is nothing to redo.</summary>
    public bool Redo()
    {
        var state = _history.Redo(CurrentState());
        if (state is null)
        {
            return false;
        }
        Document.Adopt(state);
        return true;
    }

    /// <summary>Moves the clean baseline to the current document.</summary>
    public void MarkClean() => _history.MarkClean(CurrentState());

    /// <summary>
    /// Writes the project through the codec and moves the clean baseline. The
    /// file is replaced atomically so a crash cannot leave half a project.
    /// </summary>
    public void Save(string projectPath)
    {
        var bytes = StudioCoreApi.WriteProject(CurrentState(), _context);
        var temporary = projectPath + ".tmp";
        File.WriteAllBytes(temporary, bytes);
        File.Move(temporary, projectPath, overwrite: true);
        ProjectPath = projectPath;
        MarkClean();
    }

    public void Dispose() => _history.Dispose();
}
