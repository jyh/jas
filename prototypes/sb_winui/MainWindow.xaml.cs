using Microsoft.UI.Xaml;

namespace SbWinUi;

public sealed partial class MainWindow : Window
{
    /// <summary>
    /// The title the verifier asserts on. It is deliberately long and specific:
    /// the oracle must assert a value ONLY THIS APP CAN PRODUCE, which is the
    /// same law `scripts/check_native_backend_lane.py` is built on. A title like
    /// "MainWindow" would match half the windows ever opened on this desktop and
    /// would pass over a run in which nothing of ours appeared.
    /// </summary>
    public const string VerifyTitle = "JAS S-B MATERIALIZER CHECKPOINT 1";

    public MainWindow()
    {
        InitializeComponent();
        Title = VerifyTitle;
    }
}
