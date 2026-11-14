using System.IO;
using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;
using System.Windows.Input;
using Line = System.Windows.Shapes.Line;
using Microsoft.Win32;
using RetouchStudio.Core.Project;
using RetouchStudio.Core.View;

namespace RetouchStudio.App;

/// <summary>
/// The window. Every button maps to one view-model call; the view model owns the
/// session and the pixels, so this class only shows dialogs and reports errors.
/// </summary>
public partial class MainWindow : Window
{
    private const string ProjectExtension = "retouch";

    private readonly EditorViewModel _vm = new();

    // The crop overlay remembers the frame being dragged until Apply. The
    // preview underneath is rendered without a crop while the overlay is open.
    private CropValue _pendingCrop = new(0, 0, 1, 1);
    private bool _cropMode;

    // Canvas zoom and pan. The arithmetic lives in CanvasView so the headless
    // checks can pin it; this window only feeds it sizes and pointer points.
    private readonly CanvasView _view = new();
    private Point? _panPoint;

    public MainWindow()
    {
        InitializeComponent();
        DataContext = _vm;
        _vm.PropertyChanged += (_, args) =>
        {
            if (args.PropertyName == nameof(EditorViewModel.HasDocument))
            {
                // A new photo starts fitted: a zoom chosen for the previous one
                // would frame a region the new photo may not even have.
                _panPoint = null;
                _view.Reset();
                ApplyView();
            }
            if (_cropMode && args.PropertyName == nameof(EditorViewModel.Preview))
            {
                UpdateCropOverlay();
            }
        };
        ApplyView();
    }

    private void Window_Loaded(object sender, RoutedEventArgs e)
    {
        TryApplyDarkTitleBar();

        // A hosted CI session does not always expose a main-window handle, so
        // the smoke run asks the loaded window to write its own marker.
        var marker = Environment.GetEnvironmentVariable("RETOUCHSTUDIO_SMOKE");
        if (!string.IsNullOrEmpty(marker))
        {
            File.WriteAllText(marker, Title);
        }
    }

    private void Window_Closing(object sender, System.ComponentModel.CancelEventArgs e)
    {
        _vm.FlushCommit();
        if (!_vm.CanClose())
        {
            e.Cancel = true;
        }
    }

    private void Window_PreviewKeyDown(object sender, KeyEventArgs e)
    {
        var modifiers = Keyboard.Modifiers;
        var ctrl = modifiers.HasFlag(ModifierKeys.Control);
        var shift = modifiers.HasFlag(ModifierKeys.Shift);

        switch (e.Key)
        {
            case Key.O when ctrl && shift:
                OpenProject_Click(sender, e);
                e.Handled = true;
                break;
            case Key.O when ctrl:
                OpenPhoto_Click(sender, e);
                e.Handled = true;
                break;
            case Key.S when ctrl:
                Save_Click(sender, e);
                e.Handled = true;
                break;
            case Key.E when ctrl:
                Export_Click(sender, e);
                e.Handled = true;
                break;
            case Key.Z when ctrl && shift:
            case Key.Y when ctrl:
                _vm.Redo();
                e.Handled = true;
                break;
            case Key.Z when ctrl:
                _vm.Undo();
                e.Handled = true;
                break;
            case Key.OemPlus or Key.Add when ctrl:
                StepZoom(inward: true);
                e.Handled = true;
                break;
            case Key.OemMinus or Key.Subtract when ctrl:
                StepZoom(inward: false);
                e.Handled = true;
                break;
            case Key.D0 or Key.NumPad0 when ctrl:
                ResetZoomView();
                e.Handled = true;
                break;
            case Key.Escape when _cropMode:
                EndCrop();
                e.Handled = true;
                break;
            case Key.Space when _vm.HasDocument:
                // Handled even while the original is still rendering, so the
                // key cannot fall through and click a focused button.
                _vm.IsPeekingOriginal = true;
                e.Handled = true;
                break;
        }
    }

