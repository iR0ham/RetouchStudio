using System.Diagnostics;
using System.Windows.Automation;
using RetouchStudio.Imaging;

namespace RetouchStudio.UiTests;

/// <summary>
/// Drives the published editor through Windows UI Automation. The headless
/// suite proves the core, the codec and the view-model arithmetic; only an
/// automation client proves that a person's clicks reach them. The path here is
/// the golden one: open a photo through the Open dialog, move the Exposure
/// slider, export through the Save dialog, and read the written file back with
/// the real codec.
///
///   RetouchStudio.UiTests &lt;app.exe&gt; &lt;photo&gt; &lt;output.jpg&gt;
///
/// The app runs with an isolated recovery folder, so a leftover copy on the
/// machine cannot put a prompt in front of the window under test.
/// </summary>
internal static class Program
{
    private static readonly TimeSpan StartUpPatience = TimeSpan.FromSeconds(120);

    private static int Main(string[] args)
    {
        if (args.Length != 3)
        {
            Console.Error.WriteLine(
                "usage: RetouchStudio.UiTests <app.exe> <photo> <output.jpg>");
            return 2;
        }
        var app = Path.GetFullPath(args[0]);
        var photo = Path.GetFullPath(args[1]);
        var output = Path.GetFullPath(args[2]);
        if (!File.Exists(app))
        {
            Console.Error.WriteLine($"UI CHECK FAILED: {app} does not exist");
            return 1;
        }
        if (!File.Exists(photo))
        {
            Console.Error.WriteLine($"UI CHECK FAILED: {photo} does not exist");
            return 1;
        }
        if (File.Exists(output))
        {
            File.Delete(output);
        }
        var recovery = Directory.CreateTempSubdirectory("retouchstudio-ui-recovery-");

        var start = new ProcessStartInfo(app)
        {
            UseShellExecute = false,
            WorkingDirectory = Path.GetDirectoryName(app)!,
        };
        // An unexpected error prints and exits instead of hiding behind a
        // modal dialog the automation client would never see through.
        start.Environment["RETOUCHSTUDIO_NO_DIALOG"] = "1";
        start.Environment["RETOUCHSTUDIO_RECOVERY"] = recovery.FullName;

        using var process = Process.Start(start)
            ?? throw new InvalidOperationException("the app did not start");
        try
        {
            Run(process, photo, output);
            return 0;
        }
        catch (Exception error)
        {
            Console.Error.WriteLine($"UI CHECK FAILED: {error.Message}");
            Dump(process);
            return 1;
        }
        finally
        {
            try
            {
                if (!process.HasExited)
                {
                    process.Kill(entireProcessTree: true);
                }
            }
            catch (InvalidOperationException)
            {
            }
            try
            {
                Directory.Delete(recovery.FullName, recursive: true);
            }
            catch (IOException)
            {
            }
        }
    }

