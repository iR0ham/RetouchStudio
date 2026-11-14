using System.Collections.ObjectModel;
using System.ComponentModel;
using System.Globalization;
using System.IO;
using System.Text.Json.Nodes;
using System.Runtime.CompilerServices;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using System.Windows.Threading;
using RetouchStudio.Core.Imaging;
using RetouchStudio.Core.Project;
using RetouchStudio.Core.Render;
using RetouchStudio.Imaging;

namespace RetouchStudio.App;

/// <summary>One slider: the document key, the label and the -100…100 value.</summary>
public sealed class AdjustmentItem : INotifyPropertyChanged
{
    private static readonly Dictionary<string, string> Labels = new()
    {
        ["exposure"] = "Exposure",
        ["contrast"] = "Contrast",
        ["blacks"] = "Blacks",
        ["whites"] = "Whites",
        ["saturation"] = "Saturation",
        ["vibrance"] = "Vibrance",
        ["warmth"] = "Warmth",
        ["clarity"] = "Clarity",
        ["vignette"] = "Vignette",
    };

    private double _value;

    public AdjustmentItem(string key, Action<AdjustmentItem> changed)
    {
        Key = key;
        Label = Labels.TryGetValue(key, out var label) ? label : key;
        Changed = changed;
    }

    public event PropertyChangedEventHandler? PropertyChanged;

    public string Key { get; }
    public string Label { get; }
    private Action<AdjustmentItem> Changed { get; }

    public double Value
    {
        get => _value;
        set
        {
            var rounded = Math.Round(value, 1);
            if (Math.Abs(_value - rounded) < 1e-9)
            {
                return;
            }
            _value = rounded;
            Raise(nameof(Value));
            Raise(nameof(ValueText));
            Changed(this);
        }
    }

    public string ValueText =>
        (_value > 0 ? "+" : "") + _value.ToString("0.#", CultureInfo.InvariantCulture);

    /// <summary>Sets the value without reporting a change, for undo and load.</summary>
    public void SetSilently(double value)
    {
        _value = Math.Round(value, 1);
        Raise(nameof(Value));
        Raise(nameof(ValueText));
    }

    private void Raise(string name) =>
        PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(name));
}

/// <summary>
/// The window's state: the open session, the preview pixels and the debounced
/// edit→render→commit loop. Pixels live in the shared core; this class only
/// moves them between the document, the preview and the filesystem.
/// </summary>
public sealed class EditorViewModel : INotifyPropertyChanged
{
    private const int PreviewLongEdge = 1600;

    private readonly WindowsImageCodec _codec = new();
    private readonly DispatcherTimer _renderTimer;
    private readonly DispatcherTimer _commitTimer;
    private ProjectSession? _session;
    private PixelBuffer? _previewSource;
    private PixelBuffer16? _previewSource16;
    private int _sourceWidth;
    private int _sourceHeight;
    private int _renderToken;
    private bool _commitPending;
    private bool _loading;
    private BitmapSource? _preview;
    private BitmapSource? _originalPreview;
    private bool _isPeekingOriginal;
    private string _status = "Open a photo to begin.";
    private string _dimensionText = "";
    private bool _canUndo;
    private bool _canRedo;
    private bool _isDirty;
    private double _straightenAngle;
    private string _exportFormat = "jpeg";
    private double _exportQuality = 0.92;
    private int _exportLongEdge;
    private bool _keepSourceMetadata;
    private string _cropLabel = "Original";
    private bool _isCropping;

    public EditorViewModel()
    {
        Adjustments = new ObservableCollection<AdjustmentItem>(
            DocumentModel.GlobalAdjustmentNames.Select(
                key => new AdjustmentItem(key, OnAdjustmentChanged)));

        _renderTimer = new DispatcherTimer { Interval = TimeSpan.FromMilliseconds(35) };
        _renderTimer.Tick += async (_, _) =>
        {
            _renderTimer.Stop();
            await RenderPreviewAsync();
        };

        _commitTimer = new DispatcherTimer { Interval = TimeSpan.FromMilliseconds(700) };
        _commitTimer.Tick += (_, _) =>
        {
            _commitTimer.Stop();
            FlushCommit();
        };
    }

