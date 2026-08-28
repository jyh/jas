using Microsoft.UI.Xaml;
using Windows.Graphics;

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

        // SB_FULLSCREEN: THE COPY COST IS FIXED BY SURFACE AREA, so pricing it
        // needs a run at the display's full resolution and not at whatever size
        // WinUI happens to give a new window. The default 1904x941 is 1.79 Mpx
        // against this display's 8.29 Mpx -- 22% -- so a copy priced only there
        // understates the full-screen cost by ~4.6x.
        //
        // Set BEFORE the panel is laid out, so the FIRST SizeChanged (the one
        // that starts the run, because of the _started latch below) is already
        // the fullscreen size. If this ran after layout the latch would capture
        // the default size and the run would report 4K in its label while
        // measuring a small window -- and the numbers would look entirely
        // plausible. `LastStatus` prints the ACTUAL {_width}x{_height} beside
        // every timing for exactly that reason: verify the size from the run's
        // own output, never from the flag that was passed to it.
        if (Environment.GetEnvironmentVariable("SB_FULLSCREEN") == "1")
        {
            AppWindow.SetPresenter(Microsoft.UI.Windowing.AppWindowPresenterKind.FullScreen);
        }

        // SizeChanged rather than Loaded: a SwapChainPanel has no useful size
        // until it has been laid out, and creating a swapchain at 0x0 fails in a
        // way that reads as a device fault.
        Canvas.SizeChanged += (_, e) =>
        {
            var w = (uint)Math.Max(1, e.NewSize.Width);
            var h = (uint)Math.Max(1, e.NewSize.Height);
            if (!_started) { Start(w, h); return; }

            // ⛔ THE LATCH USED TO RETURN HERE, and that was the defect.
            //
            // `if (_started) return;` meant the first laid-out size was the only
            // size the swapchain ever had. Right for a fixed-size MEASUREMENT
            // harness -- it is what keeps a run's label honest -- and wrong the
            // moment this route is the product, because the back buffer then
            // outgrows an offscreen target that is never recreated and the copy
            // is silently dropped.
            //
            // A LATER RESIZE IS REPORTED AS LOUDLY AS THE FIRST PAINT. A resize
            // that fails must not leave the title still showing the last good
            // frame's status, which would read to the session-1 oracle as a
            // healthy window.
            if (!_host.Resize(w, h))
            {
                StatusLine.Text = $"FAILED — {_host.LastStatus}";
                Report($"RUSTFAIL {_host.LastStatus}");
                return;
            }
            // ⛔ CARRY ResizeCost EXPLICITLY. RenderFrame overwrites LastStatus,
            // so the resize's own three-part timing -- the whole point of driving
            // a resize -- was computed and then thrown away before anything read
            // it. Found by running the paired sweep and seeing eight arms report
            // no resize number at all. An instrument that overwrites its own
            // result is the same class this branch keeps finding, arriving in the
            // code I added to measure with.
            var cost = _host.ResizeCost;
            var ok = _host.RenderFrame();
            StatusLine.Text = ok
                ? $"rust repainted after resize — {_host.LastStatus}"
                : $"FAILED after resize — {_host.LastStatus}";
            Report(ok
                ? $"RUSTOK RESIZE[{cost}] {_host.LastStatus}"
                : $"RUSTFAIL RESIZE[{cost}] {_host.LastStatus}");
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

    /// <summary>
    /// SB_RESIZE=WxH -- resize the window ONCE, after the first run, so the
    /// resize path is exercised by a REAL SizeChanged rather than by calling
    /// <c>Resize</c> directly.
    ///
    /// THE DISTINCTION IS THE POINT. Calling <c>SwapChainHost.Resize</c> from a
    /// test would prove the method works while leaving untested the thing that
    /// actually broke: the WIRING -- a latch that swallowed the event before the
    /// method was ever reached. An experiment that bypasses the defective link
    /// cannot fail on it.
    ///
    /// Posted through the dispatcher rather than called inline: the first
    /// SizeChanged is still on the stack, and resizing from inside a layout pass
    /// is how a reentrancy fault gets blamed on the graphics code.
    ///
    /// A malformed value REFUSES LOUDLY instead of falling back to no resize --
    /// a run labelled "resize" that quietly did not resize is exactly the
    /// vacuity this harness exists to refuse.
    /// </summary>
    private void MaybeDriveResize()
    {
        var spec = Environment.GetEnvironmentVariable("SB_RESIZE");
        if (string.IsNullOrWhiteSpace(spec)) return;

        var parts = spec.Split('x', 'X');
        if (parts.Length != 2
            || !int.TryParse(parts[0], out var rw) || !int.TryParse(parts[1], out var rh)
            || rw < 1 || rh < 1)
        {
            StatusLine.Text = $"FAILED — SB_RESIZE malformed: '{spec}' (want WxH)";
            Report($"RUSTFAIL SB_RESIZE malformed: '{spec}'");
            return;
        }

        DispatcherQueue.TryEnqueue(() =>
        {
            try
            {
                AppWindow.Resize(new SizeInt32(rw, rh));
            }
            catch (Exception ex)
            {
                StatusLine.Text = $"FAILED — resize request threw {ex.GetType().Name}";
                Report($"RUSTFAIL resize request {ex.GetType().Name}: {ex.Message}");
            }
        });
    }

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
            if (ok) MaybeDriveResize();
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