    private static void Run(Process process, string photo, string output)
    {
        var window = WaitWindow(process.Id, "Retouch Studio", StartUpPatience)
            ?? throw new InvalidOperationException(
                "the app window never appeared for UI Automation");
        Ok("the app opened a window UIA can see");

        var open = FindButton(window, "Open Photo")
            ?? throw new InvalidOperationException("the Open Photo button is missing");
        Invoke(open);
        var openDialog = WaitWindow(process.Id, "Open Photo", TimeSpan.FromSeconds(30))
            ?? throw new InvalidOperationException("the Open dialog never appeared");
        Ok("Open Photo opened its dialog");

        SetFileName(openDialog, photo);
        PressDefaultButton(openDialog, "Open");
        var photoName = Path.GetFileName(photo);
        var opened = WaitFor(
            () => window.Current.Name.Contains(photoName, StringComparison.Ordinal),
            TimeSpan.FromSeconds(90));
        if (!opened)
        {
            throw new InvalidOperationException(
                $"the photo did not open; the title is '{window.Current.Name}'");
        }
        Ok($"the photo opened: '{window.Current.Name}'");

        var slider = FindSlider(window, "Exposure")
            ?? throw new InvalidOperationException("the Exposure slider is missing");
        SetRange(slider, 40);
        var moved = WaitFor(
            () => slider.TryGetCurrentPattern(RangeValuePattern.Pattern, out var pattern)
                  && pattern is RangeValuePattern range
                  && Math.Abs(range.Current.Value - 40) < 0.5,
            TimeSpan.FromSeconds(10));
        if (!moved)
        {
            throw new InvalidOperationException("the Exposure slider did not take the value");
        }
        Ok("the Exposure slider moved through UIA");

        var export = FindButton(window, "Export")
            ?? throw new InvalidOperationException("the Export button is missing");
        Invoke(export);
        var saveDialog = WaitWindow(process.Id, "Export Photo", TimeSpan.FromSeconds(30))
            ?? throw new InvalidOperationException("the Export dialog never appeared");
        Ok("Export opened its dialog");

        SetFileName(saveDialog, output);
        PressDefaultButton(saveDialog, "Save");
        var wrote = WaitFor(
            () => File.Exists(output) && new FileInfo(output).Length > 1024,
            TimeSpan.FromMinutes(2));
        if (!wrote)
        {
            throw new InvalidOperationException("the export never wrote a file");
        }
        Ok($"the export wrote {new FileInfo(output).Length} bytes");

        var codec = new WindowsImageCodec();
        var source = codec.ReadSizeAsync(photo).GetAwaiter().GetResult();
        var written = codec.ReadSizeAsync(output).GetAwaiter().GetResult();
        if (written.Width != source.Width || written.Height != source.Height)
        {
            throw new InvalidOperationException(
                $"the export is {written.Width}x{written.Height}, the photo is " +
                $"{source.Width}x{source.Height}");
        }
        Ok($"the exported file decodes at the photo's {written.Width}x{written.Height}");

        // The slider edit is still unsaved; undo it so Closing has nothing to
        // ask about, then close like a person would.
        var undo = FindButton(window, "Undo");
        if (undo is not null)
        {
            Invoke(undo);
        }
        var close = (WindowPattern)window.GetCurrentPattern(WindowPattern.Pattern);
        close.Close();
        if (!process.WaitForExit(30_000))
        {
            DismissClosePrompt(process.Id);
            if (!process.WaitForExit(15_000))
            {
                throw new InvalidOperationException("the app did not close");
            }
        }
        if (process.ExitCode != 0)
        {
            throw new InvalidOperationException(
                $"the app exited with {process.ExitCode}");
        }
        Ok("the app closed cleanly");
        Console.WriteLine("UI HOST TESTS: PASS");
    }

    /// <summary>
    /// A still-dirty document asks "Close anyway?"; the answer drops the edits,
    /// which is what a person choosing to close would accept here.
    /// </summary>
    private static void DismissClosePrompt(int processId)
    {
        var deadline = DateTime.UtcNow + TimeSpan.FromSeconds(15);
        while (DateTime.UtcNow < deadline)
        {
            try
            {
                var windows = AutomationElement.RootElement.FindAll(
                    TreeScope.Children,
                    new PropertyCondition(AutomationElement.ProcessIdProperty, processId));
                foreach (AutomationElement window in windows)
                {
                    var yes = FindButton(window, "Yes", contains: true);
                    if (yes is not null)
                    {
                        Invoke(yes);
                        return;
                    }
                }
            }
            catch (ElementNotAvailableException)
            {
            }
            Thread.Sleep(250);
        }
    }

    private static AutomationElement? WaitWindow(int processId, string title,
                                                 TimeSpan patience)
    {
        var deadline = DateTime.UtcNow + patience;
        while (DateTime.UtcNow < deadline)
        {
            try
            {
                var windows = AutomationElement.RootElement.FindAll(
                    TreeScope.Children,
                    new AndCondition(
                        new PropertyCondition(AutomationElement.ProcessIdProperty, processId),
                        new PropertyCondition(AutomationElement.ControlTypeProperty,
                                              ControlType.Window)));
                foreach (AutomationElement candidate in windows)
                {
                    if (candidate.Current.Name == title)
                    {
                        return candidate;
                    }
                }
            }
            catch (ElementNotAvailableException)
            {
            }
            Thread.Sleep(250);
        }
        return null;
    }

    private static bool WaitFor(Func<bool> probe, TimeSpan patience)
    {
        var deadline = DateTime.UtcNow + patience;
        while (DateTime.UtcNow < deadline)
        {
            try
            {
                if (probe())
                {
                    return true;
                }
            }
            catch (ElementNotAvailableException)
            {
            }
            Thread.Sleep(250);
        }
        return false;
    }

