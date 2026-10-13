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

/// THE TWINS SHARE THEIR HANDLES. Twin of Rust's
/// `closed_path_twin_handle_tests`, arm for arm. A pen-closed path's start (a
/// `moveTo`) has no in-segment: its in-handle is the closing curve's x2. The
/// closing endpoint has no out-segment: its out-handle is the first
/// segment's x1. A Convert on a straight-`closePath` close inserts the pen's
/// closing curve to hold the start's in-handle.
@Suite("A closed path's start and its closing endpoint share their handles")
struct ClosedPathTwinHandleTests {

    private let penClosed: [PathCommand] = [
        .moveTo(0, 0),
        .curveTo(x1: 10, y1: -10, x2: 90, y2: -10, x: 100, y: 0),
        .curveTo(x1: 110, y1: 50, x2: -10, y2: 50, x: 0, y: 0),
        .closePath,
    ]

    private let penClosedStartCornered: [PathCommand] = [
        .moveTo(0, 0),
        .curveTo(x1: 0, y1: 0, x2: 90, y2: -10, x: 100, y: 0),
        .curveTo(x1: 110, y1: 50, x2: 0, y2: 0, x: 0, y: 0),
        .closePath,
    ]

    private func eq(_ a: (Double, Double)?, _ b: (Double, Double)?) -> Bool {
        switch (a, b) {
        case (nil, nil): return true
        case let (p?, q?): return p.0 == q.0 && p.1 == q.1
        default: return false
        }
    }

    @Test func theStartAndItsTwinReportTheSameTwoHandles() {
        for i in [0, 2] {
            let (hIn, hOut) = pathHandlePositions(penClosed, anchorIdx: i)
            #expect(eq(hIn, (-10, 50)), "anchor \(i) in")
            #expect(eq(hOut, (10, -10)), "anchor \(i) out")
        }
        // CONTROL: a middle anchor reads its own two handles, unchanged.
        let (mIn, mOut) = pathHandlePositions(penClosed, anchorIdx: 1)
        #expect(eq(mIn, (90, -10)) && eq(mOut, (110, 50)))
    }

    @Test func aStartWithOnlyAnInHandleIsSmooth() {
        var d = penClosed
        d[1] = .curveTo(x1: 0, y1: 0, x2: 90, y2: -10, x: 100, y: 0)
        #expect(isSmoothPoint(d, anchorIdx: 0))
    }

    @Test func convertingTheStartToACornerCollapsesBothOfItsHandles() {
        for i in [0, 2] {
            #expect(convertSmoothToCorner(penClosed, anchorIdx: i) == penClosedStartCornered, "anchor \(i)")
        }
    }

    @Test func convertingTheStartToSmoothWritesBothOfItsHandles() {
        let want: [PathCommand] = [
            .moveTo(0, 0),
            .curveTo(x1: 20, y1: -20, x2: 90, y2: -10, x: 100, y: 0),
            .curveTo(x1: 110, y1: 50, x2: -20, y2: 20, x: 0, y: 0),
            .closePath,
        ]
        for i in [0, 2] {
            #expect(convertCornerToSmooth(penClosedStartCornered, anchorIdx: i, hx: 20, hy: -20) == want,
                    "anchor \(i)")
        }
    }

    @Test func convertingTheStartOfAStraightCloseInsertsTheClosingCurve() {
        let tri: [PathCommand] = [.moveTo(0, 0), .lineTo(100, 0), .lineTo(50, 80), .closePath]
        let got = convertCornerToSmooth(tri, anchorIdx: 0, hx: 0, hy: -20)
        #expect(got == [
            .moveTo(0, 0),
            .curveTo(x1: 0, y1: -20, x2: 100, y2: 0, x: 100, y: 0),
            .lineTo(50, 80),
            .curveTo(x1: 50, y1: 80, x2: 0, y2: 20, x: 0, y: 0),
            .closePath,
        ])
        let twins = closedPathTwins(got)
        #expect(twins.count == 1 && twins[0] == (0, 3))
    }

    /// CONTROL: an OPEN path's start has no in-handle, and nothing is inserted.
    @Test func convertingTheStartOfAnOpenPathInsertsNothing() {
        #expect(convertCornerToSmooth([.moveTo(0, 0), .lineTo(100, 0)], anchorIdx: 0, hx: 0, hy: -20)
                == [.moveTo(0, 0), .curveTo(x1: 0, y1: -20, x2: 100, y2: 0, x: 100, y: 0)])
    }

    @Test func draggingTheStartsInHandleMovesTheClosingX2() {
        var want = penClosed
        want[2] = .curveTo(x1: 110, y1: 50, x2: -5, y2: 50, x: 0, y: 0)
        #expect(movePathHandleIndependent(penClosed, anchorIdx: 0, handleType: "in", dx: 5, dy: 0) == want)
    }

    @Test func draggingTheTwinsOutHandleMovesTheFirstX1() {
        var want = penClosed
        want[1] = .curveTo(x1: 10, y1: -5, x2: 90, y2: -10, x: 100, y: 0)
        #expect(movePathHandleIndependent(penClosed, anchorIdx: 2, handleType: "out", dx: 0, dy: 5) == want)
    }

    @Test func aSmoothDragOfTheStartsInHandleRotatesItsOutHandle() {
        let got = movePathHandle(penClosed, anchorIdx: 0, handleType: "in", dx: -40, dy: -50)
        guard case .curveTo(_, _, let x2, let y2, _, _) = got[2],
              case .curveTo(let x1, let y1, _, _, _, _) = got[1] else {
            Issue.record("shape changed: \(got)")
            return
        }
        #expect(x2 == -50 && y2 == 0)
        #expect(abs(x1 - 200.0.squareRoot()) < 1e-9 && abs(y1) < 1e-9, "(\(x1), \(y1))")
    }
}
