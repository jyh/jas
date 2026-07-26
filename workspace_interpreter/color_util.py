"""Color conversion utilities matching app.js implementations."""


def parse_hex(c: str | None) -> tuple[int, int, int]:
    """Parse a hex color string to (r, g, b). Returns (0,0,0) for invalid input."""
    if not c or not isinstance(c, str):
        return (0, 0, 0)
    h = c.lstrip("#")
    if len(h) == 3:
        h = h[0]*2 + h[1]*2 + h[2]*2
    if len(h) != 6:
        return (0, 0, 0)
    try:
        return (int(h[0:2], 16), int(h[2:4], 16), int(h[4:6], 16))
    except ValueError:
        return (0, 0, 0)


def rgb_to_hex(r: int, g: int, b: int) -> str:
    """Convert RGB to 6-digit hex with # prefix."""
    r = max(0, min(255, round(r)))
    g = max(0, min(255, round(g)))
    b = max(0, min(255, round(b)))
    return f"#{r:02x}{g:02x}{b:02x}"


def rgb_to_hsb(r: int, g: int, b: int) -> tuple[int, int, int]:
    """Convert RGB (0-255) to HSB (h:0-359, s:0-100, b:0-100)."""
    r1, g1, b1 = r / 255.0, g / 255.0, b / 255.0
    mx = max(r1, g1, b1)
    mn = min(r1, g1, b1)
    d = mx - mn
    h = 0.0
    s = 0.0 if mx == 0 else d / mx
    v = mx
    if d > 0:
        if mx == r1:
            h = ((g1 - b1) / d + (6 if g1 < b1 else 0)) / 6.0
        elif mx == g1:
            h = ((b1 - r1) / d + 2) / 6.0
        else:
            h = ((r1 - g1) / d + 4) / 6.0
    hue = round(h * 360) % 360
    return (hue, round(s * 100), round(v * 100))


def saturate_u8(v: float) -> int:
    """Convert a float to 0..255 the way Rust's ``v as u8`` does.

    Truncate toward zero, saturate at both bounds, NaN -> 0. Spelled out as a
    function because the other ports' native conversions differ: Rust's ``as``
    saturates, and Swift's ``UInt8(_:)`` / ``Int(_:)`` are precondition failures
    outside range, so both must be routed through this one rule to agree.
    Risk R9, transcripts/CORPUS_CENSUS.md section 7.
    """
    if v != v:  # NaN
        return 0
    if v <= 0.0:
        return 0
    if v >= 255.0:
        return 255
    return int(v)


def clamp_channel(v: float, lo: float, hi: float) -> float:
    """Clamp one colour channel into [lo, hi], mapping NaN to lo.

    The colour primitives document their channels' ranges (hsb 0-360 / 0-100,
    cmyk and grayscale 0-100) and this is how they enforce them: clamp the
    INPUT, before any arithmetic. Clamping the input rather than saturating the
    output is what makes the ports equal by construction. The formulas are
    monotonic per channel, so for ONE out-of-range channel the two approaches
    agree; they diverge when two channels overflow with signs that multiply back
    positive -- unclamped, cmyk(150, 0, 0, 150) computes
    (1-1.5)*(1-1.5)*255 = +63.75, a bogus mid-grey that looks like a real
    colour, where clamping gives black. Risk R9, transcripts/CORPUS_CENSUS.md
    section 7.
    """
    if v != v:  # NaN
        return lo
    return max(lo, min(hi, v))


def hsb_to_rgb(h: float, s: float, b: float) -> tuple[int, int, int]:
    """Convert HSB (h:0-360, s:0-100, b:0-100) to RGB (0-255).

    Channels outside those ranges are clamped (see clamp_channel). Hue's upper
    bound is 360, not 359: 360 is the wrap point that the colour corpus pins as
    identical to 0 (torgb_hue_360_is_red).
    """
    h = clamp_channel(h, 0.0, 360.0)
    s = clamp_channel(s, 0.0, 100.0)
    b = clamp_channel(b, 0.0, 100.0)
    s1 = s / 100.0
    b1 = b / 100.0
    c = b1 * s1
    x = c * (1 - abs((h / 60.0) % 2 - 1))
    m = b1 - c
    if h < 60:
        r1, g1, b1_ = c, x, 0.0
    elif h < 120:
        r1, g1, b1_ = x, c, 0.0
    elif h < 180:
        r1, g1, b1_ = 0.0, c, x
    elif h < 240:
        r1, g1, b1_ = 0.0, x, c
    elif h < 300:
        r1, g1, b1_ = x, 0.0, c
    else:
        r1, g1, b1_ = c, 0.0, x
    return (round((r1 + m) * 255), round((g1 + m) * 255), round((b1_ + m) * 255))


def rgb_to_cmyk(r: int, g: int, b: int) -> tuple[int, int, int, int]:
    """Convert RGB (0-255) to CMYK (0-100 each)."""
    if r == 0 and g == 0 and b == 0:
        return (0, 0, 0, 100)
    c1 = 1 - r / 255.0
    m1 = 1 - g / 255.0
    y1 = 1 - b / 255.0
    k1 = min(c1, m1, y1)
    return (
        round((c1 - k1) / (1 - k1) * 100),
        round((m1 - k1) / (1 - k1) * 100),
        round((y1 - k1) / (1 - k1) * 100),
        round(k1 * 100),
    )


def cmyk_to_rgb(c: float, m: float, y: float, k: float) -> tuple[int, int, int]:
    """Convert CMYK (0-100 each) to RGB (0-255)."""
    c1, m1, y1, k1 = c / 100.0, m / 100.0, y / 100.0, k / 100.0
    return (
        round(255 * (1 - c1) * (1 - k1)),
        round(255 * (1 - m1) * (1 - k1)),
        round(255 * (1 - y1) * (1 - k1)),
    )
