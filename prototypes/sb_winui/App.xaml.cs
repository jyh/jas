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
    }

    protected override void OnLaunched(LaunchActivatedEventArgs args)
    {
        _window = new MainWindow();
        _window.Activate();
    }
}
