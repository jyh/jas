using Microsoft.UI.Xaml;

namespace SbWinUi;

public sealed partial class MainWindow : Window
{
    /// <summary>
    /// The title the verifier asserts on. Deliberately long and specific: the
    /// oracle must assert a value ONLY THIS APP CAN PRODUCE, the same law
    /// <c>scripts/check_native_backend_lane.py</c> is built on. A title like
    /// "MainWindow" would match half the windows ever opened on this desktop and
    /// would pass over a run in which nothing of ours appeared.
    /// </summary>
    public const string VerifyTitle = "JAS S-B MATERIALIZER CHECKPOINT 3";

    private readonly SwapChainHost _host = new();

    public MainWindow()
    {
        InitializeComponent();
        Title = VerifyTitle;

        // SizeChanged rather than Loaded: a SwapChainPanel has no useful size
        // until it has been laid out, and creating a swapchain at 0x0 fails in a
        // way that reads as a device fault.
        Canvas.SizeChanged += (_, e) =>
        {
            if (_started) return;
            var w = (uint)Math.Max(1, e.NewSize.Width);
            var h = (uint)Math.Max(1, e.NewSize.Height);
            Start(w, h);
        };
    }

    private bool _started;

    /// <summary>
    /// Publish the paint outcome INTO THE WINDOW TITLE.
    ///
    /// Not decoration, and not logging. The session-1 oracle reads window titles
    /// and can always see them; whether it can see SWAPCHAIN PIXELS is a separate
    /// and genuinely uncertain question, because a GDI screen copy does not
    /// reliably capture hardware-composed content. Without this, an absent probe
    /// colour is ambiguous between "the core did not paint" and "the camera
    /// cannot see that surface" -- two conclusions with opposite consequences for
    /// S-B, and no way to choose between them.
    ///
    /// The title is a channel that is known to work, carrying a value only a real
    /// paint attempt can produce. It makes the ambiguity decidable instead of
    /// leaving the verifier to guess.
    /// </summary>
    private void Report(string status) => Title = $"{VerifyTitle} | {status}";

    private void Start(uint w, uint h)
    {
        _started = true;
        try
        {
            JasCore.Bind();
            _host.Attach(Canvas, w, h);
            var ok = _host.RenderFrame();
            // The status line names the RUST side explicitly, so a reader can
            // tell "the shell ran and Rust refused" from "the shell never got
            // there" without opening a log.
            StatusLine.Text = ok
                ? $"rust painted via swapchain — {_host.LastStatus}"
                : $"FAILED — {_host.LastStatus}";
            Report(ok ? $"RUSTOK {_host.LastStatus}" : $"RUSTFAIL {_host.LastStatus}");
        }
        catch (Exception ex)
        {
            // Swallowing would leave a blank canvas and a cheerful status, which
            // is the vacuous-success shape this whole branch exists to refuse.
            StatusLine.Text = $"FAILED — {ex.GetType().Name}: {ex.Message}";
            Report($"RUSTFAIL {ex.GetType().Name}: {ex.Message}");
            // A window title holds one line; an interop failure needs the FRAME.
            // Written beside the exe so the session-0 verifier can read what a
            // session-1 process saw -- the two sessions share a filesystem and
            // nothing else.
            try
            {
                File.WriteAllText(
                    Path.Combine(AppContext.BaseDirectory, "sb-error.txt"),
                    ex.ToString());
            }
            catch { /* diagnostics must never become the failure */ }
        }
    }
}
