using System.Diagnostics;
using System.Globalization;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;
using System.Text.Json.Nodes;
using System.Text.RegularExpressions;
using System.Threading;
using System.Windows;
using System.Windows.Automation;
using RetouchStudio.Core.Project;
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
///       [golden|recovery|guard|project|batch|crop|compare|errors]
///
/// The app runs with an isolated recovery folder, so a leftover copy on the
/// machine cannot put a prompt in front of the window under test. The recovery
/// scenario is the exception: it seeds one copy there on purpose and answers
/// the prompt the host shows for it.
/// </summary>
internal static class Program
{
    private static readonly TimeSpan StartUpPatience = TimeSpan.FromSeconds(120);

    private static int Main(string[] args)
    {
        if (args.Length is < 3 or > 4)
        {
            Console.Error.WriteLine(
                "usage: RetouchStudio.UiTests <app.exe> <photo> <output.jpg> " +
                "[golden|recovery|guard|project|batch|crop|compare|errors]");
            return 2;
        }
        var mode = args.Length == 4 ? args[3] : "golden";
        if (mode is not ("golden" or "recovery" or "guard" or "project" or "batch"
                        or "crop" or "compare" or "errors"))
        {
            Console.Error.WriteLine($"UI CHECK FAILED: unknown mode '{mode}'");
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
        if (mode == "recovery")
        {
            SeedRecovery(recovery.FullName, photo);
        }

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
            if (mode == "recovery")
            {
                RunRecovery(process, photo);
            }
            else if (mode == "guard")
            {
                RunGuard(process, photo, output);
            }
            else if (mode == "project")
            {
                RunProject(process, app, photo, output, recovery.FullName);
            }
            else if (mode == "batch")
            {
                RunBatch(process, photo, output);
            }
            else if (mode == "crop")
            {
                RunCrop(process, photo, output);
            }
            else if (mode == "compare")
            {
                RunCompare(process, photo);
            }
            else if (mode == "errors")
            {
                RunErrors(process, photo, output);
            }
            else
            {
                Run(process, photo, output);
            }
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

    /// <summary>
    /// Leaves one unsaved document in the recovery folder, as a crash would.
    /// The photo's identity is recorded, so the host offers the copy instead of
    /// quarantining it as foreign.
    /// </summary>
    private static void SeedRecovery(string directory, string photo)
    {
        var document = new JsonObject
        {
            ["version"] = 4,
            ["imagePath"] = photo,
            ["exportFormat"] = "jpeg",
            ["exportQuality"] = 0.92,
            ["adjustments"] = new JsonObject { ["exposure"] = 60 },
        };
        var project = Encoding.UTF8.GetBytes(document.ToJsonString());
        var snapshot = RecoverySnapshot.Capture(
            project, Encoding.UTF8.GetBytes("""{"version":4}"""), photo,
            DateTimeOffset.UtcNow);
        if (!new RecoveryStore(directory).WriteWorking(snapshot, out _))
        {
            throw new InvalidOperationException(
                "the seeded recovery copy was not written");
        }
    }

    /// <summary>
    /// The host offers the unsaved copy on launch. Restoring it must open the
    /// photo with the stored slider value; a headless test can reach the store
    /// but not the message box or the restore the person sees.
    /// </summary>
    private static void RunRecovery(Process process, string photo)
    {
        var window = WaitWindow(process.Id, "Retouch Studio", StartUpPatience)
            ?? throw new InvalidOperationException("the main window never appeared");
        var prompt = WaitWindow(process.Id, "Recover unsaved changes", StartUpPatience)
            ?? throw new InvalidOperationException("the recovery prompt never appeared");
        Ok("the seeded unsaved copy raised the recovery prompt");
        var yes = FindButton(prompt, "Yes")
            ?? throw new InvalidOperationException("the recovery prompt has no Yes button");
        Invoke(yes);

        // The window was found before the prompt was answered, so the title
        // wait cannot miss a restore that finishes faster than one poll.
        var photoName = Path.GetFileName(photo);
        var opened = WaitFor(
            () => window.Current.Name.Contains(photoName, StringComparison.Ordinal),
            TimeSpan.FromSeconds(90));
        if (!opened)
        {
            throw new InvalidOperationException(
                $"the recovery did not open the photo; the title is '{window.Current.Name}'");
        }
        Ok($"the recovered document opened: '{window.Current.Name}'");

        var slider = FindSlider(window, "Exposure")
            ?? throw new InvalidOperationException("the Exposure slider is missing");
        var restored = WaitFor(
            () => slider.TryGetCurrentPattern(RangeValuePattern.Pattern, out var pattern)
                  && pattern is RangeValuePattern range
                  && Math.Abs(range.Current.Value - 60) < 0.5,
            TimeSpan.FromSeconds(10));
        if (!restored)
        {
            throw new InvalidOperationException("the restored Exposure value is not 60");
        }
        Ok("the restored document kept the unsaved Exposure value");

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
            throw new InvalidOperationException($"the app exited with {process.ExitCode}");
        }
        Ok("the app closed cleanly after a recovery");
        Console.WriteLine("UI HOST TESTS: PASS");
    }

    /// <summary>
    /// Opens a project whose edits this host cannot render and proves Export
    /// names them before writing anything. "No" must leave the photo unwritten
    /// and the document open, which is the whole point of the guard.
    /// </summary>
    private static void RunGuard(Process process, string photo, string output)
    {
        var window = WaitWindow(process.Id, "Retouch Studio", StartUpPatience)
            ?? throw new InvalidOperationException("the main window never appeared");
        var mainHandle = (IntPtr)window.Current.NativeWindowHandle;

        var project = Path.ChangeExtension(output, ".retouch");
        // The project is written by the same codec the app opens, so the
        // seeded file cannot differ from a project the host itself saved.
        using (var session = ProjectSession.Create(photo))
        {
            session.Document.SetAdjustment("smooth", 30);
            session.Commit();
            session.Save(project);
        }
        Ok("seeded a project carrying skin retouching");

        var open = FindButton(window, "Open Project")
            ?? throw new InvalidOperationException("the Open Project button is missing");
        Invoke(open);
        var dialogHandle = WaitNewWindow(process.Id, mainHandle, TimeSpan.FromSeconds(30))
            ?? throw new InvalidOperationException("the Open Project click opened no window");
        var openDialog = AutomationElement.FromHandle(dialogHandle);
        var openEdit = SetFileName(openDialog, project);
        if (!WaitFor(() => ReadValue(openEdit) == project, TimeSpan.FromSeconds(10)))
        {
            throw new InvalidOperationException(
                $"the file-name box holds '{ReadValue(openEdit)}' instead of '{project}'");
        }
        CommitFileName(openEdit);
        if (!WaitFor(() => !IsWindowVisible(dialogHandle), TimeSpan.FromSeconds(30)))
        {
            PressDefaultButton(openDialog, "Open");
            if (!WaitFor(() => !IsWindowVisible(dialogHandle), TimeSpan.FromSeconds(30)))
            {
                throw new InvalidOperationException(
                    "the Open Project dialog stayed open; " + DescribeWindow(openDialog));
            }
        }
        var photoName = Path.GetFileName(photo);
        if (!WaitFor(() => window.Current.Name.Contains(photoName, StringComparison.Ordinal),
                     TimeSpan.FromSeconds(90)))
        {
            throw new InvalidOperationException(
                $"the project did not open; the title is '{window.Current.Name}'; " +
                $"the windows are {DescribeAppWindows(process.Id)}; the texts are " +
                DescribeTexts(window));
        }
        Ok($"the project opened with its photo: '{window.Current.Name}'");

        var export = FindButton(window, "Export")
            ?? throw new InvalidOperationException("the Export button is missing");
        Invoke(export);
        var promptHandle = WaitNewWindow(process.Id, mainHandle, TimeSpan.FromSeconds(30))
            ?? throw new InvalidOperationException("the Export click opened no window");
        var prompt = AutomationElement.FromHandle(promptHandle);
        var texts = AllTexts(prompt);
        if (!texts.Contains("cannot render", StringComparison.Ordinal)
            || !texts.Contains("skin retouching", StringComparison.Ordinal))
        {
            throw new InvalidOperationException(
                $"the Export click did not raise the unsupported-edit prompt; " +
                $"'{prompt.Current.Name}' says '{texts}'");
        }
        Ok("Export named the skin retouching this host cannot render");

        var no = FindButton(prompt, "No")
            ?? throw new InvalidOperationException("the prompt has no No button");
        Invoke(no);
        if (!WaitFor(() => !IsWindowVisible(promptHandle), TimeSpan.FromSeconds(15)))
        {
            throw new InvalidOperationException("the unsupported-edit prompt stayed open after No");
        }
        Thread.Sleep(1500);
        if (File.Exists(output))
        {
            throw new InvalidOperationException("the export wrote a file after No");
        }
        Ok("No dismissed the prompt and wrote nothing");

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
            throw new InvalidOperationException($"the app exited with {process.ExitCode}");
        }
        Ok("the app closed cleanly after the guard prompt");
        Console.WriteLine("UI HOST TESTS: PASS");
    }

