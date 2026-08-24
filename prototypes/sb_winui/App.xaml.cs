using Microsoft.UI.Xaml;

namespace SbWinUi;

/// <summary>
/// S-B checkpoint 1: the shell exists and can put a window on the desktop.
///
/// Deliberately does NOT touch D3D, DXGI or the Rust core yet. §5 of this seat's
/// breadcrumb records what it cost to change two variables at once here before --
/// a launch-mechanism fault was briefly believed to be the Dioxus CLI. The chain
/// under test in this checkpoint is exactly: dotnet SDK -> WinUI 3 -> interactive
/// scheduled task -> a window that a session-1 observer can actually see.
/// SwapChainPanel and the painter arrive only once this passes.
/// </summary>
public partial class App : Application
{
    private Window? _window;

    public App()
    {
        InitializeComponent();

        // A LAST-RESORT RECORDER, and it earned its place: an exception thrown
        // outside MainWindow.Start's try/catch killed the process with only an
        // 0xE0434352 exit code to show for it, and the window simply never
        // appeared. "No window and no log" is indistinguishable from a launch
        // that never happened, which is the ambiguity this whole harness exists
        // to remove.
        AppDomain.CurrentDomain.UnhandledException += (_, e) => Dump("domain", e.ExceptionObject);
        TaskScheduler.UnobservedTaskException += (_, e) => Dump("task", e.Exception);
        UnhandledException += (_, e) => { Dump("xaml", e.Exception); e.Handled = true; };
    }

    private static void Dump(string source, object? error)
    {
        try
        {
            File.AppendAllText(
                Path.Combine(AppContext.BaseDirectory, "sb-error.txt"),
                $"--- unhandled ({source}) ---{Environment.NewLine}{error}{Environment.NewLine}");
        }
        catch { /* diagnostics must never become the failure */ }
    }

    protected override void OnLaunched(LaunchActivatedEventArgs args)
    {
        _window = new MainWindow();
        _window.Activate();
    }
}
