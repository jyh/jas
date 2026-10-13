import Testing
@testable import JasLib

/// A CLOSED PATH'S START IS ONE POINT, EVEN WHEN IT IS TWO ANCHORS. Twin of
/// Rust's `closed_path_twin_tests` in `geometry/element.rs`, arm for arm.
///
/// The pen closes a path as `MoveTo P0 … CurveTo(…, P0) Z`, so the start is
/// anchor 0 AND the closing segment's endpoint, anchor n. Partial Selection's
/// click picks the first control point in index order, so a click on the start
/// selects anchor 0 alone. Before these arms, moving it left the closing
/// endpoint behind and the `Z` drew a stray straight segment. The closing
/// endpoint is anchor 0's TWIN: selecting either moves both.
@Suite("A closed path's start and its closing endpoint move together")
struct ClosedPathTwinTests {

    private func cps(_ i: [Int]) -> SelectionKind { .partial(SortedCps(i)) }

    private func moved(_ d: [PathCommand], _ sel: [Int], dx: Double, dy: Double) -> [PathCommand] {
        let e = Element.path(Path(d: d, fillRule: .nonzero))
        guard case .path(let p) = e.moveControlPoints(cps(sel), dx: dx, dy: dy) else {
            Issue.record("a path stays a path")
            return []
        }
        return p.d
    }

    /// Anchor 0 = (0,0), anchor 1 = (100,0), anchor 2 = the closing endpoint,
    /// back on (0,0) with in-handle (-10,50).
    private let penClosed: [PathCommand] = [
        .moveTo(0, 0),
        .curveTo(x1: 10, y1: -10, x2: 90, y2: -10, x: 100, y: 0),
        .curveTo(x1: 110, y1: 50, x2: -10, y2: 50, x: 0, y: 0),
        .closePath,
    ]

    /// The start moves with its out-handle (cmd 1's x1) AND its in-handle (the
    /// closing x2); the previous anchor's out-handle and anchor 1 stay.
    private let penClosedStartMovedBy30: [PathCommand] = [
        .moveTo(30, 0),
        .curveTo(x1: 40, y1: -10, x2: 90, y2: -10, x: 100, y: 0),
        .curveTo(x1: 110, y1: 50, x2: 20, y2: 50, x: 30, y: 0),
        .closePath,
    ]

    @Test func movingTheStartMovesItsClosingTwin() {
        #expect(moved(penClosed, [0], dx: 30, dy: 0) == penClosedStartMovedBy30)
    }

    @Test func movingTheClosingEndpointMovesTheStart() {
        #expect(moved(penClosed, [2], dx: 30, dy: 0) == penClosedStartMovedBy30)
    }

    /// Both twins selected (a marquee over the start) is the same move, once.
    @Test func selectingBothTwinsMovesTheStartOnce() {
        #expect(moved(penClosed, [0, 2], dx: 30, dy: 0) == penClosedStartMovedBy30)
    }

    /// CONTROL: with no `Z`, a path that ends on its start is OPEN.
    @Test func anOpenPathEndingOnItsStartIsNotLinked() {
        let d = Array(penClosed.dropLast())
        let got = moved(d, [0], dx: 30, dy: 0)
        #expect(got[2] == d[2], "the open end did not move")
        #expect(got[0] == .moveTo(30, 0))
    }

    /// CONTROL: a straight `Z` close has no twin; the start moves alone.
    @Test func aStraightCloseHasNoTwin() {
        let d: [PathCommand] = [.moveTo(0, 0), .lineTo(100, 0), .lineTo(50, 80), .closePath]
        #expect(moved(d, [0], dx: 30, dy: 0)
                == [.moveTo(30, 0), .lineTo(100, 0), .lineTo(50, 80), .closePath])
    }

    /// Each subpath links its own twins (anchors 3 and 5 here).
    @Test func twinsArePerSubpath() {
        let d = penClosed + [.moveTo(200, 0), .lineTo(300, 0), .lineTo(200, 0), .closePath]
        let got = moved(d, [3], dx: 0, dy: 7)
        #expect(Array(got[..<4]) == penClosed, "the first subpath is untouched")
        #expect(got[4] == .moveTo(200, 7))
        #expect(got[5] == .lineTo(300, 0))
        #expect(got[6] == .lineTo(200, 7))
        #expect(Array(moved(d, [0], dx: 30, dy: 0)[4...]) == Array(d[4...]))
    }

    /// AN ANCHOR REACHED BY A LINE STILL OWNS ITS OUT-HANDLE (Rust's
    /// `an_anchor_reached_by_a_line_moves_its_out_handle`). Rust moved the next
    /// CurveTo's x1 with a LineTo anchor and Swift did not, so the same drag
    /// bent the outgoing curve differently in the two ports.
    @Test func anAnchorReachedByALineMovesItsOutHandle() {
        let d: [PathCommand] = [
            .moveTo(0, 0), .lineTo(100, 0),
            .curveTo(x1: 110, y1: 10, x2: 190, y2: 10, x: 200, y: 0),
        ]
        #expect(moved(d, [1], dx: 0, dy: 5) == [
            .moveTo(0, 0), .lineTo(100, 5),
            .curveTo(x1: 110, y1: 15, x2: 190, y2: 10, x: 200, y: 0),
        ])
    }
}