    /// <summary>
    /// Both failure paths end in a message box a person can read: a corrupt
    /// photo must be named as unopenable, and a destination another program
    /// holds open must fail the export without touching that file. The app
    /// must stay open and usable after each one.
    /// </summary>
    private static void RunErrors(Process process, string photo, string output)
    {
        var window = WaitWindow(process.Id, "Retouch Studio", StartUpPatience)
            ?? throw new InvalidOperationException("the main window never appeared");
        var mainHandle = (IntPtr)window.Current.NativeWindowHandle;
        Ok("the app opened a window UIA can see");

        var broken = Path.ChangeExtension(output, ".broken" + Path.GetExtension(photo));
        File.WriteAllText(broken, "this is not a photo");
        var open = FindButton(window, "Open Photo")
            ?? throw new InvalidOperationException("the Open Photo button is missing");
        Invoke(open);
        var openDialogHandle = WaitNewWindow(process.Id, mainHandle, TimeSpan.FromSeconds(90))
            ?? throw new InvalidOperationException("the Open dialog never appeared");
        var openDialog = AutomationElement.FromHandle(openDialogHandle);
        SetFileName(openDialog, broken);
        PressDefaultButton(openDialog, "Open");

        var openError = DismissMessageBox(process.Id, mainHandle, TimeSpan.FromSeconds(60));
        if (openError is null || !openError.Contains("could not be opened", StringComparison.Ordinal))
        {
            throw new InvalidOperationException(
                $"opening a corrupt photo said {openError ?? "nothing"}; the app's windows are " +
                DescribeAppWindows(process.Id));
        }
        Ok($"a corrupt photo is reported: {openError}");
        if (process.HasExited || !window.Current.Name.StartsWith("Retouch Studio", StringComparison.Ordinal))
        {
            throw new InvalidOperationException(
                $"the app did not survive the failed open; the title is " +
                $"'{window.Current.Name}'");
        }

        OpenPhoto(window, process, photo);

        // A file another program holds with no sharing cannot be written. The
        // Save dialog still offers to replace it, which is the moment the write
        // is attempted and fails.
        var locked = Path.ChangeExtension(output, ".locked.jpg");
        var placeholder = new byte[1024];
        File.WriteAllBytes(locked, placeholder);
        using var hold = new FileStream(locked, FileMode.Open, FileAccess.ReadWrite,
                                        FileShare.None);
        var export = FindButton(window, "Export")
            ?? throw new InvalidOperationException("the Export button is missing");
        Invoke(export);
        var saveHandle = WaitNewWindow(process.Id, mainHandle, TimeSpan.FromSeconds(30))
            ?? throw new InvalidOperationException("the Export click opened no window");
        var saveDialog = AutomationElement.FromHandle(saveHandle);
        var saveEdit = SetFileName(saveDialog, locked);
        CommitFileName(saveEdit);
        if (!WaitFor(() => !IsWindowVisible(saveHandle), TimeSpan.FromSeconds(20)))
        {
            var replace = WaitForButton(process.Id, "Yes", TimeSpan.FromSeconds(20));
            if (replace is null)
            {
                throw new InvalidOperationException(
                    "the Export dialog never offered to replace the locked file; " +
                    DescribeWindow(saveDialog));
            }
            Invoke(replace);
            if (!WaitFor(() => !IsWindowVisible(saveHandle), TimeSpan.FromSeconds(30)))
            {
                throw new InvalidOperationException(
                    "the Export dialog stayed open after replacing; " +
                    DescribeWindow(saveDialog));
            }
        }

        var exportError = DismissMessageBox(process.Id, mainHandle, TimeSpan.FromSeconds(60));
        if (exportError is null
            || !exportError.Contains("could not be exported", StringComparison.Ordinal))
        {
            throw new InvalidOperationException(
                $"exporting onto a locked file said {exportError ?? "nothing"}; " +
                "the app's windows are " + DescribeAppWindows(process.Id));
        }
        Ok($"a locked destination is reported: {exportError}");
        if (new FileInfo(locked).Length != placeholder.Length)
        {
            throw new InvalidOperationException(
                "the failed export changed the locked file");
        }
        Ok("the failed export left the locked file untouched");

        CloseCleanly(window, process);
        Console.WriteLine("UI HOST TESTS: PASS");
    }

    /// <summary>
    /// Waits for the next message box, reads the text it shows, and answers OK.
    /// Returns null when no box appears inside the patience.
    /// </summary>
    private static string? DismissMessageBox(int processId, IntPtr mainHandle,
                                             TimeSpan patience)
    {
        var deadline = DateTime.UtcNow + patience;
        while (DateTime.UtcNow < deadline)
        {
            foreach (var handle in VisibleWindows(processId))
            {
                if (handle == mainHandle)
                {
                    continue;
                }
                try
                {
                    var box = AutomationElement.FromHandle(handle);
                    var ok = FindButton(box, "OK");
                    if (ok is null)
                    {
                        continue;
                    }
                    var text = DescribeWindow(box);
                    Invoke(ok);
                    return text;
                }
                catch (ElementNotAvailableException)
                {
                }
            }
            Thread.Sleep(250);
        }
        return null;
    }

    /// <summary>A button by name in any of the process's visible windows.</summary>
    private static AutomationElement? WaitForButton(int processId, string name, TimeSpan patience)
    {
        var deadline = DateTime.UtcNow + patience;
        while (DateTime.UtcNow < deadline)
        {
            foreach (var handle in VisibleWindows(processId))
            {
                try
                {
                    var button = FindButton(AutomationElement.FromHandle(handle), name);
                    if (button is not null)
                    {
                        return button;
                    }
                }
                catch (ElementNotAvailableException)
                {
                }
            }
            Thread.Sleep(250);
        }
        return null;
    }

    /// <summary>
    /// Saves the edited photo as a project through its dialog, then proves the
    /// Undo button reaches the same history the headless checks measure.
    /// </summary>
    private static void RunProject(Process process, string app, string photo,
                                   string output, string recoveryDirectory)
    {
        var window = WaitWindow(process.Id, "Retouch Studio", StartUpPatience)
            ?? throw new InvalidOperationException("the main window never appeared");
        var mainHandle = (IntPtr)window.Current.NativeWindowHandle;

        var open = FindButton(window, "Open Photo")
            ?? throw new InvalidOperationException("the Open Photo button is missing");
        Invoke(open);
        var openDialog = WaitWindow(process.Id, "Open Photo", TimeSpan.FromSeconds(90))
            ?? throw new InvalidOperationException("the Open dialog never appeared");
        SetFileName(openDialog, photo);
        PressDefaultButton(openDialog, "Open");
        var photoName = Path.GetFileName(photo);
        if (!WaitFor(() => window.Current.Name.Contains(photoName, StringComparison.Ordinal),
                     TimeSpan.FromSeconds(90)))
        {
            throw new InvalidOperationException(
                $"the photo did not open; the title is '{window.Current.Name}'");
        }
        Ok($"the photo opened: '{window.Current.Name}'");

        var slider = FindSlider(window, "Exposure")
            ?? throw new InvalidOperationException("the Exposure slider is missing");
        SetRange(slider, 40);
        if (!WaitFor(() => Math.Abs(SliderValue(slider) - 40) < 0.5, TimeSpan.FromSeconds(10)))
        {
            throw new InvalidOperationException("the Exposure slider did not reach 40");
        }

        var save = FindButton(window, "Save Project")
            ?? throw new InvalidOperationException("the Save Project button is missing");
        Invoke(save);
        var dialogHandle = WaitNewWindow(process.Id, mainHandle, TimeSpan.FromSeconds(30))
            ?? throw new InvalidOperationException("the Save Project click opened no window");
        var saveDialog = AutomationElement.FromHandle(dialogHandle);
        var project = Path.ChangeExtension(output, ".retouch");
        var edit = SetFileName(saveDialog, project);
        if (!WaitFor(() => ReadValue(edit) == project, TimeSpan.FromSeconds(10)))
        {
            throw new InvalidOperationException(
                $"the file-name box holds '{ReadValue(edit)}' instead of '{project}'");
        }
        CommitFileName(edit);
        if (!WaitFor(() => !IsWindowVisible(dialogHandle), TimeSpan.FromSeconds(30)))
        {
            PressDefaultButton(saveDialog, "Save", "Open");
            if (!WaitFor(() => !IsWindowVisible(dialogHandle), TimeSpan.FromSeconds(30)))
            {
                throw new InvalidOperationException(
                    "the Save Project dialog stayed open; " + DescribeWindow(saveDialog));
            }
        }
        if (!WaitFor(() => File.Exists(project) && new FileInfo(project).Length > 0,
                     TimeSpan.FromSeconds(60)))
        {
            throw new InvalidOperationException(
                "Save Project wrote no file; the status says " + DescribeTexts(window));
        }
        Ok($"Save Project wrote {new FileInfo(project).Length} bytes through its dialog");

        if (!WaitFor(() => !window.Current.Name.Contains('•'), TimeSpan.FromSeconds(10)))
        {
            throw new InvalidOperationException(
                $"the title still shows unsaved changes: '{window.Current.Name}'");
        }
        Ok("the saved title shows no unsaved marker");

        var undo = FindButton(window, "Undo")
            ?? throw new InvalidOperationException("the Undo button is missing");
        Invoke(undo);
        if (!WaitFor(() => Math.Abs(SliderValue(slider)) < 0.5, TimeSpan.FromSeconds(10)))
        {
            throw new InvalidOperationException(
                $"Undo left Exposure at {SliderValue(slider)}");
        }
        Ok("Undo returned Exposure to 0 through the UI");

        var redo = FindButton(window, "Redo")
            ?? throw new InvalidOperationException("the Redo button is missing");
        Invoke(redo);
        if (!WaitFor(() => Math.Abs(SliderValue(slider) - 40) < 0.5, TimeSpan.FromSeconds(10)))
        {
            throw new InvalidOperationException(
                $"Redo left Exposure at {SliderValue(slider)}");
        }
        Ok("Redo reapplied Exposure 40 through the UI");

        // The project path is known now, so this save writes without a dialog.
        Invoke(save);
        if (!WaitFor(() => !window.Current.Name.Contains('•'), TimeSpan.FromSeconds(10)))
        {
            throw new InvalidOperationException(
                $"the second save left unsaved changes: '{window.Current.Name}'");
        }
        Ok("the second Save Project wrote through the existing path");

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
            throw new InvalidOperationException($"the app exited with {process.ExitCode}");
        }
        Ok("the app closed cleanly after the project checks");

