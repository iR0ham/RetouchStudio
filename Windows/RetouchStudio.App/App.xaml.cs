using System.Windows;
using System.Windows.Threading;

namespace RetouchStudio.App;

public partial class App : Application
{
    protected override void OnStartup(StartupEventArgs e)
    {
        // A Win32 host must not load its Swift core lazily inside a paint: a
        // missing or mismatched studioscore_core.dll should stop the app with a
        // readable message instead of failing the first edit.
        try
        {
            RetouchStudio.Core.Interop.StudioCoreApi.VerifyAbi();
        }
        catch (Exception error)
        {
            if (Environment.GetEnvironmentVariable("RETOUCHSTUDIO_NO_DIALOG") == "1")
            {
                Console.Error.WriteLine($"StudioCore failed to load: {error.Message}");
            }
            else
            {
                MessageBox.Show(
                    $"The shared StudioCore library could not be loaded.\n\n{error.Message}",
                    "Retouch Studio", MessageBoxButton.OK, MessageBoxImage.Error);
            }
            Shutdown(1);
            return;
        }

        DispatcherUnhandledException += OnUnhandledException;
        // Removes only stale, unlocked staging/quarantine trees; it never
        // downloads and never touches an installed version.
        _ = Task.Run(() =>
        {
            try
            {
                RetouchStudio.AI.Models.ModelStore.CreateProduction().Cleanup();
            }
            catch (Exception error)
            {
                Console.Error.WriteLine($"model cleanup skipped: {error.Message}");
            }
        });
        base.OnStartup(e);
    }

    /// <summary>
    /// Windows is logging off or restarting. This is the last point before the
    /// process is terminated, so the pending debounced autosave is committed
    /// now; an export still in flight is cancelled rather than left to be cut
    /// off mid-write.
    /// </summary>
    protected override void OnSessionEnding(SessionEndingCancelEventArgs e)
    {
        if (MainWindow is RetouchStudio.App.MainWindow window)
        {
            window.FlushForSessionEnd();
        }
        base.OnSessionEnding(e);
    }

    private static void OnUnhandledException(object sender, DispatcherUnhandledExceptionEventArgs e)    {
        if (Environment.GetEnvironmentVariable("RETOUCHSTUDIO_NO_DIALOG") == "1")
        {
            Console.Error.WriteLine(e.Exception.ToString());
            e.Handled = true;
            Environment.Exit(2);
            return;
        }
        MessageBox.Show(e.Exception.Message, "Retouch Studio",
                        MessageBoxButton.OK, MessageBoxImage.Error);
        e.Handled = true;
    }
}
