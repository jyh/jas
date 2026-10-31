import Testing
@testable import JasLib

/// THE PICTURE AND THE PICK ARE ONE FUNCTION (the 10-30 finding-13 read): at
/// each of the H-mode strip's evenly spaced stops, the hue the strip's pick
/// returns there draws as that stop's colour. Before the fix the stop one
/// sixth down was drawn yellow and picked magenta, in this port and the web's.
/// A tolerance of 8 per channel covers the pick's 359 maximum against 360.
@Test func theHueStripPicksTheHueItDraws() {
    let stops = hueBarHStops
    #expect(stops.count == 7)
    for (k, want) in stops.enumerated() {
        let y = Double(k) / 6.0 * 180.0
        let hue = hueBarValue(y: y, height: 180, max: 359)
        let (r, g, b) = hsbToRgb(hue, 100, 100)
        let near = { (a: UInt8, w: Int) in abs(Int(a) - w) <= 8 }
        #expect(near(r, want.0) && near(g, want.1) && near(b, want.2),
                "stop \(k) at y \(y): drawn \(want), picked hue \(hue) = (\(r), \(g), \(b))")
    }
}
