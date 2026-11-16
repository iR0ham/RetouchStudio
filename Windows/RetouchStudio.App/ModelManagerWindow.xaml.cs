using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using RetouchStudio.AI.Models;

namespace RetouchStudio.App;

/// <summary>
/// The model manager: catalog entries, installed versions, the active version,
/// verification, update/rollback, disk use, and a download that starts only
/// after the owner sees the version, size, licences, source and checksum.
/// </summary>
public partial class ModelManagerWindow : Window
{
    private ModelStore? _store;
    private CancellationTokenSource? _installCancel;
    private bool _busy;

    public ModelManagerWindow()
    {
        InitializeComponent();
        try
        {
            _store = ModelStore.CreateProduction();
        }
        catch (Exception error)
        {
            NoticeText.Text = $"The model catalog could not be loaded: {error.Message}";
        }
        Loaded += async (_, _) => await RefreshAsync();
    }

    private async Task RefreshAsync()
    {
        if (_store is null) return;
        try
        {
            var records = await Task.Run(() => _store.Records());
            var used = await Task.Run(() => _store.DiskUsage());
            var free = _store.AvailableBytes();
            DiskText.Text = $"On disk: {Bytes(used)} · Free: {Bytes(free)}";
            RowsPanel.Children.Clear();
            foreach (var record in records) RowsPanel.Children.Add(BuildRecord(record));
            RowsPanel.IsEnabled = !_busy;
        }
        catch (Exception error)
        {
            NoticeText.Text = Describe(error);
        }
    }

    private Border BuildRecord(ModelRecord record)
    {
        var entry = record.Entry;
        var panel = new StackPanel();
        var header = new DockPanel { LastChildFill = false };
        var name = new TextBlock
        {
            Text = entry.Name,
            FontSize = 13,
            FontWeight = FontWeights.SemiBold,
            VerticalAlignment = VerticalAlignment.Center,
        };
        header.Children.Add(name);
        var status = new Border
        {
            Background = record.ActiveVersion is null
                ? (Brush)FindResource("PanelBrush")
                : (Brush)FindResource("AccentBrush"),
            CornerRadius = new CornerRadius(8),
            Padding = new Thickness(7, 2, 7, 2),
            Margin = new Thickness(8, 0, 0, 0),
            VerticalAlignment = VerticalAlignment.Center,
            Child = new TextBlock
            {
                Text = record.ActiveVersion is not null ? "Installed"
                    : record.Availability == ModelAvailability.Unverifiable ? "Unverifiable"
                    : record.Availability == ModelAvailability.UnsupportedPlatform
                        ? "Unavailable" : "Not installed",
                FontSize = 10,
                Foreground = record.ActiveVersion is null
                    ? (Brush)FindResource("MutedBrush")
                    : new SolidColorBrush(Color.FromRgb(16, 18, 20)),
            },
        };
        header.Children.Add(status);
        var actions = new StackPanel
        {
            Orientation = Orientation.Horizontal,
            HorizontalAlignment = HorizontalAlignment.Right,
        };
        DockPanel.SetDock(actions, Dock.Right);
        header.Children.Add(actions);
        if (record.Availability == ModelAvailability.Ready &&
            !record.Versions.Any(v => v.Version == entry.Version))
        {
            var verb = record.Versions.Count == 0 ? "Install…" : "Update…";
            var button = Chip(verb, (_, _) => BeginInstall(entry));
            button.IsEnabled = !_busy;
            actions.Children.Add(button);
        }
        panel.Children.Add(header);

        panel.Children.Add(Line(
            $"{Capabilities(entry)} · Version {entry.Version} · {Bytes(entry.SizeBytes)} · {entry.WeightsLicense}",
            "MutedBrush", 11));
        var source = Uri.TryCreate(entry.SourceUrl, UriKind.Absolute, out var uri)
            ? uri.Host : "—";
        var sha = (entry.Sha256 ?? "").Length > 16 ? entry.Sha256![..16] : "—";
        panel.Children.Add(Line(
            $"{source} · {entry.CodeLicense} / {entry.WeightsLicense} · SHA-256 {sha}…",
            "MutedBrush", 10.5));
        if (record.Availability == ModelAvailability.Unverifiable)
            panel.Children.Add(Line($"Not installable: {record.UnverifiableReason}",
                "SkyBrush", 10.5));
        else if (record.Availability == ModelAvailability.UnsupportedPlatform)
            panel.Children.Add(Line("Not available on this platform", "SkyBrush", 10.5));

        foreach (var version in record.Versions)
            panel.Children.Add(BuildVersion(record, version));

        if (_store is not null && _store.LegacyBytes(entry) is { } legacy)
        {
            var legacyRow = new DockPanel
            {
                Margin = new Thickness(0, 4, 0, 0),
                LastChildFill = false,
            };
            legacyRow.Children.Add(Line(
                $"An older installation is on disk ({Bytes(legacy)}).", "MutedBrush", 10.5));
            var adopt = Chip("Adopt…", (_, _) => BeginAdopt(entry, legacy));
            adopt.IsEnabled = !_busy && entry.IsVerifiable;
            DockPanel.SetDock(adopt, Dock.Right);
            legacyRow.Children.Add(adopt);
            panel.Children.Add(legacyRow);
        }

        return new Border
        {
            Background = (Brush)FindResource("PanelBrush"),
            BorderBrush = (Brush)FindResource("LineBrush"),
            BorderThickness = new Thickness(1),
            CornerRadius = new CornerRadius(6),
            Padding = new Thickness(12),
            Margin = new Thickness(0, 0, 0, 8),
            Child = panel,
        };
    }