        // A fresh process must reopen the saved file with its edit intact.
        var start = new ProcessStartInfo(app)
        {
            UseShellExecute = false,
            WorkingDirectory = Path.GetDirectoryName(app)!,
        };
        start.Environment["RETOUCHSTUDIO_NO_DIALOG"] = "1";
        start.Environment["RETOUCHSTUDIO_RECOVERY"] = recoveryDirectory;
        using var reopened = Process.Start(start)
            ?? throw new InvalidOperationException("the app did not restart");
        var second = WaitWindow(reopened.Id, "Retouch Studio", StartUpPatience)
            ?? throw new InvalidOperationException("the second window never appeared");
        var secondHandle = (IntPtr)second.Current.NativeWindowHandle;

        var openProject = FindButton(second, "Open Project")
            ?? throw new InvalidOperationException("the Open Project button is missing");
        Invoke(openProject);
        var reopenHandle = WaitNewWindow(reopened.Id, secondHandle, TimeSpan.FromSeconds(30))
            ?? throw new InvalidOperationException("the Open Project click opened no window");
        var reopenDialog = AutomationElement.FromHandle(reopenHandle);
        var reopenEdit = SetFileName(reopenDialog, project);
        if (!WaitFor(() => ReadValue(reopenEdit) == project, TimeSpan.FromSeconds(10)))
        {
            throw new InvalidOperationException(
                $"the file-name box holds '{ReadValue(reopenEdit)}' instead of '{project}'");
        }
        CommitFileName(reopenEdit);
        if (!WaitFor(() => !IsWindowVisible(reopenHandle), TimeSpan.FromSeconds(30)))
        {
            PressDefaultButton(reopenDialog, "Open");
            if (!WaitFor(() => !IsWindowVisible(reopenHandle), TimeSpan.FromSeconds(30)))
            {
                throw new InvalidOperationException(
                    "the Open Project dialog stayed open; " + DescribeWindow(reopenDialog));
            }
        }
        if (!WaitFor(() => second.Current.Name.Contains(photoName, StringComparison.Ordinal),
                     TimeSpan.FromSeconds(90)))
        {
            throw new InvalidOperationException(
                $"the saved project did not reopen; the title is '{second.Current.Name}'; " +
                $"the windows are {DescribeAppWindows(reopened.Id)}");
        }
        Ok($"the saved project reopened: '{second.Current.Name}'");

        var reopenedSlider = FindSlider(second, "Exposure")
            ?? throw new InvalidOperationException("the Exposure slider is missing after reopening");
        if (!WaitFor(() => Math.Abs(SliderValue(reopenedSlider) - 40) < 0.5,
                     TimeSpan.FromSeconds(10)))
        {
            throw new InvalidOperationException(
                $"the reopened Exposure is {SliderValue(reopenedSlider)}, not 40");
        }
        Ok("the reopened project kept Exposure at 40");