    public event PropertyChangedEventHandler? PropertyChanged;

    public ObservableCollection<AdjustmentItem> Adjustments { get; }

    /// <summary>
    /// The bitmap on the canvas: the edited preview, or the untouched photo
    /// while the owner holds the compare key.
    /// </summary>
    public BitmapSource? Preview =>
        _isPeekingOriginal && _originalPreview is not null ? _originalPreview : _preview;

    /// <summary>
    /// Hold-to-compare, as the macOS canvas does with the space bar. The
    /// original is the photo as decoded — no crop, no turn, no adjustments.
    /// </summary>
    public bool IsPeekingOriginal
    {
        get => _isPeekingOriginal;
        set
        {
            if (_isPeekingOriginal == value)
            {
                return;
            }
            if (value && _originalPreview is null)
            {
                return;
            }
            _isPeekingOriginal = value;
            Raise(nameof(Preview));
            Raise(nameof(IsPeekingOriginal));
        }
    }

    /// <summary>Whether a compare peek is available right now.</summary>
    public bool CanPeekOriginal =>
        _session is not null && _originalPreview is not null && !_isCropping;

    public string Status
    {
        get => _status;
        private set => Set(ref _status, value);
    }

    public string DimensionText
    {
        get => _dimensionText;
        private set => Set(ref _dimensionText, value);
    }

    public bool CanUndo
    {
        get => _canUndo;
        private set => Set(ref _canUndo, value);
    }

    public bool CanRedo
    {
        get => _canRedo;
        private set => Set(ref _canRedo, value);
    }

    public bool IsDirty
    {
        get => _isDirty;
        private set => Set(ref _isDirty, value);
    }

    public bool HasDocument => _session is not null;

    /// <summary>Edits from a macOS project that this host would drop on export.</summary>
    public IReadOnlyList<string> UnsupportedEdits =>
        _session?.Document.UnsupportedEdits ?? Array.Empty<string>();

    public string? ProjectPath => _session?.ProjectPath;

    /// <summary>File name without extension, for save and export defaults.</summary>
    public string ImageName =>
        _session is null ? "photo" : Path.GetFileNameWithoutExtension(_session.ImagePath);

    public string Title
    {
        get
        {
            var name = _session is null ? "" : Path.GetFileName(_session.ImagePath);
            var marker = IsDirty ? " •" : "";
            return (name.Length == 0 ? "Retouch Studio" : $"{name}{marker} — Retouch Studio");
        }
    }

    public double StraightenAngle
    {
        get => _straightenAngle;
        set
        {
            var rounded = Math.Round(value, 1);
            if (Math.Abs(_straightenAngle - rounded) < 1e-9 || _session is null)
            {
                return;
            }
            _straightenAngle = rounded;
            Raise(nameof(StraightenAngle));
            _session.Document.Orientation =
                _session.Document.Orientation.WithAngle(rounded);
            ScheduleCommit();
            ScheduleRender();
        }
    }

    public string ExportFormat
    {
        get => _exportFormat;
        set
        {
            var format = string.IsNullOrWhiteSpace(value) ? "jpeg" : value;
            if (_exportFormat == format)
            {
                return;
            }
            _exportFormat = format;
            Raise(nameof(ExportFormat));
            if (_session is not null)
            {
                _session.Document.ExportFormat = format;
                ScheduleCommit();
            }
        }
    }

    public double ExportQuality
    {
        get => _exportQuality;
        set
        {
            var quality = Math.Round(value, 2);
            if (Math.Abs(_exportQuality - quality) < 1e-9)
            {
                return;
            }
            _exportQuality = quality;
            Raise(nameof(ExportQuality));
            if (_session is not null)
            {
                _session.Document.ExportQuality = quality;
                ScheduleCommit();
            }
        }
    }

