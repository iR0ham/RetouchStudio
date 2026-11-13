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
        base.OnStartup(e);
    }

    private static void OnUnhandledException(object sender, DispatcherUnhandledExceptionEventArgs e)
    {
        MessageBox.Show(e.Exception.Message, "Retouch Studio",
                        MessageBoxButton.OK, MessageBoxImage.Error);
        e.Handled = true;
    }
}