        var closeAgain = (WindowPattern)second.GetCurrentPattern(WindowPattern.Pattern);
        closeAgain.Close();
        if (!reopened.WaitForExit(30_000))
        {
            DismissClosePrompt(reopened.Id);
            if (!reopened.WaitForExit(15_000))
            {
                throw new InvalidOperationException("the restarted app did not close");
            }
        }
        if (reopened.ExitCode != 0)
        {
            throw new InvalidOperationException(
                $"the restarted app exited with {reopened.ExitCode}");
        }
        Ok("the restarted app closed cleanly");
        Console.WriteLine("UI HOST TESTS: PASS");
    }

    /// <summary>
    /// Runs a batch of one photo from the UI: the photo picker, the folder
    /// picker, and the written file decoded back. The selection is one photo
    /// because a multi-select tick is a pointer gesture UIA does not model.
    /// </summary>
    private static void RunBatch(Process process, string photo, string output)
    {
        var window = WaitWindow(process.Id, "Retouch Studio", StartUpPatience)
            ?? throw new InvalidOperationException("the main window never appeared");
        var mainHandle = (IntPtr)window.Current.NativeWindowHandle;

        var open = FindButton(window, "Open Photo")
            ?? throw new InvalidOperationException("the Open Photo button is missing");
        Invoke(open);
        var openDialog = WaitWindow(process.Id, "Open Photo", TimeSpan.FromSeconds(90))
            ?? throw new InvalidOperationException("the Open dialog never appeared");
        SetFileName(openDialog, photo);
        PressDefaultButton(openDialog, "Open");
        var photoName = Path.GetFileName(photo);
        if (!WaitFor(() => window.Current.Name.Contains(photoName, StringComparison.Ordinal),
                     TimeSpan.FromSeconds(90)))
        {
            throw new InvalidOperationException(
                $"the photo did not open; the title is '{window.Current.Name}'");
        }

        var folder = Path.Combine(
            Path.GetDirectoryName(output)!, "retouchstudio-ui-batch");
        if (Directory.Exists(folder))
        {
            Directory.Delete(folder, recursive: true);
        }
        Directory.CreateDirectory(folder);

        var batch = FindButton(window, "Batch Export…")
            ?? throw new InvalidOperationException("the Batch Export button is missing");
        Invoke(batch);
        var photosHandle = WaitNewWindow(process.Id, mainHandle, TimeSpan.FromSeconds(30))
            ?? throw new InvalidOperationException("the Batch Export click opened no window");
        var photosDialog = AutomationElement.FromHandle(photosHandle);
        var photosEdit = SetFileName(photosDialog, photo);
        if (!WaitFor(() => ReadValue(photosEdit) == photo, TimeSpan.FromSeconds(10)))
        {
            throw new InvalidOperationException(
                $"the photo box holds '{ReadValue(photosEdit)}' instead of '{photo}'");
        }
        CommitFileName(photosEdit);
        if (!WaitFor(() => !IsWindowVisible(photosHandle), TimeSpan.FromSeconds(30)))
        {
            PressDefaultButton(photosDialog, "Open");
            if (!WaitFor(() => !IsWindowVisible(photosHandle), TimeSpan.FromSeconds(30)))
            {
                throw new InvalidOperationException(
                    "the photo picker stayed open; " + DescribeWindow(photosDialog));
            }
        }
        Ok("the batch photo picker took the photo");

        var folderHandle = WaitNewWindow(process.Id, mainHandle, TimeSpan.FromSeconds(30))
            ?? throw new InvalidOperationException("the folder picker never appeared");
        var folderDialog = AutomationElement.FromHandle(folderHandle);
        var folderEdit = FindFolderEdit(folderDialog);
        if (folderEdit is null || !TypeInto(folderEdit, folder))
        {
            throw new InvalidOperationException(
                "the folder picker has no Folder box: " + DescribeEditors(folderDialog));
        }
        if (!WaitFor(() => ReadValue(folderEdit) == folder, TimeSpan.FromSeconds(10)))
        {
            throw new InvalidOperationException(
                $"the Folder box holds '{ReadValue(folderEdit)}' instead of '{folder}'");
        }
        CommitFileName(folderEdit);
        if (!WaitFor(() => !IsWindowVisible(folderHandle), TimeSpan.FromSeconds(30)))
        {
            var select = FindButton(folderDialog, "Select Folder")
                ?? throw new InvalidOperationException(
                    "the folder picker has no Select Folder button: " +
                    DescribeWindow(folderDialog));
            Invoke(select);
            if (!WaitFor(() => !IsWindowVisible(folderHandle), TimeSpan.FromSeconds(30)))
            {
                throw new InvalidOperationException(
                    "the folder picker stayed open; " + DescribeWindow(folderDialog));
            }
        }
        Ok($"the folder picker took '{folder}'");

        var written = Path.Combine(
            folder, Path.GetFileNameWithoutExtension(photo) + "-retouched.jpg");
        if (!WaitFor(() => File.Exists(written) && new FileInfo(written).Length > 1024,
                     TimeSpan.FromMinutes(2)))
        {
            throw new InvalidOperationException(
                "the batch wrote no file; the status says " + DescribeTexts(window) +
                "; the folder holds " + RecentFiles(folder));
        }
        var codec = new WindowsImageCodec();
        var source = codec.ReadSizeAsync(photo).GetAwaiter().GetResult();
        var decoded = codec.ReadSizeAsync(written).GetAwaiter().GetResult();
        if (decoded.Width != source.Width || decoded.Height != source.Height)
        {
            throw new InvalidOperationException(
                $"the batch photo is {decoded.Width}x{decoded.Height}, the source is " +
                $"{source.Width}x{source.Height}");
        }
        Ok($"the batch wrote and decoded {new FileInfo(written).Length} bytes at " +
           $"{decoded.Width}x{decoded.Height}");

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
            throw new InvalidOperationException($"the app exited with {process.ExitCode}");
        }
        Ok("the app closed cleanly after the batch");
        Console.WriteLine("UI HOST TESTS: PASS");
    }

    private static void Run(Process process, string photo, string output)
    {
        var window = WaitWindow(process.Id, "Retouch Studio", StartUpPatience)
            ?? throw new InvalidOperationException(
                "the app window never appeared for UI Automation");
        var mainHandle = (IntPtr)window.Current.NativeWindowHandle;
        Ok("the app opened a window UIA can see");

        OpenPhoto(window, process, photo);

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

        // Every other global slider must be wired the same way; a missing one
        // here is a dead control, not a rendering difference.
        foreach (var (name, value) in new[]
                 {
                     ("Contrast", 12.0), ("Blacks", -8.0), ("Whites", 6.0),
                     ("Saturation", 14.0), ("Vibrance", 10.0), ("Warmth", -6.0),
                     ("Clarity", 18.0), ("Vignette", 20.0),
                 })
        {
            var control = FindSlider(window, name)
                ?? throw new InvalidOperationException($"the {name} slider is missing");
            SetRange(control, value);
            if (!WaitFor(() => Math.Abs(SliderValue(control) - value) < 0.5,
                         TimeSpan.FromSeconds(10)))
            {
                throw new InvalidOperationException(
                    $"the {name} slider holds {SliderValue(control)} instead of {value}");
            }
        }
        Ok("the other eight global sliders moved through UIA");

        // The zoom dock proves a second kind of wiring: a button whose effect
        // is a text readout, not a value the harness sets itself.
        var zoomIn = FindButton(window, "Zoom in")
            ?? throw new InvalidOperationException("the Zoom in button is missing");
        Invoke(zoomIn);
        var zoomed = WaitFor(() => FindText(window, "150%") is not null,
                             TimeSpan.FromSeconds(10));
        if (!zoomed)
        {
            throw new InvalidOperationException("the zoom readout never reached 150%");
        }
        Ok("the zoom control reached 150% through UIA");
        var fit = FindButton(window, "Fit to window")
            ?? throw new InvalidOperationException("the Fit button is missing");
        Invoke(fit);

        var photoSize = PhotoSize(photo);
        var written = ExportTo(window, process, mainHandle, output);
        if (written.Width != photoSize.Width || written.Height != photoSize.Height)
        {
            throw new InvalidOperationException(
                $"the export is {written.Width}x{written.Height}, the photo is " +
                $"{photoSize.Width}x{photoSize.Height}");
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
    /// The crop path proves a pointer gesture, which no UIA pattern can
    /// express: the bottom-right handle is dragged with injected mouse input,
    /// the size badge is read before and after, and the applied crop is
    /// exported. The written frame must equal the badge, so the drag reached
    /// the same crop maths the headless checks cover.
    /// </summary>
    private static void RunCrop(Process process, string photo, string output)
    {
        var window = WaitWindow(process.Id, "Retouch Studio", StartUpPatience)
            ?? throw new InvalidOperationException(
                "the app window never appeared for UI Automation");
        var mainHandle = (IntPtr)window.Current.NativeWindowHandle;
        Ok("the app opened a window UIA can see");
        OpenPhoto(window, process, photo);

        var custom = FindButton(window, "Custom…")
            ?? throw new InvalidOperationException("the Custom crop button is missing");
        Invoke(custom);
        var handles = WaitForHandles(window, "Crop corner handle", 4, TimeSpan.FromSeconds(15));
        if (handles is null)
        {
            throw new InvalidOperationException(
                "the crop overlay showed fewer than four handles; the texts are " +
                DescribeTexts(window));
        }
        Ok("the crop overlay opened with four corner handles");

        var before = CropBadgeSize(window)
            ?? throw new InvalidOperationException(
                $"the crop badge shows no size; the texts are {DescribeTexts(window)}");

        // The runner's virtual desktop can be smaller than the window. A handle
        // past the screen edge cannot be clicked — the injected pointer clamps
        // to the last pixel — so the window is moved fully onto the screen and
        // only a corner the screen shows is used.
        var windowRect = FitWindowToScreen(window);
        var rect = WaitForUsableCorner(window, windowRect, TimeSpan.FromSeconds(10))
            ?? throw new InvalidOperationException(
                "no crop corner handle can be reached by the pointer");
        // Pull the corner towards the photo's centre: right/bottom corners move
        // left and up, left/top corners move right and down.
        var dx = rect.X + rect.Width / 2 < windowRect.X + windowRect.Width / 2 ? 70 : -70;
        var dy = rect.Y + rect.Height / 2 < windowRect.Y + windowRect.Height / 2 ? 45 : -45;
        Console.WriteLine($"  dragging handle at {rect} by {dx},{dy}");

        var foreground = SetForegroundWindow(mainHandle);
        Thread.Sleep(300);
        Console.WriteLine($"  set foreground: {foreground}; " +
                          $"active window is the app: {GetForegroundWindow() == mainHandle}");
        var resized = DragHandle(window, rect, dx, dy, before);
        if (!resized)
        {
            // A first click can be what gives the window real input focus on an
            // unattended desktop; the drag is then repeated once.
            Console.WriteLine("  the first drag changed nothing; retrying after a focus click");
            SetForegroundWindow(mainHandle);
            Thread.Sleep(500);
            resized = DragHandle(window, rect, dx, dy, before);
        }
        var after = CropBadgeSize(window);
        if (!resized || after is not { } cropped)
        {
            GetCursorPos(out var cursor);
            var under = WindowFromPoint(cursor);
            throw new InvalidOperationException(
                $"the drag left the badge at {before.Width}×{before.Height}; " +
                $"cursor {cursor.X},{cursor.Y}, window under it {under}, app {mainHandle}, " +
                $"active {GetForegroundWindow()}");
        }
        if (cropped.Width >= before.Width || cropped.Height >= before.Height)
        {
            throw new InvalidOperationException(
                $"the drag grew the crop from {before.Width}×{before.Height} to " +
                $"{cropped.Width}×{cropped.Height}");
        }
        Ok($"dragging the corner shrank the crop from {before.Width}×{before.Height} " +
           $"to {cropped.Width}×{cropped.Height}");

        var apply = FindButton(window, "Apply crop")
            ?? throw new InvalidOperationException("the Apply crop button is missing");
        Invoke(apply);
        if (!WaitFor(() => FindText(window, "Custom") is not null, TimeSpan.FromSeconds(10)))
        {
            throw new InvalidOperationException(
                "the crop label never named the drawn frame; the texts are " +
                DescribeTexts(window));
        }
        Ok("Apply crop committed the drawn frame");

        var written = ExportTo(window, process, mainHandle, output);
        if (written.Width != cropped.Width || written.Height != cropped.Height)
        {
            throw new InvalidOperationException(
                $"the export is {written.Width}x{written.Height}, the badge said " +
                $"{cropped.Width}×{cropped.Height}");
        }
        Ok($"the exported crop is the badge's {written.Width}x{written.Height}");

        var undo = FindButton(window, "Undo");
        if (undo is not null)
        {
            Invoke(undo);
        }
        CloseCleanly(window, process);
        Console.WriteLine("UI HOST TESTS: PASS");
    }

    /// <summary>
    /// The before/after split is another pointer-only control: its Thumb has no
    /// UIA pattern that moves it, so the divider is dragged with injected mouse
    /// input and the only observable evidence is the Thumb's own screen
    /// rectangle. The split starts at a fixed fraction and must come back when
    /// the drag is reversed.
    /// </summary>
    private static void RunCompare(Process process, string photo)
    {
        var window = WaitWindow(process.Id, "Retouch Studio", StartUpPatience)
            ?? throw new InvalidOperationException(
                "the app window never appeared for UI Automation");
        var mainHandle = (IntPtr)window.Current.NativeWindowHandle;
        Ok("the app opened a window UIA can see");
        OpenPhoto(window, process, photo);
        FitWindowToScreen(window);

        var compare = FindButton(window, "Compare before and after")
            ?? throw new InvalidOperationException("the Compare toggle is missing");
        bool IsOn() =>
            compare.TryGetCurrentPattern(TogglePattern.Pattern, out var pattern)
            && pattern is TogglePattern toggle
            && toggle.Current.ToggleState == ToggleState.On;
        ClickControl(compare, mainHandle);
        var turnedOn = WaitFor(IsOn, TimeSpan.FromSeconds(8));
        if (!turnedOn)
        {
            Console.WriteLine("  the first click left Compare off; clicking again");
            ClickControl(compare, mainHandle);
            turnedOn = WaitFor(IsOn, TimeSpan.FromSeconds(8));
        }
        if (!turnedOn)
        {
            throw new InvalidOperationException(
                $"the Compare toggle reads {ToggleStateText(compare)} after a click at " +
                $"{compare.Current.BoundingRectangle}");
        }
        Ok("Compare turned on through a real click");

        var handles = WaitForHandles(window, "Compare split", 1, TimeSpan.FromSeconds(15));
        if (handles is null || handles[0].Current.BoundingRectangle.IsEmpty)
        {
            throw new InvalidOperationException(
                $"the compare divider did not appear; the toggle reads {ToggleStateText(compare)}; " +
                $"the thumbs are {DescribeThumbs(window)}; the texts are " + DescribeTexts(window));
        }
        var thumb = handles[0];
        var start = thumb.Current.BoundingRectangle;
        Console.WriteLine($"  compare divider at {start}");

        var foreground = SetForegroundWindow(mainHandle);
        Thread.Sleep(300);
        Console.WriteLine($"  set foreground: {foreground}; " +
                          $"active window is the app: {GetForegroundWindow() == mainHandle}");
        Drag(start.X + start.Width / 2, start.Y + start.Height / 2, dx: 80, dy: 0, steps: 20);
        var movedRight = WaitFor(
            () => thumb.Current.BoundingRectangle.X >= start.X + 50,
            TimeSpan.FromSeconds(10));
        if (!movedRight)
        {
            throw new InvalidOperationException(
                $"the divider stayed at {thumb.Current.BoundingRectangle.X}, " +
                $"it started at {start.X}");
        }
        var shifted = thumb.Current.BoundingRectangle;
        Ok($"dragging the divider moved it {shifted.X - start.X:0}px right");

        Drag(shifted.X + shifted.Width / 2, shifted.Y + shifted.Height / 2,
             dx: -80, dy: 0, steps: 20);
        var returned = WaitFor(
            () => Math.Abs(thumb.Current.BoundingRectangle.X - start.X) <= 6,
            TimeSpan.FromSeconds(10));
        if (!returned)
        {
            throw new InvalidOperationException(
                $"the divider did not return: {thumb.Current.BoundingRectangle.X} " +
                $"against a start of {start.X}");
        }
        Ok("dragging it back returned the divider to its start");

        ClickControl(compare, mainHandle);
        var disappeared = WaitFor(() => HandleCount(window, "Compare split") == 0,
                                  TimeSpan.FromSeconds(10));
        if (!disappeared)
        {
            throw new InvalidOperationException(
                "the divider stayed after Compare was turned off");
        }
        Ok("turning Compare off removed the divider");

        CloseCleanly(window, process);
        Console.WriteLine("UI HOST TESTS: PASS");
    }

    private static void CloseCleanly(AutomationElement window, Process process)
    {
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
    }

    /// <summary>
    /// Clicks the middle of a control with injected pointer input. The WPF
    /// ToggleButton exposes no InvokePattern, and TogglePattern flips IsChecked
    /// without raising Click, which is where the app reads its state.
    /// </summary>
    private static void ClickControl(AutomationElement control, IntPtr mainHandle)
    {
        var rect = control.Current.BoundingRectangle;
        if (rect.IsEmpty || rect.Width < 1 || rect.Height < 1)
        {
            throw new InvalidOperationException(
                $"'{control.Current.Name}' has no screen bounds");
        }
        SetForegroundWindow(mainHandle);
        Thread.Sleep(200);
        var screen = new Rect(0, 0, GetSystemMetrics(SmCxScreen),
                              GetSystemMetrics(SmCyScreen));
        // A maximized window keeps a frame past the screen edge, and the top
        // bar can overflow it; a user clicks the visible part, so the pointer
        // is aimed at the centre of the control's on-screen intersection.
        var left = Math.Max(rect.Left, screen.Left);
        var right = Math.Min(rect.Right, screen.Right);
        var top = Math.Max(rect.Top, screen.Top);
        var bottom = Math.Min(rect.Bottom, screen.Bottom);
        if (right - left < 4 || bottom - top < 4)
        {
            throw new InvalidOperationException(
                $"'{control.Current.Name}' sits at {rect}, outside the screen {screen}; " +
                "the injected pointer cannot reach it");
        }
        var x = (left + right) / 2;
        var y = (top + bottom) / 2;
        Console.WriteLine($"  clicking '{control.Current.Name}' at {x:0},{y:0}");
        SetCursorPos((int)Math.Round(x), (int)Math.Round(y));
        Thread.Sleep(120);
        mouse_event(MouseLeftDown, 0, 0, 0, IntPtr.Zero);
        Thread.Sleep(60);
        mouse_event(MouseLeftUp, 0, 0, 0, IntPtr.Zero);
        Thread.Sleep(250);
    }

    private static string DescribeThumbs(AutomationElement window) =>
        string.Join(" | ", window.FindAll(
                TreeScope.Descendants,
                new PropertyCondition(AutomationElement.ControlTypeProperty, ControlType.Thumb))
            .Cast<AutomationElement>()
            .Select(item => $"'{item.Current.Name}' {item.Current.BoundingRectangle}"));

    private static string ToggleStateText(AutomationElement element) =>
        element.TryGetCurrentPattern(TogglePattern.Pattern, out var pattern)
        && pattern is TogglePattern toggle
            ? toggle.Current.ToggleState.ToString()
            : "not a toggle";

    private static int HandleCount(AutomationElement window, string name) =>
        window.FindAll(
                TreeScope.Descendants,
                new AndCondition(
                    new PropertyCondition(AutomationElement.ControlTypeProperty,
                                          ControlType.Thumb),
                    new PropertyCondition(AutomationElement.NameProperty, name)))
            .Count;
    private static void OpenPhoto(AutomationElement window, Process process, string photo)
    {
        var open = FindButton(window, "Open Photo")
            ?? throw new InvalidOperationException("the Open Photo button is missing");
        Invoke(open);
        var openDialog = WaitWindow(process.Id, "Open Photo", TimeSpan.FromSeconds(90))
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
    }

    private static (int Width, int Height) PhotoSize(string path)
    {
        var size = new WindowsImageCodec().ReadSizeAsync(path).GetAwaiter().GetResult();
        return (size.Width, size.Height);
    }

    /// <summary>
    /// Exports through the Export button and its Save dialog, waits for the
    /// file, and decodes what was written. The caller decides what the size
    /// must mean: the whole photo, or the crop the overlay shows.
    /// </summary>
    private static (int Width, int Height) ExportTo(AutomationElement window, Process process,
                                                    IntPtr mainHandle, string output)
    {
        var export = FindButton(window, "Export")
            ?? throw new InvalidOperationException("the Export button is missing");
        Invoke(export);
        // The dialog is the new window the click opened. Its caption is not
        // asserted: on this host the common dialog carries the app title, so
        // the evidence is the window itself plus the export it writes.
        var dialogHandle = WaitNewWindow(process.Id, mainHandle, TimeSpan.FromSeconds(30))
            ?? throw new InvalidOperationException("the Export click opened no window");
        var saveDialog = AutomationElement.FromHandle(dialogHandle);
        var caption = saveDialog.Current.Name;
        if (FindFileNameControl(saveDialog) is null)
        {
            throw new InvalidOperationException(
                $"the Export window '{caption}' has no file-name box: " +
                DescribeWindow(saveDialog));
        }
        Ok($"Export opened its window '{caption}'");

        var saveEdit = SetFileName(saveDialog, output);
        Ok($"typed '{ReadValue(saveEdit)}' into the file-name box " +
           $"[{saveEdit.Current.ControlType.ProgrammaticName} " +
           $"'{saveEdit.Current.AutomationId}' '{saveEdit.Current.Name}']; " +
           $"the window has {DescribeEditors(saveDialog)}");
        var typed = WaitFor(() => ReadValue(saveEdit) == output, TimeSpan.FromSeconds(10));
        if (!typed)
        {
            throw new InvalidOperationException(
                $"the file-name box holds '{ReadValue(saveEdit)}' instead of '{output}'");
        }
        CommitFileName(saveEdit);
        var dismissed = WaitFor(() => !IsWindowVisible(dialogHandle),
                                TimeSpan.FromSeconds(30));
        if (!dismissed)
        {
            // An auto-complete suggestion can swallow the Enter; the button
            // still saves, so the path is only reported as uncommitted.
            PressDefaultButton(saveDialog, "Save", "Open");
            dismissed = WaitFor(() => !IsWindowVisible(dialogHandle),
                                TimeSpan.FromSeconds(30));
        }
        if (!dismissed)
        {
            throw new InvalidOperationException(
                "the Export dialog stayed open after Save; " + DescribeWindow(saveDialog));
        }
        var wrote = WaitFor(
            () => File.Exists(output) && new FileInfo(output).Length > 1024,
            TimeSpan.FromMinutes(2));
        if (!wrote)
        {
            throw new InvalidOperationException(
                "the export never wrote a file; the app's windows are " +
                DescribeAppWindows(process.Id) + "; the status says " +
                DescribeTexts(window) + "; recent files are " +
                RecentFiles(Path.GetDirectoryName(output)) + " and " +
                RecentFiles(AppDirectory(process)));
        }
        Ok($"the export wrote {new FileInfo(output).Length} bytes");

        var codec = new WindowsImageCodec();
        var written = codec.ReadSizeAsync(output).GetAwaiter().GetResult();
        Ok($"the exported file decodes at {written.Width}x{written.Height}");
        return (written.Width, written.Height);
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
            foreach (var handle in VisibleWindows(processId))
            {
                try
                {
                    var yes = FindButton(AutomationElement.FromHandle(handle), "Yes",
                                         contains: true);
                    if (yes is not null)
                    {
                        Invoke(yes);
                        return;
                    }
                }
                catch (ElementNotAvailableException)
                {
                }
            }
            Thread.Sleep(250);
        }
    }

    private static AutomationElement? WaitWindow(int processId, string title,
                                                 TimeSpan patience)
        => WaitWindow((int?)processId, title, patience);

    /// <summary>
    /// The desktop's top-level windows are found through Win32. The common
    /// dialogs are plain visible windows, but this hosted session's UIA root
    /// does not list them among its children; the handle still yields a normal
    /// automation element for their controls.
    /// </summary>
    private static AutomationElement? WaitWindow(int? processId, string title,
                                                 TimeSpan patience)
    {
        var deadline = DateTime.UtcNow + patience;
        while (DateTime.UtcNow < deadline)
        {
            var handle = FindVisibleWindow(processId, title);
            if (handle != IntPtr.Zero)
            {
                try
                {
                    return AutomationElement.FromHandle(handle);
                }
                catch (ElementNotAvailableException)
                {
                }
            }
            Thread.Sleep(250);
        }
        return null;
    }

    private static IntPtr FindVisibleWindow(int? processId, string title)
    {
        var found = IntPtr.Zero;
        EnumWindows((window, _) =>
        {
            if (!IsWindowVisible(window))
            {
                return true;
            }
            GetWindowThreadProcessId(window, out var owner);
            if (processId is { } wanted && owner != (uint)wanted)
            {
                return true;
            }
            var text = new StringBuilder(256);
            GetWindowTextW(window, text, text.Capacity);
            if (text.ToString() != title)
            {
                return true;
            }
            found = window;
            return false;
        }, IntPtr.Zero);
        return found;
    }

    private static List<IntPtr> VisibleWindows(int processId)
    {
        var handles = new List<IntPtr>();
        EnumWindows((window, _) =>
        {
            GetWindowThreadProcessId(window, out var owner);
            if (owner == (uint)processId && IsWindowVisible(window))
            {
                handles.Add(window);
            }
            return true;
        }, IntPtr.Zero);
        return handles;
    }

    /// <summary>
    /// The first visible top-level window of the app other than the one named.
    /// A click that opens a dialog has to produce such a window; the caption is
    /// the dialog's own choice and is reported, not asserted.
    /// </summary>
    private static IntPtr? WaitNewWindow(int processId, IntPtr except, TimeSpan patience)
    {
        var deadline = DateTime.UtcNow + patience;
        while (DateTime.UtcNow < deadline)
        {
            foreach (var handle in VisibleWindows(processId))
            {
                if (handle != except)
                {
                    return handle;
                }
            }
            Thread.Sleep(250);
        }
        return null;
    }

    private static string DescribeWindow(AutomationElement window)
    {
        var text = new StringBuilder();
        foreach (AutomationElement item in window.FindAll(
                     TreeScope.Descendants,
                     new PropertyCondition(AutomationElement.ControlTypeProperty,
                                           ControlType.Text)))
        {
            text.Append('\'').Append(item.Current.Name).Append("' ");
        }
        return $"texts are {text}".TrimEnd();
    }

    private static string DescribeAppWindows(int processId)
    {
        var described = new List<string>();
        foreach (var handle in VisibleWindows(processId))
        {
            var text = new StringBuilder(256);
            GetWindowTextW(handle, text, text.Capacity);
            var name = new StringBuilder(128);
            GetClassNameW(handle, name, name.Capacity);
            described.Add($"'{text}' [{name}]");
        }
        return string.Join(", ", described);
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

    private static AutomationElement? FindText(AutomationElement scope, string name)
    {
        foreach (AutomationElement candidate in scope.FindAll(
                     TreeScope.Descendants,
                     new PropertyCondition(AutomationElement.ControlTypeProperty,
                                           ControlType.Text)))
        {
            if (candidate.Current.Name == name)
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

    private static double SliderValue(AutomationElement element) =>
        element.TryGetCurrentPattern(RangeValuePattern.Pattern, out var pattern)
        && pattern is RangeValuePattern range
            ? range.Current.Value
            : double.NaN;

    /// <summary>
    /// Types an absolute path into the file-name edit one character at a time.
    /// The common dialog mirrors the name from the edit's keystroke
    /// notifications; a value pasted into the automation property, or set on
    /// the window in one call, leaves the dialog's own copy at its default and
    /// Save then returns that default. Only keystrokes update it.
    /// </summary>
    private static AutomationElement SetFileName(AutomationElement dialog, string path)
    {
        var target = FindFileNameControl(dialog)
            ?? throw new InvalidOperationException("the dialog has no file-name box");
        var edit = FindFileNameEdit(dialog);
        if (edit is null)
        {
            if (target.TryGetCurrentPattern(ValuePattern.Pattern, out var pattern)
                && pattern is ValuePattern value)
            {
                value.SetValue(path);
            }
            return target;
        }
        if (!TypeInto(edit, path))
        {
            target.TryGetCurrentPattern(ValuePattern.Pattern, out var pattern);
            (pattern as ValuePattern)?.SetValue(path);
        }
        return edit;
    }

    /// <summary>Clears an edit and types the text as keystrokes, as a person would.</summary>
    private static bool TypeInto(AutomationElement edit, string text)
    {
        var handle = (IntPtr)edit.Current.NativeWindowHandle;
        if (handle == IntPtr.Zero)
        {
            return false;
        }
        SendMessageW(handle, WmSetText, IntPtr.Zero, "");
        foreach (var character in text)
        {
            SendMessageW(handle, WmChar, (IntPtr)(int)character, IntPtr.Zero);
        }
        return true;
    }

    /// <summary>The edit the common dialogs label "Folder:" in the folder picker.</summary>
    private static AutomationElement? FindFolderEdit(AutomationElement dialog)
    {
        foreach (AutomationElement edit in dialog.FindAll(
                     TreeScope.Descendants,
                     new PropertyCondition(AutomationElement.ControlTypeProperty,
                                           ControlType.Edit)))
        {
            if (edit.Current.Name.StartsWith("Folder", StringComparison.OrdinalIgnoreCase)
                && (IntPtr)edit.Current.NativeWindowHandle != IntPtr.Zero)
            {
                return edit;
            }
        }
        return null;
    }

    /// <summary>
    /// Presses Enter inside the file-name edit so the dialog commits its own
    /// copy of the typed path before it closes.
    /// </summary>
    private static void CommitFileName(AutomationElement edit)
    {
        try
        {
            edit.SetFocus();
        }
        catch (ElementNotAvailableException)
        {
            return;
        }
        var handle = (IntPtr)edit.Current.NativeWindowHandle;
        if (handle == IntPtr.Zero)
        {
            return;
        }
        SendMessageW(handle, WmKeyDown, (IntPtr)VkReturn, IntPtr.Zero);
        SendMessageW(handle, WmKeyUp, (IntPtr)VkReturn, IntPtr.Zero);
    }

    private static AutomationElement? FindFileNameEdit(AutomationElement dialog)
    {
        foreach (AutomationElement edit in dialog.FindAll(
                     TreeScope.Descendants,
                     new PropertyCondition(AutomationElement.ControlTypeProperty,
                                           ControlType.Edit)))
        {
            var name = edit.Current.Name;
            if ((edit.Current.AutomationId == "1001"
                 || name.StartsWith("File name", StringComparison.OrdinalIgnoreCase))
                && (IntPtr)edit.Current.NativeWindowHandle != IntPtr.Zero)
            {
                return edit;
            }
        }
        return null;
    }

    private static AutomationElement? FindFileNameControl(AutomationElement dialog)
    {
        AutomationElement? labelled = null;
        AutomationElement? identified = null;
        AutomationElement? anyCombo = null;
        AutomationElement? anyEdit = null;
        foreach (ControlType type in new[] { ControlType.ComboBox, ControlType.Edit })
        {
            foreach (AutomationElement candidate in dialog.FindAll(
                         TreeScope.Descendants,
                         new PropertyCondition(AutomationElement.ControlTypeProperty, type)))
            {
                var name = candidate.Current.Name;
                if (name.StartsWith("File name", StringComparison.OrdinalIgnoreCase))
                {
                    labelled ??= candidate;
                }
                if (candidate.Current.AutomationId == "1148")
                {
                    identified ??= candidate;
                }
                if (type == ControlType.ComboBox)
                {
                    anyCombo ??= candidate;
                }
                else
                {
                    anyEdit ??= candidate;
                }
            }
        }
        return labelled ?? identified ?? anyCombo ?? anyEdit;
    }

    private static string ReadValue(AutomationElement control) =>
        control.TryGetCurrentPattern(ValuePattern.Pattern, out var pattern)
        && pattern is ValuePattern value
            ? value.Current.Value
            : "";

    /// <summary>Every editable control the dialog exposes, with its current text.</summary>
    private static string DescribeEditors(AutomationElement dialog)
    {
        var editors = new List<string>();
        foreach (ControlType type in new[] { ControlType.ComboBox, ControlType.Edit })
        {
            foreach (AutomationElement item in dialog.FindAll(
                         TreeScope.Descendants,
                         new PropertyCondition(AutomationElement.ControlTypeProperty, type)))
            {
                editors.Add($"[{type.ProgrammaticName.Replace("ControlType.", "")} " +
                            $"id '{item.Current.AutomationId}' name '{item.Current.Name}' " +
                            $"value '{ReadValue(item)}']");
            }
        }
        return editors.Count == 0 ? "no editors" : string.Join(" ", editors);
    }

    /// <summary>Every non-empty text the window shows, for a failure report.</summary>
    private static string DescribeTexts(AutomationElement window)
    {
        var texts = new List<string>();
        foreach (AutomationElement item in window.FindAll(
                     TreeScope.Descendants,
                     new PropertyCondition(AutomationElement.ControlTypeProperty,
                                           ControlType.Text)))
        {
            var name = item.Current.Name;
            if (name.Length is > 0 and < 160)
            {
                texts.Add(name);
            }
        }
        return texts.Count == 0 ? "nothing" : string.Join(" | ", texts);
    }

    /// <summary>Every text the window shows, however long — a prompt's body included.</summary>
    private static string AllTexts(AutomationElement window) =>
        string.Join(" ", window.FindAll(
                TreeScope.Descendants,
                new PropertyCondition(AutomationElement.ControlTypeProperty, ControlType.Text))
            .Cast<AutomationElement>()
            .Select(item => item.Current.Name));

    private static string AppDirectory(Process process)
    {
        try
        {
            return Path.GetDirectoryName(process.MainModule?.FileName ?? "") ?? "";
        }
        catch (InvalidOperationException)
        {
            return "";
        }
    }

    /// <summary>Files written to the folder in the last five minutes.</summary>
    private static string RecentFiles(string? directory)
    {
        if (string.IsNullOrEmpty(directory) || !Directory.Exists(directory))
        {
            return $"no folder at '{directory}'";
        }
        var since = DateTime.UtcNow.AddMinutes(-5);
        var files = new DirectoryInfo(directory).GetFiles()
            .Where(file => file.LastWriteTimeUtc >= since)
            .OrderByDescending(file => file.LastWriteTimeUtc)
            .Select(file => $"'{file.Name}' ({file.Length} bytes at " +
                            $"{file.LastWriteTimeUtc:HH:mm:ss}Z)")
            .ToList();
        return files.Count == 0 ? "none" : string.Join(", ", files);
    }

    /// <summary>
    /// The default button of the standard dialog is button 1; the name is the
    /// fallback, with the accelerator ampersand removed.
    /// </summary>
    private static void PressDefaultButton(AutomationElement dialog, params string[] names)
    {
        var button = dialog.FindFirst(
            TreeScope.Descendants,
            new AndCondition(
                new PropertyCondition(AutomationElement.ControlTypeProperty,
                                      ControlType.Button),
                new PropertyCondition(AutomationElement.AutomationIdProperty, "1")));
        foreach (var name in names)
        {
            if (button is not null)
            {
                break;
            }
            button = FindButton(dialog, name);
        }
        if (button is null)
        {
            throw new InvalidOperationException(
                $"the dialog has no '{string.Join("' or '", names)}' button");
        }
        Invoke(button);
    }

    /// <summary>The Thumb controls, once the crop overlay has laid them out.</summary>
    private static List<AutomationElement>? WaitForHandles(AutomationElement window, string name,
                                                          int wanted, TimeSpan patience)
    {
        List<AutomationElement>? found = null;
        WaitFor(() =>
        {
            var current = window.FindAll(
                    TreeScope.Descendants,
                    new AndCondition(
                        new PropertyCondition(AutomationElement.ControlTypeProperty,
                                              ControlType.Thumb),
                        new PropertyCondition(AutomationElement.NameProperty, name)))
                .Cast<AutomationElement>()
                .ToList();
            found = current;
            return current.Count >= wanted;
        }, patience);
        return found is not null && found.Count >= wanted ? found : null;
    }

    /// <summary>
    /// The crop overlay's "width × height" badge, in source pixels, or null
    /// when no badge is on screen.
    /// </summary>
    private static (int Width, int Height)? CropBadgeSize(AutomationElement window)
    {
        foreach (AutomationElement item in window.FindAll(
                     TreeScope.Descendants,
                     new PropertyCondition(AutomationElement.ControlTypeProperty,
                                           ControlType.Text)))
        {
            var match = Regex.Match(item.Current.Name, @"^(\d[\d,]*)\s*×\s*(\d[\d,]*)$");
            if (match.Success
                && int.TryParse(match.Groups[1].Value, NumberStyles.AllowThousands,
                                CultureInfo.InvariantCulture, out var width)
                && int.TryParse(match.Groups[2].Value, NumberStyles.AllowThousands,
                                CultureInfo.InvariantCulture, out var height))
            {
                return (width, height);
            }
        }
        return null;
    }

    /// <summary>
    /// Brings the window fully onto the virtual desktop. Shrinking it would
    /// relayout the crop overlay between measuring a handle and dragging it, so
    /// a window that only hangs over an edge is moved instead.
    /// Returns the window's rect on screen afterwards.
    /// </summary>
    private static Rect FitWindowToScreen(AutomationElement window)
    {
        var screenWidth = GetSystemMetrics(SmCxScreen);
        var screenHeight = GetSystemMetrics(SmCyScreen);
        Console.WriteLine($"  virtual screen: {screenWidth}x{screenHeight}");
        var rect = window.Current.BoundingRectangle;
        Console.WriteLine($"  window rect: {rect}");
        bool Fits(Rect bounds) => bounds.Left >= 0 && bounds.Top >= 0
            && bounds.Right <= screenWidth && bounds.Bottom <= screenHeight;
        if (Fits(rect))
        {
            return rect;
        }
        // The host's minimum window width can exceed a 1024-pixel runner
        // desktop, and a control past the last screen pixel cannot be clicked.
        // Maximizing is the one state the platform itself keeps on screen.
        if (window.TryGetCurrentPattern(WindowPattern.Pattern, out var statePattern)
            && statePattern is WindowPattern windowState && windowState.Current.CanMaximize)
        {
            windowState.SetWindowVisualState(WindowVisualState.Maximized);
            Thread.Sleep(800);
            rect = window.Current.BoundingRectangle;
            Console.WriteLine($"  window rect after maximize: {rect}");
            if (Fits(rect))
            {
                return rect;
            }
        }
        if (!window.TryGetCurrentPattern(TransformPattern.Pattern, out var pattern)
            || pattern is not TransformPattern transform)
        {
            Console.WriteLine("  the window does not accept a transform");
            return rect;
        }
        if (rect.Width > screenWidth || rect.Height > screenHeight)
        {
            if (!transform.Current.CanResize)
            {
                Console.WriteLine("  the window is larger than the screen and cannot shrink");
                return rect;
            }
            transform.Resize(screenWidth - 40, screenHeight - 80);
            Thread.Sleep(800);
            rect = window.Current.BoundingRectangle;
            Console.WriteLine($"  window rect after resize: {rect}");
        }
        if (transform.Current.CanMove)
        {
            transform.Move(Math.Max(0, Math.Min(rect.Left, screenWidth - rect.Width)),
                           Math.Max(0, Math.Min(rect.Top, screenHeight - rect.Height)));
            Thread.Sleep(500);
            rect = window.Current.BoundingRectangle;
            Console.WriteLine($"  window rect after move: {rect}");
        }
        return rect;
    }

    /// <summary>
    /// The bottom-right crop corner the pointer can actually reach: fully on
    /// screen, inside the window, and the element under its centre is the
    /// handle itself. UIA bounds are believed only once a hit test agrees.
    /// </summary>
    private static Rect? WaitForUsableCorner(AutomationElement window, Rect windowRect,
                                             TimeSpan patience)
    {
        var deadline = DateTime.UtcNow + patience;
        var screen = new Rect(0, 0, GetSystemMetrics(SmCxScreen),
                              GetSystemMetrics(SmCyScreen));
        var last = "no corner handle was reported";
        while (DateTime.UtcNow < deadline)
        {
            var handles = WaitForHandles(window, "Crop corner handle", 4,
                                         TimeSpan.FromMilliseconds(500));
            if (handles is not null)
            {
                var inside = handles
                    .Select(item => item.Current.BoundingRectangle)
                    .Where(bounds => bounds.Width >= 1 && bounds.Height >= 1)
                    .Where(bounds => windowRect.Contains(bounds) && screen.Contains(bounds))
                    .OrderByDescending(bounds => bounds.Right + bounds.Bottom)
                    .ToList();
                if (inside.Count == 0)
                {
                    last = $"no corner sits inside {windowRect}; the corners are " +
                           string.Join(", ", handles.Select(item =>
                               item.Current.BoundingRectangle.ToString()));
                }
                else
                {
                    var corner = inside[0];
                    var centre = new Point(corner.X + corner.Width / 2,
                                           corner.Y + corner.Height / 2);
                    AutomationElement? hit = null;
                    try
                    {
                        hit = AutomationElement.FromPoint(centre);
                    }
                    catch (ElementNotAvailableException)
                    {
                    }
                    if (hit is not null
                        && hit.Current.ControlType == ControlType.Thumb
                        && hit.Current.Name == "Crop corner handle")
                    {
                        Console.WriteLine($"  usable corner at {corner}; the pointer reaches it");
                        return corner;
                    }
                    last = $"the pointer at {centre} hits " +
                           (hit is null
                               ? "nothing"
                               : $"{hit.Current.ControlType.ProgrammaticName} " +
                                 $"'{hit.Current.Name}'");
                }
            }
            Thread.Sleep(300);
        }
        Console.WriteLine($"  no usable crop corner: {last}");
        return null;
    }

    private static bool DragHandle(AutomationElement window, Rect rect, double dx, double dy,
                                   (int Width, int Height) before)
    {
        Drag(rect.X + rect.Width / 2, rect.Y + rect.Height / 2, dx, dy, steps: 20);
        return WaitFor(() => CropBadgeSize(window) is { } size && size != before,
                       TimeSpan.FromSeconds(10));
    }

    /// <summary>
    /// A real left-button drag in screen pixels. WPF's Thumb reports DragDelta
    /// only for pointer input, so an automation client must move the pointer.
    /// </summary>
    private static void Drag(double x, double y, double dx, double dy, int steps = 12)
    {
        SetCursorPos((int)Math.Round(x), (int)Math.Round(y));
        Thread.Sleep(150);
        mouse_event(MouseLeftDown, 0, 0, 0, IntPtr.Zero);
        for (var step = 1; step <= steps; step++)
        {
            SetCursorPos((int)Math.Round(x + dx * step / steps),
                         (int)Math.Round(y + dy * step / steps));
            Thread.Sleep(30);
        }
        mouse_event(MouseLeftUp, 0, 0, 0, IntPtr.Zero);
        Thread.Sleep(250);
    }

    [DllImport("user32.dll")]
    private static extern bool SetCursorPos(int x, int y);

    [DllImport("user32.dll")]
    private static extern void mouse_event(uint flags, uint dx, uint dy,
                                           uint data, IntPtr extra);

    [DllImport("user32.dll")]
    private static extern bool SetForegroundWindow(IntPtr window);

    [DllImport("user32.dll")]
    private static extern IntPtr GetForegroundWindow();

    [DllImport("user32.dll")]
    private static extern int GetSystemMetrics(int index);

    [DllImport("user32.dll")]
    private static extern bool GetCursorPos(out NativePoint point);

    [DllImport("user32.dll")]
    private static extern IntPtr WindowFromPoint(NativePoint point);

    [StructLayout(LayoutKind.Sequential)]
    private struct NativePoint
    {
        public int X;
        public int Y;
    }

    private const int SmCxScreen = 0;
    private const int SmCyScreen = 1;

    private const uint MouseLeftDown = 0x0002;
    private const uint MouseLeftUp = 0x0004;

    [DllImport("user32.dll")]
    private static extern bool EnumWindows(EnumWindowsProc callback, IntPtr extra);

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    private static extern int GetWindowTextW(IntPtr window, StringBuilder text, int count);

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    private static extern int GetClassNameW(IntPtr window, StringBuilder name, int count);

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    private static extern IntPtr SendMessageW(IntPtr window, uint message,
                                              IntPtr wParam, string text);

    [DllImport("user32.dll")]
    private static extern IntPtr SendMessageW(IntPtr window, uint message,
                                              IntPtr wParam, IntPtr lParam);

    private const uint WmSetText = 0x000C;
    private const uint WmChar = 0x0102;
    private const uint WmKeyDown = 0x0100;
    private const uint WmKeyUp = 0x0101;
    private const int VkReturn = 0x0D;

    [DllImport("user32.dll")]
    private static extern uint GetWindowThreadProcessId(IntPtr window, out uint processId);

    [DllImport("user32.dll")]
    private static extern bool IsWindowVisible(IntPtr window);

    private delegate bool EnumWindowsProc(IntPtr window, IntPtr extra);

    private static void Dump(Process process)
    {
        try
        {
            Console.Error.WriteLine(
                $"  the app {(process.HasExited ? "exited" : "is running")} (pid {process.Id})");
            Console.Error.WriteLine("  win32 windows:");
            EnumWindows((window, _) =>
            {
                var text = new StringBuilder(256);
                GetWindowTextW(window, text, text.Capacity);
                GetWindowThreadProcessId(window, out var pid);
                Console.Error.WriteLine(
                    $"    pid {pid} visible={IsWindowVisible(window)} '{text}'");
                return true;
            }, IntPtr.Zero);
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
            var handles = VisibleWindows(process.Id);
            if (own is null && handles.Count > 0)
            {
                own = AutomationElement.FromHandle(handles[0]);
            }
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