    public int ExportLongEdge
    {
        get => _exportLongEdge;
        set
        {
            if (_exportLongEdge == value)
            {
                return;
            }
            _exportLongEdge = value;
            Raise(nameof(ExportLongEdge));
            Raise(nameof(LongEdgeIndex));
            if (_session is not null)
            {
                _session.Document.ExportLongEdge = value > 0 ? value : null;
                ScheduleCommit();
            }
        }
    }

    /// <summary>
    /// The export long edge as the panel's four choices: 0 original, 1 4096,
    /// 2 2048, 3 1080. Binding the index, not just the value, is what makes an
    /// opened project show the setting it carries. Both apps write only these
    /// choices, so an off-list value from a hand-edited file shows Original
    /// while the export keeps the file's own value.
    /// </summary>
    public int LongEdgeIndex
    {
        get => _exportLongEdge switch
        {
            4096 => 1,
            2048 => 2,
            1080 => 3,
            _ => 0,
        };
        set => ExportLongEdge = value switch
        {
            1 => 4096,
            2 => 2048,
            3 => 1080,
            _ => 0,
        };
    }

    /// <summary>
    /// Off by default: an export carries only the resolution unless the owner
    /// asks for the camera, capture and GPS keys. It is a per-export choice,
    /// not a project field, so the shared document does not grow a key that
    /// macOS would have to preserve.
    /// </summary>
    public bool KeepSourceMetadata
    {
        get => _keepSourceMetadata;
        set
        {
            if (_keepSourceMetadata == value)
            {
                return;
            }
            _keepSourceMetadata = value;
            Raise(nameof(KeepSourceMetadata));
        }
    }

    public string CropLabel
    {
        get => _cropLabel;
        private set => Set(ref _cropLabel, value);
    }

    /// <summary>
    /// While the crop overlay is open the preview shows the whole photo, so the
    /// frame the owner drags and the picture under it share coordinates.
    /// </summary>
    public bool IsCropping
    {
        get => _isCropping;
        set
        {
            if (_isCropping == value)
            {
                return;
            }
            _isCropping = value;
            if (value)
            {
                _isPeekingOriginal = false;
            }
            Raise(nameof(IsCropping));
            Raise(nameof(Preview));
            Raise(nameof(CanPeekOriginal));
            ScheduleRender();
        }
    }

    public CropValue? CurrentCrop => _session?.Document.Crop;

    /// <summary>Pixel size of a draft crop, for the overlay's live readout.</summary>
    public string CropPixelText(CropValue crop)
    {
        var size = CropGeometry.PixelSize(crop, _sourceWidth, _sourceHeight,
                             _session?.Document.Orientation.QuarterTurns ?? 0);
        return $"{size.Width:N0} × {size.Height:N0}";
    }

    /// <summary>Writes a crop the owner drew; the preview returns to it.</summary>
    public void ApplyCustomCrop(CropValue crop)
    {
        if (_session is null)
        {
            return;
        }
        _session.Document.Crop = CropGeometry.Clamp(crop);
        CropLabel = "Custom";
        ScheduleCommit();
        ScheduleRender();
    }

    public async Task OpenImageAsync(string imagePath)
    {
        CloseSession();
        var session = ProjectSession.Create(imagePath);
        await AdoptAsync(session);
        Status = $"{Path.GetFileName(imagePath)} opened.";
    }

    public async Task OpenProjectAsync(string projectPath)
    {
        var session = ProjectSession.Open(projectPath);
        var imagePath = session.ImagePath;
        if (string.IsNullOrEmpty(imagePath) || !File.Exists(imagePath))
        {
            session.Dispose();
            throw new FileNotFoundException(
                "the project's photo is not at the recorded path", imagePath);
        }
        CloseSession();
        await AdoptAsync(session);
        var unrendered = session.Document.UnsupportedEdits;
        Status = unrendered.Count == 0
            ? $"{Path.GetFileName(projectPath)} opened."
            : $"{Path.GetFileName(projectPath)} opened; this host cannot render " +
              $"{string.Join(", ", unrendered)}.";
    }