    private static AutomationElement? FindButton(AutomationElement scope, string name,
                                                 bool contains = false)
    {
        foreach (AutomationElement candidate in scope.FindAll(
                     TreeScope.Descendants,
                     new PropertyCondition(AutomationElement.ControlTypeProperty,
                                           ControlType.Button)))
        {
            var text = candidate.Current.Name.Replace("&", "");
            if (text == name || (contains && text.Contains(name, StringComparison.Ordinal)))
            {
                return candidate;
            }
        }
        return null;
    }

    private static AutomationElement? FindSlider(AutomationElement scope, string name)
    {
        foreach (AutomationElement candidate in scope.FindAll(
                     TreeScope.Descendants,
                     new PropertyCondition(AutomationElement.ControlTypeProperty,
                                           ControlType.Slider)))
        {
            if (candidate.Current.Name == name)
            {
                return candidate;
            }
        }
        return null;
    }

    private static void Invoke(AutomationElement element)
    {
        ((InvokePattern)element.GetCurrentPattern(InvokePattern.Pattern)).Invoke();
    }

    private static void SetRange(AutomationElement element, double value)
    {
        ((RangeValuePattern)element.GetCurrentPattern(RangeValuePattern.Pattern))
            .SetValue(value);
    }

    /// <summary>
    /// Types an absolute path into the file-name box. The box is the edit the
    /// standard dialog marks as 1148; any edit is the fallback for a dialog
    /// that does not carry that id.
    /// </summary>
    private static void SetFileName(AutomationElement dialog, string path)
    {
        var edit = dialog.FindFirst(
            TreeScope.Descendants,
            new AndCondition(
                new PropertyCondition(AutomationElement.ControlTypeProperty,
                                      ControlType.Edit),
                new PropertyCondition(AutomationElement.AutomationIdProperty, "1148")));
        if (edit is null)
        {
            edit = dialog.FindFirst(
                TreeScope.Descendants,
                new PropertyCondition(AutomationElement.ControlTypeProperty,
                                      ControlType.Edit));
        }
        if (edit is null)
        {
            throw new InvalidOperationException("the dialog has no file-name box");
        }
        ((ValuePattern)edit.GetCurrentPattern(ValuePattern.Pattern)).SetValue(path);
    }

    /// <summary>
    /// The default button of the standard dialog is button 1; the name is the
    /// fallback, with the accelerator ampersand removed.
    /// </summary>
    private static void PressDefaultButton(AutomationElement dialog, string name)
    {
        var button = dialog.FindFirst(
            TreeScope.Descendants,
            new AndCondition(
                new PropertyCondition(AutomationElement.ControlTypeProperty,
                                      ControlType.Button),
                new PropertyCondition(AutomationElement.AutomationIdProperty, "1")));
        button ??= FindButton(dialog, name);
        if (button is null)
        {
            throw new InvalidOperationException(
                $"the dialog has no '{name}' button");
        }
        Invoke(button);
    }

    private static void Dump(Process process)
    {
        try
        {
            Console.Error.WriteLine("  windows:");
            foreach (AutomationElement window in AutomationElement.RootElement.FindAll(
                         TreeScope.Children,
                         new PropertyCondition(AutomationElement.ControlTypeProperty,
                                               ControlType.Window)))
            {
                Console.Error.WriteLine(
                    $"    pid {window.Current.ProcessId}: '{window.Current.Name}'");
            }
            var own = AutomationElement.RootElement.FindFirst(
                TreeScope.Children,
                new PropertyCondition(AutomationElement.ProcessIdProperty, process.Id));
            if (own is null)
            {
                return;
            }
            Console.Error.WriteLine("  buttons:");
            foreach (AutomationElement button in own.FindAll(
                         TreeScope.Descendants,
                         new PropertyCondition(AutomationElement.ControlTypeProperty,
                                               ControlType.Button)))
            {
                Console.Error.WriteLine($"    '{button.Current.Name}' " +
                                        $"[{button.Current.AutomationId}] " +
                                        $"enabled={button.Current.IsEnabled}");
            }
        }
        catch (Exception error)
        {
            Console.Error.WriteLine($"  the dump failed: {error.Message}");
        }
    }

    private static void Ok(string message) => Console.WriteLine($"  ok {message}");
}
