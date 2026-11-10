namespace SbWinUi;

/// <summary>
/// The pointer position the shell hands the core, read from WinRT's bytes.
///
/// ⛔ PURE ON PURPOSE, like `PanelWire`: `sb_winui_tests` links this file.
/// </summary>
internal static class PointerWire
{
    /// <summary>How far from a whole physical pixel a reading may be and still
    /// BE that pixel. A thousandth of a pixel is far below anything a pen can
    /// mean. ⛔ THE BOUND: WinRT's `Point` is two floats, and a float's step
    /// grows with magnitude (about 2.4e-4 px near 4,096 px, about 1e-3 px near
    /// 16,384 px), so this window covers the noise only for canvas coordinates
    /// under about 8k physical pixels. Today's displays are well inside that; a
    /// canvas past it would see the noise again, unsnapped.</summary>
    internal const double SnapWindow = 1e-3;

    /// <summary>
    /// A physical-pixel reading within <see cref="SnapWindow"/> of a whole pixel
    /// is that pixel; any other reading is kept as it is.
    ///
    /// ⛔ WHY (2026-10-11): `GetCurrentPoint(Canvas)` subtracts the canvas's
    /// origin from the window position in FLOAT32. Layout rounding puts the
    /// origin on a whole physical pixel, which is not a whole DIP at scale 1.5
    /// (122 px = 81.333... DIPs, beside the toolbar column), so a mouse on a
    /// whole pixel came back a hair off it, and the E2E drag landed x1=5.999992
    /// where the cross-port spec says 6.0. The snap removes the noise and never
    /// moves a real sub-pixel position (a pen's, a half pixel).
    /// </summary>
    internal static double Snap(double px)
    {
        var whole = Math.Round(px);
        return Math.Abs(px - whole) <= SnapWindow ? whole : px;
    }
}

/// <summary>
/// G11 step 3 (jas sections 756, 758): WHEN the canvas sends the engine its
/// double-click, `jas_pointer_event`'s `KIND_DOUBLE_CLICK`.
///
/// The corpus's order is press, release, press, release, double_click (the
/// browser's `dblclick`). WinUI raises `DoubleTapped` ON THE SECOND PRESS
/// (measured on the Windows box at 60 and 150 ms gaps), while that press's
/// gesture is still open, so the double is MARKED there and sent by the
/// release that closes the gesture, after the release. A `DoubleTapped` with
/// no gesture open (raised after the release) is sent at once. A lost capture
/// is not a release a person made, so it drops a marked double.
///
/// ⛔ PURE ON PURPOSE, like `PointerWire`: `sb_winui_tests` links this file.
/// </summary>
internal sealed class DoubleClickGate
{
    private bool _pending;

    /// <summary>WinUI raised `DoubleTapped`. True when the double must be sent
    /// NOW (no gesture is open to close); false when it is marked for the
    /// release that closes the open one.</summary>
    internal bool OnDoubleTapped(bool gestureOpen)
    {
        if (!gestureOpen) { return true; }
        _pending = true;
        return false;
    }

    /// <summary>A gesture closed. True when this release must be followed by
    /// the double: a marked double and a REAL release. Either way the mark is
    /// spent.</summary>
    internal bool TakeOnRelease(bool real)
    {
        var send = _pending && real;
        _pending = false;
        return send;
    }
}