    public void Save(string projectPath)
    {
        FlushCommit();
        _session?.Save(projectPath);
        RefreshState();
        Status = $"Saved {Path.GetFileName(projectPath)}.";
    }

    public async Task<string> ExportAsync(string destination)
    {
        if (_session is null)
        {
            throw new InvalidOperationException("there is no open document");
        }
        FlushCommit();
        var plan = await ExportRunner.ExportAsync(_session, _codec, destination,
                                                 _exportFormat, _exportQuality,
                                                 _exportLongEdge,
                                                 stripPrivacyMetadata: !_keepSourceMetadata);
        Status = $"Exported {Path.GetFileName(destination)} " +
                 $"({plan.Format}, {plan.BitsPerChannel}-bit).";
        return destination;
    }

    /// <summary>
    /// Exports a selection with the open document's edits. Every file takes the
    /// single-export path and the results are reported one by one, so a file
    /// that fails does not stop the rest.
    /// </summary>
    public async Task<IReadOnlyList<BatchExportItem>> BatchExportAsync(
        IReadOnlyList<string> sources, string destinationDirectory)
    {
        if (_session is null)
        {
            throw new InvalidOperationException("there is no open document");
        }
        if (sources.Count == 0)
        {
            throw new InvalidOperationException("no photos were selected");
        }
        FlushCommit();
        var results = await BatchExporter.ExportAsync(
            _session.Document, _codec,
            new BatchExportRequest(sources, destinationDirectory, _exportFormat,
                                   _exportQuality, _exportLongEdge,
                                   !_keepSourceMetadata));
        var exported = results.Count(item => item.Error is null);
        var folder = Path.GetFileName(destinationDirectory.TrimEnd(
            Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar));
        Status = $"Exported {exported} of {results.Count} photos to {folder}.";
        return results;
    }

    public void Undo()
    {
        if (_session is null)
        {
            return;
        }
        FlushCommit();
        if (_session.Undo())
        {
            LoadFromDocument();
            ScheduleRender();
        }
        RefreshState();
    }

    public void Redo()
    {
        if (_session is null)
        {
            return;
        }
        if (_session.Redo())
        {
            LoadFromDocument();
            ScheduleRender();
        }
        RefreshState();
    }

    public void Rotate(int quarterTurns)
    {
        if (_session is null)
        {
            return;
        }
        var document = _session.Document;
        document.Orientation = document.Orientation.WithQuarterTurn(quarterTurns);
        if (document.Crop is { } crop)
        {
            var turned = CropGeometry.Rotate(crop, quarterTurns);
            document.Crop = CropGeometry.IsFull(turned) ? null : turned;
            CropLabel = document.Crop is null ? "Original" : "Custom";
        }
        ScheduleCommit();
        ScheduleRender();
    }

    public void Flip()
    {
        if (_session is null)
        {
            return;
        }
        var document = _session.Document;
        document.Orientation = document.Orientation.WithFlip();
        if (document.Crop is { } crop)
        {
            document.Crop = CropGeometry.Mirror(crop);
            CropLabel = "Custom";
        }
        ScheduleCommit();
        ScheduleRender();
    }

    /// <summary>
    /// A centred crop at a fixed aspect; the freeform overlay is separate. The
    /// preset covers the common portrait and print ratios and writes the same
    /// normalized frame crop the macOS app reads. The preset names the finished
    /// frame's aspect, so where the frame is turned its aspect is the turned one.
    /// </summary>
    public void ApplyCrop(string preset)
    {
        if (_session is null || (_previewSource is null && _previewSource16 is null))
        {
            return;
        }
        var document = _session.Document;
        var crop = CropGeometry.Preset(preset, _sourceWidth, _sourceHeight,
                                       document.Orientation.QuarterTurns);
        document.Crop = crop;
        CropLabel = crop is null ? "Original" : preset;
        ScheduleCommit();
        ScheduleRender();
    }

