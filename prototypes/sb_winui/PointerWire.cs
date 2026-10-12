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
