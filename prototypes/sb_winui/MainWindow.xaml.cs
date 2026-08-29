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
            // ── FIRST LAYOUT ────────────────────────────────────────────────
            if (!_started)
            {
                // SB_SIZE=WxH -- A MEASUREMENT INPUT, AND DELIBERATELY NOT THE FIX.
                // (from the base branch; kept verbatim in intent.)
                //
                // `e.NewSize` is in DIPs. At 150% scaling a 3840x2160 display
                // reports 2560x1440, so every surface this harness measured was
                // 3.60 Mpx -- 43% of the display -- and the true physical-4K copy
                // cost had never been measured. The FIX for that is to read
                // CompositionScaleX/Y and set the swapchain's inverse matrix
                // transform; it is BOOKED WORK (jyh/jas#16) and is not smuggled
                // in here. This is the narrower thing: an explicit size input
                // that sizes the SWAPCHAIN in physical pixels so the copy can be
                // priced at a real 4K surface.
                var forced = Environment.GetEnvironmentVariable("SB_SIZE");
                if (!string.IsNullOrWhiteSpace(forced))
                {
                    var parts = forced.Split('x', 'X');
                    if (parts.Length == 2
                        && uint.TryParse(parts[0], out var fw) && fw > 0
                        && uint.TryParse(parts[1], out var fh) && fh > 0)
                    {
                        w = fw; h = fh;
                    }
                    else
                    {
                        // REFUSE LOUDLY. A malformed SB_SIZE that silently fell
                        // back to the DIP size would produce a run labelled 4K
                        // and measured at 3.6 Mpx -- the exact confusion this
                        // input exists to end, wearing the label of its own cure.
                        Report($"SBFAIL bad SB_SIZE '{forced}' (want WxH)");
                        StatusLine.Text = $"FAILED - bad SB_SIZE '{forced}'";
                        _started = true;
                        return;
                    }
                }

                Start(w, h);
                return;
            }

            // ── EVERY LATER RESIZE ──────────────────────────────────────────
            //
            // ⛔ THE LATCH USED TO RETURN HERE, and that was the defect.
            // `if (_started) return;` meant the first laid-out size was the only
            // size the swapchain ever had -- right for a fixed-size MEASUREMENT
            // harness, wrong the moment this route is the product, because the
            // back buffer then outgrows an offscreen target that is never
            // recreated and the copy is SILENTLY DROPPED.
            //
            // ⚠️ SB_SIZE AND A RESIZE ARE MUTUALLY EXCLUSIVE, and this is the one
            // decision the merge had to make rather than inherit. SB_SIZE exists
            // to pin the swapchain at a stated physical size so a number can be
            // attributed to it; a later resize moves the surface out from under
            // that pin. Honouring both would produce a run LABELLED with the
            // forced size and MEASURED at another -- precisely the confusion
            // SB_SIZE's own comment says it exists to end. So the pin wins and
            // the resize is REFUSED BY NAME rather than silently ignored.
            if (!string.IsNullOrWhiteSpace(Environment.GetEnvironmentVariable("SB_SIZE")))
            {
                Report($"RUSTFAIL SB_SIZE pins the surface; a resize to {w}x{h} would "
                     + "measure a size the run is not labelled with. Use one or the other.");
                StatusLine.Text = "FAILED - SB_SIZE and SB_RESIZE are mutually exclusive";
                return;
            }

            // A LATER RESIZE IS REPORTED AS LOUDLY AS THE FIRST PAINT. A resize
            // that fails must not leave the title showing the last good frame's
            // status, which would read to the session-1 oracle as a healthy
            // window.
            if (!_host.Resize(w, h))
            {
                StatusLine.Text = $"FAILED — {_host.LastStatus}";
                Report($"RUSTFAIL {_host.LastStatus}");
                return;
            }
            // ⛔ CARRY ResizeCost EXPLICITLY. RenderFrame overwrites LastStatus,
            // so the resize's own three-part timing -- the whole point of driving
            // a resize -- was computed and then thrown away before anything read
            // it. An instrument that overwrites its own result is the same class
            // this branch keeps finding, arriving in the code I added to measure
            // with.
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
    private void Report(string status)
    {
        Title = $"{VerifyTitle} | {status}";

        // AND WRITE IT TO A FILE, because the title alone cannot carry a
        // measurement back to the agent shell.
        //
        // The title was the right channel for the question S-B first asked --
        // "is there a window at all" -- and a session-1 observer can read it.
        // It is the WRONG channel for "give me four numbers": session 0 cannot
        // see session 1's titles, so a sweep driven from the agent shell would
        // have to screenshot and OCR its own results.
        //
        // The two sessions share a filesystem and nothing else. This is the same
        // shape the S-C.1 harness settled on for the same reason, and the receipt
        // is APPENDED so a multi-arm sweep accumulates rather than overwriting --
        // an overwriting receipt cannot tell four arms from the last one, which
        // is the defect my own statusline marker had this morning.
        try
        {
            var path = System.IO.Path.Combine(AppContext.BaseDirectory, "sb-runs.log");
            var mode = Environment.GetEnvironmentVariable("SB_MODE") ?? "(default:offscreen)";
            var size = Environment.GetEnvironmentVariable("SB_SIZE") ?? "(window)";
            var frames = Environment.GetEnvironmentVariable("SB_FRAMES") ?? "(default:60)";
            System.IO.File.AppendAllText(path,
                $"{DateTime.Now:HH:mm:ss}\tSB_MODE={mode}\tSB_SIZE={size}\tSB_FRAMES={frames}\t{status}\n");
        }
        catch
        {
            // Diagnostics must never become the failure.
        }
    }

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