    public void ResetAdjustments()
    {
        if (_session is null)
        {
            return;
        }
        foreach (var item in Adjustments)
        {
            item.SetSilently(0);
            _session.Document.SetAdjustment(item.Key, 0);
        }
        _session.Document.Orientation = _session.Document.Orientation.WithAngle(0);
        _straightenAngle = 0;
        Raise(nameof(StraightenAngle));
        ScheduleCommit();
        ScheduleRender();
    }

    public bool CanClose()
    {
        if (_session is null || !IsDirty)
        {
            return true;
        }
        var answer = System.Windows.MessageBox.Show(
            "The document has unsaved changes. Close anyway?",
            "Retouch Studio", System.Windows.MessageBoxButton.YesNo,
            System.Windows.MessageBoxImage.Warning);
        return answer == System.Windows.MessageBoxResult.Yes;
    }

    private async Task AdoptAsync(ProjectSession session)
    {
        PixelBuffer? decoded = null;
        PixelBuffer16? decoded16 = null;
        try
        {
            // A file that stores 16-bit samples previews through the 16-bit
            // pipeline, so the preview does not lose what the source has before
            // an adjustment can amplify it. Everything else stays 8-bit.
            if (await _codec.ReadBitDepthAsync(session.ImagePath) >= 16)
            {
                decoded16 = await _codec.Decode16Async(session.ImagePath);
            }
            else
            {
                decoded = await _codec.DecodeAsync(session.ImagePath);
            }
        }
        catch
        {
            // The window never adopted this session, so the failed decode must
            // not leave its history handle open.
            session.Dispose();
            throw;
        }

        _sourceWidth = decoded?.Width ?? decoded16!.Width;
        _sourceHeight = decoded?.Height ?? decoded16!.Height;
        if (decoded16 is not null)
        {
            var wide = decoded16;
            _previewSource16 = await Task.Run(() => wide.ResizeLongEdge(PreviewLongEdge));
            _previewSource = null;
        }
        else
        {
            var narrow = decoded!;
            _previewSource = await Task.Run(() => narrow.ResizeLongEdge(PreviewLongEdge));
            _previewSource16 = null;
        }

        _loading = true;
        try
        {
            _session = session;
            foreach (var item in Adjustments)
            {
                item.SetSilently(session.Document.Adjustment(item.Key));
            }
            _straightenAngle = Math.Round(session.Document.Orientation.Angle, 1);
            Raise(nameof(StraightenAngle));
            _exportFormat = session.Document.ExportFormat;
            _exportQuality = session.Document.ExportQuality;
            _exportLongEdge = session.Document.ExportLongEdge ?? 0;
            Raise(nameof(ExportFormat));
            Raise(nameof(ExportQuality));
            Raise(nameof(ExportLongEdge));
            Raise(nameof(LongEdgeIndex));
            CropLabel = session.Document.Crop is null ? "Original" : "Custom";
            Raise(nameof(HasDocument));
            Raise(nameof(Title));
        }
        finally
        {
            _loading = false;
        }

        await RenderPreviewAsync();
        await RenderOriginalPreviewAsync();
        RefreshState();
    }

    private void CloseSession()
    {
        _renderTimer.Stop();
        _commitTimer.Stop();
        _commitPending = false;
        _session?.Dispose();
        _session = null;
        _previewSource = null;
        _previewSource16 = null;
        _sourceWidth = 0;
        _sourceHeight = 0;
        Set(ref _preview, null, nameof(Preview));
        _originalPreview = null;
        _isPeekingOriginal = false;
        DimensionText = "";
        Raise(nameof(HasDocument));
        Raise(nameof(Title));
    }

    private void OnAdjustmentChanged(AdjustmentItem item)
    {
        if (_loading || _session is null)
        {
            return;
        }
        _session.Document.SetAdjustment(item.Key, item.Value);
        ScheduleCommit();
        ScheduleRender();
    }

    private void ScheduleRender()
    {
        _renderTimer.Stop();
        _renderTimer.Start();
    }

    private void ScheduleCommit()
    {
        _commitPending = true;
        IsDirty = true;
        Raise(nameof(Title));
        _commitTimer.Stop();
        _commitTimer.Start();
    }