    /// <summary>
    /// Releasing the compare key returns to the edit. Doing it on key-up (not
    /// a toggle) keeps the "before" visible only while the key is held, as
    /// macOS peeks with the space bar.
    /// </summary>
    private void Window_PreviewKeyUp(object sender, KeyEventArgs e)
    {
        if (e.Key == Key.Space && _vm.IsPeekingOriginal)
        {
            _vm.IsPeekingOriginal = false;
            e.Handled = true;
        }
    }

    /// <summary>A peek held while the window loses focus must not stick.</summary>
    private void Window_Deactivated(object sender, EventArgs e) =>
        _vm.IsPeekingOriginal = false;

    /// <summary>
    /// The unzoomed fitted photo, in PreviewHost coordinates. It is computed
    /// from layout and the bitmap's own aspect, not from the rendered visual,
    /// so the zoom transform applied to the image cannot feed back into the
    /// maths that positions it.
    /// </summary>
    private bool TryFittedRect(out DisplayRect fit)
    {
        fit = default;
        var bitmap = _vm.Preview;
        if (bitmap is null)
        {
            return false;
        }
        var margin = PreviewImage.Margin;
        var width = PreviewHost.ActualWidth - margin.Left - margin.Right;
        var height = PreviewHost.ActualHeight - margin.Top - margin.Bottom;
        if (width <= 0 || height <= 0)
        {
            return false;
        }
        var content = CropGeometry.Fit(bitmap.PixelWidth, bitmap.PixelHeight, width, height);
        fit = content with { X = margin.Left + content.X, Y = margin.Top + content.Y };
        return fit.Width > 0 && fit.Height > 0;
    }

    /// <summary>Pushes the CanvasView state onto the image and the dock.</summary>
    private void ApplyView()
    {
        PreviewScale.ScaleX = _view.Zoom;
        PreviewScale.ScaleY = _view.Zoom;
        PreviewPan.X = _view.PanX;
        PreviewPan.Y = _view.PanY;
        ZoomText.Text = _view.ZoomText;
        ZoomFitButton.IsEnabled = _view.IsZoomed;
        ZoomOutButton.IsEnabled = _view.IsZoomed;
        ZoomInButton.IsEnabled = _view.Zoom < CanvasView.MaxZoom - 0.001;
        PreviewHost.Cursor = !_view.IsZoomed ? Cursors.Arrow
                           : _panPoint is not null ? Cursors.SizeAll
                           : Cursors.Hand;
    }

    private void ResetZoomView()
    {
        _panPoint = null;
        _view.Reset();
        ApplyView();
    }

    private void StepZoom(bool inward)
    {
        if (!_vm.HasDocument || _cropMode || !TryFittedRect(out var fit))
        {
            return;
        }
        if (inward)
        {
            _view.ZoomIn(fit.Width, fit.Height, PreviewHost.ActualWidth, PreviewHost.ActualHeight);
        }
        else
        {
            _view.ZoomOut(fit.Width, fit.Height, PreviewHost.ActualWidth, PreviewHost.ActualHeight);
        }
        ApplyView();
    }

    /// <summary>
    /// Ctrl+wheel zooms about the pointer, as macOS does with ⌘-scroll; a plain
    /// wheel pans a zoomed photo, as macOS scroll does. A fitted photo has
    /// nothing to pan, so the plain wheel is left alone.
    /// </summary>
    private void PreviewHost_MouseWheel(object sender, MouseWheelEventArgs e)
    {
        if (!_vm.HasDocument || _cropMode || !TryFittedRect(out var fit))
        {
            return;
        }
        if (Keyboard.Modifiers.HasFlag(ModifierKeys.Control))
        {
            var point = e.GetPosition(PreviewHost);
            _view.SetZoom(_view.Zoom * Math.Exp(e.Delta * 0.0015), point.X, point.Y,
                          fit.Width, fit.Height, PreviewHost.ActualWidth,
                          PreviewHost.ActualHeight);
            ApplyView();
            e.Handled = true;
        }
        else if (_view.IsZoomed)
        {
            // One notch is 120 units; dividing keeps a click to a comfortable
            // strip instead of half the photo.
            _view.PanBy(0, e.Delta / 2.0, fit.Width, fit.Height,
                        PreviewHost.ActualWidth, PreviewHost.ActualHeight);
            ApplyView();
            e.Handled = true;
        }
    }