    private DockPanel BuildVersion(ModelRecord record, ModelVersionState version)
    {
        var row = new DockPanel { Margin = new Thickness(2, 4, 0, 0), LastChildFill = false };
        var label = new TextBlock
        {
            Text = $"Version {version.Version}",
            FontSize = 10.5,
            VerticalAlignment = VerticalAlignment.Center,
            Foreground = version.Active
                ? (Brush)FindResource("TextBrush")
                : (Brush)FindResource("MutedBrush"),
        };
        row.Children.Add(label);
        if (version.Active)
        {
            var active = new TextBlock
            {
                Text = "Active",
                FontSize = 9.5,
                Margin = new Thickness(8, 0, 0, 0),
                VerticalAlignment = VerticalAlignment.Center,
                Foreground = (Brush)FindResource("AccentBrush"),
            };
            row.Children.Add(active);
        }
        if (!version.ManifestOk)
            row.Children.Add(Line(" · manifest is damaged", "SkyBrush", 9.5));

        var actions = new StackPanel
        {
            Orientation = Orientation.Horizontal,
            HorizontalAlignment = HorizontalAlignment.Right,
        };
        DockPanel.SetDock(actions, Dock.Right);
        var verify = Chip("Verify", (_, _) => BeginVerify(record.Entry, version.Version));
        verify.IsEnabled = !_busy;
        actions.Children.Add(verify);
        if (!version.Active)
        {
            var use = Chip("Use", (_, _) => BeginActivate(record.Entry, version.Version));
            use.IsEnabled = !_busy && record.IsVerifiable;
            actions.Children.Add(use);
        }
        var remove = Chip("Remove…", (_, _) => BeginRemove(record, version.Version));
        remove.IsEnabled = !_busy;
        actions.Children.Add(remove);
        row.Children.Add(actions);
        return row;
    }

    private async void BeginInstall(ModelCatalogEntry entry)
    {
        if (_store is null || _busy) return;
        var host = Uri.TryCreate(entry.SourceUrl, UriKind.Absolute, out var uri)
            ? uri.Host : entry.SourceUrl;
        var sha = (entry.Sha256 ?? "").Length > 16 ? entry.Sha256![..16] : "—";
        var text = $"{entry.Files.Count} file(s), {Bytes(entry.SizeBytes)}, from {host}.\n\n" +
                   $"Code licence: {entry.CodeLicense}\nWeights licence: {entry.WeightsLicense}\n" +
                   $"SHA-256 (manifest): {sha}…\n\n" +
                   "This is the only step that uses the internet. Nothing is installed unless every file matches its size and checksum.";
        if (MessageBox.Show(this, text, $"Install {entry.Name}, version {entry.Version}?",
                MessageBoxButton.OKCancel, MessageBoxImage.Question) != MessageBoxResult.OK)
            return;
        await RunTransfer(entry, () => _store.InstallAsync(entry,
            TransferProgress(entry), _installCancel!.Token), null);
    }

    private async void BeginAdopt(ModelCatalogEntry entry, long legacy)
    {
        if (_store is null || _busy) return;
        var text = $"The app will hash the {Bytes(legacy)} already on this PC against the catalog. " +
                   "If every file matches, they are moved into the versioned store, with no download and no network use. " +
                   "If anything differs, nothing is moved.";
        if (MessageBox.Show(this, text, $"Adopt the existing {entry.Name} files?",
                MessageBoxButton.OKCancel, MessageBoxImage.Question) != MessageBoxResult.OK)
            return;
        await RunTransfer(entry, () => _store.MigrateLegacyAsync(entry,
            TransferProgress(entry), _installCancel!.Token), "adopted");
    }

    private async Task RunTransfer(ModelCatalogEntry entry, Func<Task<ModelVersionState>> work,
        string? verb)
    {
        _busy = true;
        RowsPanel.IsEnabled = false;
        _installCancel = new CancellationTokenSource();
        ProgressPanel.Visibility = Visibility.Visible;
        ProgressLabel.Text = $"{entry.Name} · version {entry.Version}";
        TransferBar.IsIndeterminate = entry.SizeBytes is null;
        TransferBar.Value = 0;
        NoticeText.Text = "";
        try
        {
            await Task.Run(work);
            NoticeText.Text = verb == "adopted"
                ? $"{entry.Name} was moved into the versioned store."
                : $"{entry.Name} is installed.";
        }
        catch (Exception error)
        {
            NoticeText.Text = Describe(error);
        }
        finally
        {
            _busy = false;
            _installCancel.Dispose();
            _installCancel = null;
            ProgressPanel.Visibility = Visibility.Collapsed;
            await RefreshAsync();
        }
    }

