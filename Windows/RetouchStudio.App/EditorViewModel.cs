using System.Collections.ObjectModel;
using System.ComponentModel;
using System.Globalization;
using System.IO;
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
    private int _sourceWidth;
    private int _sourceHeight;
    private int _renderToken;
    private bool _commitPending;
    private bool _loading;
    private BitmapSource? _preview;
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

    public BitmapSource? Preview
    {
        get => _preview;
        private set => Set(ref _preview, value);
    }

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
            if (_session is not null)
            {
                _session.Document.ExportLongEdge = value > 0 ? value : null;
                ScheduleCommit();
            }
        }
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
        Status = $"{Path.GetFileName(projectPath)} opened.";
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
        _session.Document.Orientation =
            _session.Document.Orientation.WithQuarterTurn(quarterTurns);
        ScheduleCommit();
        ScheduleRender();
    }

    public void Flip()
    {
        if (_session is null)
        {
            return;
        }
        _session.Document.Orientation = _session.Document.Orientation.WithFlip();
        ScheduleCommit();
        ScheduleRender();
    }

    /// <summary>
    /// A centred crop at a fixed aspect. Freeform crop handles are not part of
    /// this host yet; the presets cover the common portrait and print ratios and
    /// write the same normalized crop record the macOS app reads.
    /// </summary>
    public void ApplyCrop(string preset)
    {
        if (_session is null || _previewSource is null)
        {
            return;
        }
        var document = _session.Document;
        if (preset == "original")
        {
            document.Crop = null;
            CropLabel = "Original";
        }
        else
        {
            var aspect = preset switch
            {
                "square" => 1.0,
                "4:5" => 4.0 / 5.0,
                "3:2" => 3.0 / 2.0,
                "16:9" => 16.0 / 9.0,
                _ => 1.0,
            };
            var photoAspect = document.Orientation.QuarterTurns % 2 == 0
                ? _sourceWidth / (double)_sourceHeight
                : _sourceHeight / (double)_sourceWidth;
            double width = 1;
            double height = 1;
            if (aspect > photoAspect)
            {
                height = photoAspect / aspect;
            }
            else
            {
                width = aspect / photoAspect;
            }
            document.Crop = new CropValue((1 - width) / 2, (1 - height) / 2, width, height);
            CropLabel = preset;
        }
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
        PixelBuffer decoded;
        try
        {
            decoded = await _codec.DecodeAsync(session.ImagePath);
        }
        catch
        {
            // The window never adopted this session, so the failed decode must
            // not leave its history handle open.
            session.Dispose();
            throw;
        }

        _sourceWidth = decoded.Width;
        _sourceHeight = decoded.Height;
        _previewSource = await Task.Run(() => decoded.ResizeLongEdge(PreviewLongEdge));

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
            CropLabel = session.Document.Crop is null ? "Original" : "Custom";
            Raise(nameof(HasDocument));
            Raise(nameof(Title));
        }
        finally
        {
            _loading = false;
        }

        await RenderPreviewAsync();
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
        _sourceWidth = 0;
        _sourceHeight = 0;
        Preview = null;
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
        if (_session is null || _previewSource is null)
        {
            return;
        }
        var token = ++_renderToken;
        var source = _previewSource;
        var document = _session.Document;

        var bitmap = await Task.Run(() =>
        {
            var rendered = ExportRunner.RenderDocument(source, document);
            return ToBitmap(rendered);
        });

        if (token != _renderToken)
        {
            return;
        }
        Preview = bitmap;
        DimensionText = $"{source.Width}×{source.Height} preview";
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