    private void PreviewHost_MouseLeftButtonDown(object sender, MouseButtonEventArgs e)
    {
        if (!_vm.HasDocument || _cropMode)
        {
            return;
        }
        if (e.ClickCount == 2)
        {
            if (!TryFittedRect(out var fitted))
            {
                return;
            }
            _panPoint = null;
            if (PreviewHost.IsMouseCaptured)
            {
                PreviewHost.ReleaseMouseCapture();
            }
            _view.Toggle(fitted.Width, fitted.Height, PreviewHost.ActualWidth,
                         PreviewHost.ActualHeight);
            ApplyView();
            e.Handled = true;
            return;
        }
        if (!_view.IsZoomed)
        {
            return;
        }
        _panPoint = e.GetPosition(PreviewHost);
        PreviewHost.CaptureMouse();
        ApplyView();
        e.Handled = true;
    }

    private void PreviewHost_MouseMove(object sender, MouseEventArgs e)
    {
        if (_panPoint is not { } last || e.LeftButton != MouseButtonState.Pressed
            || !TryFittedRect(out var fit))
        {
            return;
        }
        var now = e.GetPosition(PreviewHost);
        _view.PanBy(now.X - last.X, now.Y - last.Y, fit.Width, fit.Height,
                    PreviewHost.ActualWidth, PreviewHost.ActualHeight);
        _panPoint = now;
        ApplyView();
    }

    private void PreviewHost_MouseLeftButtonUp(object sender, MouseButtonEventArgs e)
    {
        if (_panPoint is null)
        {
            return;
        }
        _panPoint = null;
        PreviewHost.ReleaseMouseCapture();
        ApplyView();
    }

    private void PreviewHost_LostMouseCapture(object sender, MouseEventArgs e)
    {
        if (_panPoint is null)
        {
            return;
        }
        _panPoint = null;
        ApplyView();
    }

    private void ZoomFit_Click(object sender, RoutedEventArgs e) => ResetZoomView();

    private void ZoomIn_Click(object sender, RoutedEventArgs e) => StepZoom(inward: true);

    private void ZoomOut_Click(object sender, RoutedEventArgs e) => StepZoom(inward: false);

    private async void OpenPhoto_Click(object sender, RoutedEventArgs e)
    {
        if (!_vm.CanClose())
        {
            return;
        }
        EndCrop();
        var dialog = new OpenFileDialog
        {
            Title = "Open Photo",
            Filter = "Images|*.jpg;*.jpeg;*.png;*.tif;*.tiff;*.bmp|All files|*.*",
        };
        if (dialog.ShowDialog(this) != true)
        {
            return;
        }
        try
        {
            await _vm.OpenImageAsync(dialog.FileName);
        }
        catch (Exception error)
        {
            Report("The photo could not be opened", error);
        }
    }

    private async void OpenProject_Click(object sender, RoutedEventArgs e)
    {
        if (!_vm.CanClose())
        {
            return;
        }
        EndCrop();
        var dialog = new OpenFileDialog
        {
            Title = "Open Project",
            Filter = $"Retouch Studio project|*.{ProjectExtension}|All files|*.*",
        };
        if (dialog.ShowDialog(this) != true)
        {
            return;
        }
        try
        {
            await _vm.OpenProjectAsync(dialog.FileName);
        }
        catch (Exception error)
        {
            Report("The project could not be opened", error);
        }
    }

    private void Save_Click(object sender, RoutedEventArgs e)
    {
        if (!_vm.HasDocument)
        {
            return;
        }
        var path = _vm.ProjectPath;
        if (path is null)
        {
            var dialog = new SaveFileDialog
            {
                Title = "Save Project",
                Filter = $"Retouch Studio project|*.{ProjectExtension}",
                DefaultExt = ProjectExtension,
                FileName = _vm.ImageName,
            };
            if (dialog.ShowDialog(this) != true)
            {
                return;
            }
            path = dialog.FileName;
        }
        try
        {
            _vm.Save(path);
        }
        catch (Exception error)
        {
            Report("The project could not be saved", error);
        }
    }