    /// <summary>Records a pending slider or orientation edit as one undo step.</summary>
    public void FlushCommit()
    {
        _commitTimer.Stop();
        if (!_commitPending || _session is null)
        {
            return;
        }
        _session.Commit();
        _commitPending = false;
        RefreshState();
    }

    private async Task RenderPreviewAsync()
    {
        var source = _previewSource;
        var source16 = _previewSource16;
        if (_session is null || (source is null && source16 is null))
        {
            return;
        }
        var token = ++_renderToken;
        var document = _isCropping ? WithoutCrop(_session.Document) : _session.Document;

        var bitmap = await Task.Run(() =>
        {
            if (source16 is not null)
            {
                return ToBitmap(
                    ExportRunner.RenderDocument16(source16, document).ToBgra8());
            }
            return ToBitmap(ExportRunner.RenderDocument(source!, document));
        });

        if (token != _renderToken)
        {
            return;
        }
        Set(ref _preview, bitmap, nameof(Preview));
        var width = source?.Width ?? source16!.Width;
        var height = source?.Height ?? source16!.Height;
        DimensionText = $"{width}×{height} preview";
    }

    /// <summary>
    /// A copy of the document without its crop: the overlay drags a rectangle
    /// over the upright, uncropped frame the owner sees, exactly as macOS does,
    /// and the finished frame returns when the crop is applied.
    /// </summary>
    private static DocumentModel WithoutCrop(DocumentModel document)
    {
        var copy = new DocumentModel((JsonObject)document.Root.DeepClone());
        copy.Crop = null;
        return copy;
    }

    private void LoadFromDocument()
    {
        if (_session is null)
        {
            return;
        }
        _loading = true;
        try
        {
            foreach (var item in Adjustments)
            {
                item.SetSilently(_session.Document.Adjustment(item.Key));
            }
            _straightenAngle = Math.Round(_session.Document.Orientation.Angle, 1);
            Raise(nameof(StraightenAngle));
            CropLabel = _session.Document.Crop is null ? "Original" : "Custom";
        }
        finally
        {
            _loading = false;
        }
    }

    private void RefreshState()
    {
        if (_session is null)
        {
            CanUndo = false;
            CanRedo = false;
            IsDirty = false;
            return;
        }
        var (canUndo, canRedo) = _session.HistoryFlags();
        CanUndo = canUndo;
        CanRedo = canRedo;
        IsDirty = _session.IsDirty();
        Raise(nameof(Title));
    }

    /// <summary>
    /// Renders the compare original once per open: the preview-sized source
    /// with no orientation, crop or adjustment, which is the photo as the
    /// decoder delivered it (EXIF rotation baked in).
    /// </summary>
    private async Task RenderOriginalPreviewAsync()
    {
        var source = _previewSource;
        var source16 = _previewSource16;
        var session = _session;
        if (session is null || (source is null && source16 is null))
        {
            _originalPreview = null;
            return;
        }
        var plain = new DocumentModel(new JsonObject());
        var bitmap = await Task.Run(() =>
        {
            if (source16 is not null)
            {
                return ToBitmap(ExportRunner.RenderDocument16(source16, plain).ToBgra8());
            }
            return ToBitmap(ExportRunner.RenderDocument(source!, plain));
        });
        if (!ReferenceEquals(_session, session))
        {
            return;
        }
        _originalPreview = bitmap;
        Raise(nameof(CanPeekOriginal));
    }

    private static BitmapSource ToBitmap(PixelBuffer buffer)
    {
        var bitmap = BitmapSource.Create(buffer.Width, buffer.Height, 96, 96,
                                         PixelFormats.Bgra32, null,
                                         buffer.Pixels, buffer.Width * 4);
        bitmap.Freeze();
        return bitmap;
    }

    private void Set<T>(ref T field, T value, [CallerMemberName] string? name = null)
    {
        if (EqualityComparer<T>.Default.Equals(field, value))
        {
            return;
        }
        field = value;
        Raise(name);
    }

    private void Raise(string? name) =>
        PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(name));
}