    private IProgress<ModelTransferProgress> TransferProgress(ModelCatalogEntry entry) =>
        new Progress<ModelTransferProgress>(update =>
        {
            var total = update.TotalBytes ?? entry.SizeBytes;
            if (total is > 0)
            {
                TransferBar.IsIndeterminate = false;
                TransferBar.Value = Math.Min(100,
                    update.ReceivedBytes * 100.0 / total.Value);
                ProgressLabel.Text =
                    $"{entry.Name} · {Bytes(update.ReceivedBytes)} / {Bytes(total)}";
            }
            else
            {
                TransferBar.IsIndeterminate = true;
                ProgressLabel.Text = $"{entry.Name} · {Bytes(update.ReceivedBytes)}";
            }
        });

    private async void BeginVerify(ModelCatalogEntry entry, string version)
    {
        if (_store is null || _busy) return;
        _busy = true;
        RowsPanel.IsEnabled = false;
        try
        {
            var report = await Task.Run(() => _store.Verify(entry, version, true));
            NoticeText.Text = report.Ok
                ? $"{entry.Name} {version}: checksums match."
                : $"Verification failed: {report.Problems.FirstOrDefault()?.File} " +
                  $"({report.Problems.FirstOrDefault()?.Reason})";
        }
        catch (Exception error)
        {
            NoticeText.Text = Describe(error);
        }
        finally
        {
            _busy = false;
            await RefreshAsync();
        }
    }

    private async void BeginActivate(ModelCatalogEntry entry, string version)
    {
        if (_store is null || _busy) return;
        _busy = true;
        RowsPanel.IsEnabled = false;
        try
        {
            await Task.Run(() => _store.Activate(entry, version));
            NoticeText.Text = $"{entry.Name} now uses version {version}.";
        }
        catch (Exception error)
        {
            NoticeText.Text = Describe(error);
        }
        finally
        {
            _busy = false;
            await RefreshAsync();
        }
    }

    private async void BeginRemove(ModelRecord record, string version)
    {
        if (_store is null || _busy) return;
        var only = record.Versions.Count <= 1;
        if (MessageBox.Show(this,
                $"Version {version} is deleted from this PC. You can download it again later.",
                $"Remove {record.Entry.Name}?", MessageBoxButton.OKCancel,
                MessageBoxImage.Warning) != MessageBoxResult.OK)
            return;
        _busy = true;
        RowsPanel.IsEnabled = false;
        try
        {
            await Task.Run(() =>
            {
                if (only) _store.DeleteAll(record.Entry);
                else _store.Delete(record.Entry, version);
            });
            NoticeText.Text = $"{record.Entry.Name} was removed.";
        }
        catch (Exception error)
        {
            NoticeText.Text = Describe(error);
        }
        finally
        {
            _busy = false;
            await RefreshAsync();
        }
    }

    private void Cancel_Click(object sender, RoutedEventArgs e) => _installCancel?.Cancel();

    private void Done_Click(object sender, RoutedEventArgs e) => Close();

    private static string Describe(Exception error) =>
        error is OperationCanceledException
            ? "Cancelled. Nothing was installed."
            : error is ModelStoreError model
                ? model.Code switch
                {
                    "E_CANCELLED" => "Download cancelled. Nothing was installed.",
                    "E_MODEL_LEASED" =>
                        "This version is in use by a running job or another window.",
                    _ => model.Message,
                }
                : error.Message;

    private string Capabilities(ModelCatalogEntry entry) =>
        string.Join(" · ", entry.Capabilities.Select(capability => capability switch
        {
            "mask.click" => "Selection",
            "upscale.4x" => "Upscaling",
            "inpaint.spot" or "inpaint.object" => "Healing",
            "generative.edit" or "generative.reimagine" => "Object removal",
            _ => capability,
        }).Distinct());

    private static TextBlock Line(string text, string brush, double size) => new()
    {
        Text = text,
        FontSize = size,
        TextWrapping = TextWrapping.Wrap,
        Margin = new Thickness(0, 2, 0, 0),
        Foreground = (Brush)Application.Current.FindResource(brush),
    };

    private static Button Chip(string text, RoutedEventHandler click)
    {
        var button = new Button
        {
            Content = text,
            Style = (Style)Application.Current.FindResource("ToolButton"),
            Margin = new Thickness(6, 0, 0, 0),
        };
        button.Click += click;
        return button;
    }

    private static string Bytes(long? bytes)
    {
        if (bytes is not > 0) return "size unknown";
        string[] units = { "B", "KB", "MB", "GB", "TB" };
        var value = (double)bytes.Value;
        var unit = 0;
        while (value >= 1024 && unit < units.Length - 1)
        {
            value /= 1024;
            unit++;
        }
        return unit == 0 ? $"{value:0} {units[unit]}" : $"{value:0.0} {units[unit]}";
    }
}