    private async void Export_Click(object sender, RoutedEventArgs e)
    {
        if (!_vm.HasDocument || !ConfirmUnsupportedEdits("the exported photo"))
        {
            return;
        }
        var format = _vm.ExportFormat;
        var extension = format switch
        {
            "png" => "png",
            "tiff" => "tif",
            _ => "jpg",
        };
        var dialog = new SaveFileDialog
        {
            Title = "Export Photo",
            Filter = format switch
            {
                "png" => "PNG|*.png",
                "tiff" => "TIFF|*.tif;*.tiff",
                _ => "JPEG|*.jpg;*.jpeg",
            },
            DefaultExt = extension,
            FileName = _vm.ImageName + "-export",
            AddExtension = true,
        };
        if (dialog.ShowDialog(this) != true)
        {
            return;
        }
        try
        {
            await _vm.ExportAsync(dialog.FileName);
        }
        catch (Exception error)
        {
            Report("The photo could not be exported", error);
        }
    }

    private async void BatchExport_Click(object sender, RoutedEventArgs e)
    {
        if (!_vm.HasDocument || !ConfirmUnsupportedEdits("the batch export"))
        {
            return;
        }
        var photos = new OpenFileDialog
        {
            Title = "Batch Export",
            Filter = "Images|*.jpg;*.jpeg;*.png;*.tif;*.tiff;*.bmp|All files|*.*",
            Multiselect = true,
            CheckFileExists = true,
        };
        if (photos.ShowDialog(this) != true || photos.FileNames.Length == 0)
        {
            return;
        }
        var folder = new OpenFolderDialog
        {
            Title = "Export the selection to",
        };
        if (folder.ShowDialog(this) != true)
        {
            return;
        }
        try
        {
            var results = await _vm.BatchExportAsync(photos.FileNames, folder.FolderName);
            var failed = results.Where(item => item.Error is not null).ToList();
            if (failed.Count > 0)
            {
                var lines = string.Join("\n", failed.Select(
                    item => $"{Path.GetFileName(item.Source)}: {item.Error}"));
                MessageBox.Show(this,
                    $"Exported {results.Count - failed.Count} of {results.Count}.\n\n{lines}",
                    "Batch Export", MessageBoxButton.OK, MessageBoxImage.Warning);
            }
        }
        catch (Exception error)
        {
            Report("The photos could not be exported", error);
        }
    }

    private void Undo_Click(object sender, RoutedEventArgs e) => _vm.Undo();

    private void Redo_Click(object sender, RoutedEventArgs e) => _vm.Redo();

    private void RotateLeft_Click(object sender, RoutedEventArgs e) => _vm.Rotate(-1);

    private void RotateRight_Click(object sender, RoutedEventArgs e) => _vm.Rotate(1);

    private void Flip_Click(object sender, RoutedEventArgs e) => _vm.Flip();

    private void Reset_Click(object sender, RoutedEventArgs e) => _vm.ResetAdjustments();

    private void Crop_Click(object sender, RoutedEventArgs e)
    {
        if (sender is Button { Tag: string preset })
        {
            EndCrop();
            _vm.ApplyCrop(preset);
        }
    }

    /// <summary>
    /// Opens the crop overlay on the uncropped picture. Until Apply, the
    /// document keeps its old crop; the overlay holds the new frame.
    /// </summary>
    private void CropCustom_Click(object sender, RoutedEventArgs e)
    {
        if (!_vm.HasDocument || _cropMode)
        {
            return;
        }
        _cropMode = true;
        // The overlay works in fitted coordinates, so a zoomed canvas returns
        // to fit before it opens; the crop is chosen on the whole photo.
        ResetZoomView();
        ZoomDock.Visibility = Visibility.Collapsed;
        _pendingCrop = _vm.CurrentCrop ?? new CropValue(0, 0, 1, 1);
        _vm.IsCropping = true;
        CropOverlay.Visibility = Visibility.Visible;
        CropBar.Visibility = Visibility.Visible;
        PreviewHost.SizeChanged += PreviewHost_SizeChanged;
        UpdateCropOverlay();
    }

