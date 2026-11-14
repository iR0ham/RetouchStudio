using System.IO;
using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using Microsoft.Win32;

namespace RetouchStudio.App;

/// <summary>
/// The window. Every button maps to one view-model call; the view model owns the
/// session and the pixels, so this class only shows dialogs and reports errors.
/// </summary>
public partial class MainWindow : Window
{
    private const string ProjectExtension = "retouch";

    private readonly EditorViewModel _vm = new();

    public MainWindow()
    {
        InitializeComponent();
        DataContext = _vm;
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
        }
    }

    private async void OpenPhoto_Click(object sender, RoutedEventArgs e)
    {
        if (!_vm.CanClose())
        {
            return;
        }
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
            _vm.ApplyCrop(preset);
        }
    }

    private void LongEdge_Changed(object sender, SelectionChangedEventArgs e)
    {
        if (LongEdgeBox is null)
        {
            return;
        }
        _vm.ExportLongEdge = LongEdgeBox.SelectedIndex switch
        {
            1 => 4096,
            2 => 2048,
            3 => 1080,
            _ => 0,
        };
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