    private void CropApply_Click(object sender, RoutedEventArgs e)
    {
        var crop = _pendingCrop;
        EndCrop();
        _vm.ApplyCustomCrop(crop);
    }

    private void CropCancel_Click(object sender, RoutedEventArgs e) => EndCrop();

    private void EndCrop()
    {
        if (!_cropMode)
        {
            return;
        }
        _cropMode = false;
        PreviewHost.SizeChanged -= PreviewHost_SizeChanged;
        ZoomDock.ClearValue(VisibilityProperty);
        CropOverlay.Visibility = Visibility.Collapsed;
        CropBar.Visibility = Visibility.Collapsed;
        _vm.IsCropping = false;
    }

    private void PreviewHost_SizeChanged(object sender, SizeChangedEventArgs e)
    {
        if (_cropMode)
        {
            UpdateCropOverlay();
        }
    }

    private void CropHandle_Drag(object sender, DragDeltaEventArgs e)
    {
        if (sender is not Thumb { Tag: string corner }
            || !Enum.TryParse<CropCorner>(corner, out var parsed))
        {
            return;
        }
        var fit = CurrentImageRect();
        if (fit.Width <= 0 || fit.Height <= 0)
        {
            return;
        }
        _pendingCrop = CropGeometry.Resize(_pendingCrop, parsed,
                                           e.HorizontalChange / fit.Width,
                                           e.VerticalChange / fit.Height);
        UpdateCropOverlay();
    }

    /// <summary>
    /// Dragging inside the frame slides the crop: the size is kept and the
    /// rectangle stays on the photo, as in the macOS overlay.
    /// </summary>
    private void CropBody_Drag(object sender, DragDeltaEventArgs e)
    {
        var fit = CurrentImageRect();
        if (fit.Width <= 0 || fit.Height <= 0)
        {
            return;
        }
        _pendingCrop = CropGeometry.Move(_pendingCrop, e.HorizontalChange / fit.Width,
                                         e.VerticalChange / fit.Height);
        UpdateCropOverlay();
    }

    /// <summary>Where the shown bitmap sits inside the overlay's canvas.</summary>
    private DisplayRect CurrentImageRect()
    {
        var bitmap = _vm.Preview;
        if (bitmap is null)
        {
            return default;
        }
        var origin = PreviewImage.TranslatePoint(new Point(0, 0), PreviewHost);
        var fit = CropGeometry.Fit(bitmap.PixelWidth, bitmap.PixelHeight,
                                   PreviewImage.ActualWidth, PreviewImage.ActualHeight);
        return fit with { X = fit.X + origin.X, Y = fit.Y + origin.Y };
    }

    private void UpdateCropOverlay()
    {
        var fit = CurrentImageRect();
        if (fit.Width <= 0 || fit.Height <= 0)
        {
            return;
        }
        var x = fit.X + _pendingCrop.X * fit.Width;
        var y = fit.Y + _pendingCrop.Y * fit.Height;
        var width = _pendingCrop.Width * fit.Width;
        var height = _pendingCrop.Height * fit.Height;

        CropFrame.Width = width;
        CropFrame.Height = height;
        Canvas.SetLeft(CropFrame, x);
        Canvas.SetTop(CropFrame, y);

        var canvasWidth = PreviewHost.ActualWidth;
        var canvasHeight = PreviewHost.ActualHeight;
        Place(CropShadeTop, 0, 0, canvasWidth, y);
        Place(CropShadeBottom, 0, y + height, canvasWidth,
              Math.Max(0, canvasHeight - y - height));
        Place(CropShadeLeft, 0, y, x, height);
        Place(CropShadeRight, x + width, y, Math.Max(0, canvasWidth - x - width), height);

        Place(CropBody, x, y, width, height);

        SetLine(CropThirdV1, x + width / 3, y, x + width / 3, y + height);
        SetLine(CropThirdV2, x + width * 2 / 3, y, x + width * 2 / 3, y + height);
        SetLine(CropThirdH1, x, y + height / 3, x + width, y + height / 3);
        SetLine(CropThirdH2, x, y + height * 2 / 3, x + width, y + height * 2 / 3);

        CropBadgeText.Text = _vm.CropPixelText(_pendingCrop);
        CropBadge.Measure(new Size(double.PositiveInfinity, double.PositiveInfinity));
        var badgeWidth = CropBadge.DesiredSize.Width;
        var badgeHeight = CropBadge.DesiredSize.Height;
        var badgeY = y + height + 8;
        if (badgeY + badgeHeight > canvasHeight)
        {
            badgeY = Math.Max(0, y - badgeHeight - 8);
        }
        Canvas.SetLeft(CropBadge, Math.Clamp(x + (width - badgeWidth) / 2, 0,
                                             Math.Max(0, canvasWidth - badgeWidth)));
        Canvas.SetTop(CropBadge, badgeY);

        Centre(CropTopLeft, x, y);
        Centre(CropTopRight, x + width, y);
        Centre(CropBottomLeft, x, y + height);
        Centre(CropBottomRight, x + width, y + height);
    }

    private static void Place(FrameworkElement element, double x, double y,
                              double width, double height)
    {
        element.Width = Math.Max(0, width);
        element.Height = Math.Max(0, height);
        Canvas.SetLeft(element, x);
        Canvas.SetTop(element, y);
    }

    private static void SetLine(Line line, double x1, double y1, double x2, double y2)
    {
        line.X1 = x1;
        line.Y1 = y1;
        line.X2 = x2;
        line.Y2 = y2;
    }

    private static void Centre(FrameworkElement element, double x, double y)
    {
        Canvas.SetLeft(element, x - element.Width / 2);
        Canvas.SetTop(element, y - element.Height / 2);
    }

    private void Report(string headline, Exception error) =>
        MessageBox.Show($"{headline}.\n\n{error.Message}", "Retouch Studio",
                        MessageBoxButton.OK, MessageBoxImage.Warning);

    /// <summary>
    /// A project can carry macOS-only edits this host keeps in the file but
    /// cannot draw. Writing a photo that silently lacks them would look like a
    /// successful export of work that is not in the pixels.
    /// </summary>
    private bool ConfirmUnsupportedEdits(string action)
    {
        var edits = _vm.UnsupportedEdits;
        if (edits.Count == 0)
        {
            return true;
        }
        var answer = MessageBox.Show(this,
            $"This project carries edits this host cannot render: {string.Join(", ", edits)}.\n\n" +
            $"They stay in the project file, but {action} will not include them. Continue?",
            "Retouch Studio", MessageBoxButton.YesNo, MessageBoxImage.Warning);
        return answer == MessageBoxResult.Yes;
    }

    /// <summary>
    /// The dark title bar is a Windows 10 20H1+ call. It is cosmetic, so a
    /// missing export or an older build falls back to the system colour.
    /// </summary>
    private void TryApplyDarkTitleBar()
    {
        const int UseImmersiveDarkMode = 20;
        const int UseImmersiveDarkModeBefore20H1 = 19;
        try
        {
            var handle = new System.Windows.Interop.WindowInteropHelper(this).Handle;
            var enabled = 1;
            if (DwmSetWindowAttribute(handle, UseImmersiveDarkMode, ref enabled,
                                      sizeof(int)) != 0)
            {
                DwmSetWindowAttribute(handle, UseImmersiveDarkModeBefore20H1,
                                      ref enabled, sizeof(int));
            }
        }
        catch (DllNotFoundException)
        {
        }
        catch (EntryPointNotFoundException)
        {
        }
    }

    [DllImport("dwmapi.dll")]
    private static extern int DwmSetWindowAttribute(IntPtr hwnd, int attribute,
                                                    ref int value, int size);
}
