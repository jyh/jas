import UIKit

// BezierShape is a graphics element represented by a BezierCurve.
// It can be stroked, filled, closed or not closed.
class BezierShape : Shape {
    var curve : BezierCurve
    var stroke : Stroke?
    var fill : CGColor?
    var path : UIBezierPath?
    var isClosed = false
    
    // Fith the path to a sequence of points.
    init(points : [CGPoint], error : CGFloat) {
        curve = BezierCurve(points: points, error: error)
    }

    init(shape: BezierShape) {
        self.curve = shape.curve
        self.stroke = shape.stroke
        self.fill = shape.fill
        self.isClosed = false
    }

    // updatePath computes the BezierPath.
    func updatePath() -> UIBezierPath {
        if path != nil {
            return path!
        }
        let p = UIBezierPath()
        self.path = p
        if curve.segments.count == 0 {
            return p
        }
        p.move(to: curve.segments[0].p1)
        for s in curve.segments[1..<curve.segments.count] {
            p.addCurve(to: s.p2, controlPoint1: s.control1, controlPoint2: s.control2)
        }
        if isClosed {
            p.close()
        }
        return p
    }
    
    // setContext sets the graphics context.
    func setContext() {
        let context = UIGraphicsGetCurrentContext()
        if fill != nil {
            context?.setFillColor(fill!)
        }
        if stroke != nil {
            stroke!.setContext()
        }
    }
    
    // drawRect draws the shape if it overlaps with the rectangle.
    func drawRect(_ rect : CGRect) {
        if !curve.mayIntersect(fill != nil, rect: rect.Grow(strokeWidth())) {
            return
        }
        self.setContext()
        let p = updatePath()
        if fill != nil {
            p.fill()
        }
        if stroke != nil {
            let s = stroke!
            p.lineWidth = s.width
            p.lineCapStyle = s.cap
            p.lineJoinStyle = s.join
            if s.miterLimit != 0 {
                p.miterLimit = s.miterLimit
            }
            p.stroke()
        }
    }
    
    // strokeWidth returns the stroke width, if any.
    func strokeWidth() -> CGFloat {
        return stroke == nil ? 0 : stroke!.width
    }

    // boundingBox returns the bounding box of the shape.
    func boundingBox() -> CGRect {
        return curve.boundingBox().Grow(strokeWidth())
    }

    // apply the transform to the shape.
    func applyTransform(_ t : CGAffineTransform) -> Shape {
        let shape = BezierShape(shape: self)
        shape.curve = curve.applyTransform(t)
        return shape
    }

    // Select returns a selection, if any.
    func select(_ p : CGPoint) -> Selection? {
        return nil
    }
}

// BezierCurve represents a cubic bezier curve.
class BezierCurve {
    // segments holds the segments in the curve.
    var segments : [BezierSegment]

    // Fit the curve to a sequence of points.
    init(points : [CGPoint], error : CGFloat) {
        let fitter = FitCurve()
        fitter.FitCurve(points, error: error)
        self.segments = fitter.segments
    }

    init(segments : [BezierSegment]) {
        self.segments = segments
    }

    // mayIntersect returns true if the segment might intersect with the rectangle.
    // This is approximate, we use the points to determine a boounding box,
    // and return true iff the convex hull intersects with the rectangle.
    func mayIntersect(_ isFilled : Bool, rect : CGRect) -> Bool {
        if isFilled {
            return self.boundingBox().Intersects(rect)
        }
        for segment in segments {
            if segment.mayIntersect(rect) {
                return true
            }
        }
        return false
    }

    // boundbox returns the bounding box for the content.
    func boundingBox() -> CGRect {
        if segments.count == 0 {
            return CGRect()
        }
        var bb = segments[0].boundingBox()
        for segment in segments {
            bb = bb.Union(segment.boundingBox())
        }
        return bb
    }

    // apply the transform to the shape.
    func applyTransform(_ t : CGAffineTransform) -> BezierCurve {
        var newSegments : [BezierSegment] = []
        newSegments.reserveCapacity(segments.count)
        for i in 0..<segments.count {
                         newSegments.append(segments[i].applyTransform(t))
        }
        return BezierCurve(segments: newSegments)
    }
}

// A BezierSegment is one segment of a cubic bezier curve.
struct BezierSegment {
    let p1 : CGPoint
    let control1 : CGPoint
    let control2 : CGPoint
    let p2 : CGPoint
    
    init(V : [Point2]) {
        self.p1 = V[0]
        self.control1 = V[1]
        self.control2 = V[2]
        self.p2 = V[3]
    }

    init(p1 : CGPoint, control1 : CGPoint, control2 : CGPoint, p2 : CGPoint) {
        self.p1 = p1
        self.control1 = control1
        self.control2 = control2
        self.p2 = p2
    }

    // MayIntersect returns true if the segment might intersect with the rectangle.
    // This is approximate, we use the points to determine a boounding box,
    // and return true iff the convex hull intersects with the rectangle.
    func mayIntersect(_ rect : CGRect) -> Bool {
        return rect.Intersects(self.boundingBox())
    }

    func boundingBox() -> CGRect {
        return DrawingExample.BoundingBox(p1, control1, control2, p2)
    }

    func applyTransform(_ t : CGAffineTransform) -> BezierSegment {
        return BezierSegment(
                p1 : p1.applying(t),
                control1: control1.applying(t),
                control2: control2.applying(t),
                p2: p2.applying(t))
    }

    // Find the zeros.  Appends the x-values to the result.
    func zeros(_ result : [CGFloat]) {
        // Degenerate cases.
        if (p1.y > 0 && control1.y > 0 && control2.y > 0 && p2.y > 0
            || p1.y > 0 && control1.y < 0 && control2.y < 0 && p2.y < 0) {
           return
        }
    }
}

////////////////////////////////////////////////////////////////////////
// The rest is the internal implementation.
//
// The algporithm for Bezier extraction is taken from Graphics Gems I, "An
// Algorithm for Automatically Futting Digitized Curves," Phillip J. Schneider,
// University of Geneva, 1995.

// Point2 and Vector2 are aliases for CGPoint.
typealias Point2 = CGPoint
typealias Vector2 = Point2

// Point2 has additional methods for computing distances.
extension Point2 {
    func Negate() -> Point2 {
        return Point2(x : -self.x, y : -self.y)
    }
    
    func Add(_ p : Vector2) -> Vector2 {
        return Vector2(x: self.x + p.x, y: self.y + p.y)
    }
    
    func Sub(_ p : Vector2) -> Vector2 {
        return Vector2(x: self.x - p.x, y: self.y - p.y)
    }
    
    func Scale(_ s : CGFloat) -> Vector2 {
        return Vector2(x: self.x * s, y: self.y * s)
    }
    
    func SquaredLength() -> CGFloat {
        return self.x * self.x + self.y * self.y
    }
    
    func Length() -> CGFloat {
        return sqrt(self.SquaredLength())
    }
    
    func Normalize() -> Vector2 {
        let len = self.Length()
        if len == 0 {
            return self
        }
        return Vector2(x : self.x / len, y : self.y / len)
    }
    
    func DistanceBetween(_ p : Point2) -> CGFloat {
        let dx = self.x - p.x
        let dy = self.y - p.y
        return sqrt((dx * dx) + (dy * dy))
    }
    
    func Dot(_ p : Vector2) -> CGFloat {
        return (self.x * p.x) + (self.y * p.y)
    }
}

// BezierSegmentPoints is used only internally as an array of four points,
// [p1, control1, control2, p2].
typealias BezierSegmentPoints = [Point2]

// FitCurve performs the actual fitting.
class FitCurve {
    // Max number of iterations for reparameterize loop.
    let maxIterations = 4
    
    // Output curve.
    var segments : [BezierSegment] = []
    
    func add(_ c : BezierSegmentPoints) {
        segments.append(BezierSegment(V: c))
    }
    
    //  FitCurve : Fit a Bezier curve to a set of digitized points.
    func FitCurve(_ d : [Point2], error : CGFloat) {
        let tHat1 = ComputeLeftTangent(d, end: 0)
        let tHat2 = ComputeRightTangent(d, end: d.count - 1)
        FitCubic(d, first: 0, last: d.count - 1, tHat1: tHat1, tHat2: tHat2, error: error)
    }
    
    //  FitCubic : Fit a Bezier curve to a (sub)set of digitized points.
    //
    //  d                   /*  Array of digitized points */
    //  first, last         /* Indices of first and last pts in region */
    //  tHat1, tHat2        /* Unit tangent vectors at endpoints */
    //  double error        /*  User-defined error squared     */
    func FitCubic(_ d : [Point2], first : Int, last : Int, tHat1 : Vector2, tHat2 : Vector2, error : CGFloat) {
        let iterationError = error * error;
        let nPts = last - first + 1
        
        //  Use heuristic if region only has two points in it.
        if nPts == 2 {
            let dist = d[last].DistanceBetween(d[first]) / 3.0
            let bezCurve = [
                d[first],
                d[first].Add(tHat1.Scale(dist)),
                d[last].Add(tHat2.Scale(dist)),
                d[last],
            ]
            add(bezCurve)
            return
        }
        
        // Parameterize points, and attempt to fit curve.
        var u = ChordLengthParameterize(d, first: first, last: last)
        var bezCurve = GenerateBezier(d, first: first, last: last, uPrime: u, tHat1: tHat1, tHat2: tHat2)
        
        // Find max deviation of points to fitted curve.
        var (maxError, splitPoint) = ComputeMaxError(d, first: first, last: last, bezCurve: bezCurve, u: u)
        if maxError < error {
            add(bezCurve)
            return
        }
        
        
        // If error not too large, try some reparameterization and iteration.
        if maxError < iterationError {
            for _ in 0..<maxIterations {
                let uPrime = Reparameterize(d, first: first, last: last, u: u, bezCurve: bezCurve)
                bezCurve = GenerateBezier(d, first: first, last: last, uPrime: uPrime, tHat1: tHat1, tHat2: tHat2)
                (maxError, splitPoint) = ComputeMaxError(d, first: first, last: last, bezCurve: bezCurve, u: uPrime)
                if maxError < error {
                    add(bezCurve)
                    return
                }
                u = uPrime
            }
        }
        
        // Fitting failed -- split at max error point and fit recursively.
        var tHatCenter = ComputeCenterTangent(d, center: splitPoint)
        FitCubic(d, first: first, last: splitPoint, tHat1: tHat1, tHat2: tHatCenter, error: error)
        tHatCenter = tHatCenter.Negate()
        FitCubic(d, first: splitPoint, last: last, tHat1: tHatCenter, tHat2: tHat2, error: error)
    }
    
    //  GenerateBezier :  Use least-squares method to find Bezier control points for region.
    //
    //  d                   /*  Array of digitized points   */
    //  first, last         /*  Indices defining region     */
    //  uPrime              /*  Parameter values for region */
    //  tHat1, tHat2        /*  Unit tangents at endpoints  */
    func GenerateBezier(_ d : [Point2], first : Int, last : Int, uPrime : [CGFloat], tHat1 : Vector2, tHat2 : Vector2) -> BezierSegmentPoints {
        let nPts = last - first + 1
        
        // Compute the A's
        var A : [[Vector2]] = []
        for i in 0..<nPts {
            A.append([tHat1.Scale(B1(uPrime[i])), tHat2.Scale(B2(uPrime[i]))])
        }
        
        // Create the C and X matrices
        var X : [CGFloat] = [0, 0]
        var C : [[CGFloat]] = [X, X]
        
        for i in 0..<nPts {
            C[0][0] += A[i][0].Dot(A[i][0])
            C[0][1] += A[i][0].Dot(A[i][1])
            C[1][0] = C[0][1]
            C[1][1] += A[i][1].Dot(A[i][1])
            let tmp = d[first + i].Sub(
                d[first].Scale(B0(uPrime[i])).Add(
                    d[first].Scale(B1(uPrime[i])).Add(
                        d[last].Scale(B2(uPrime[i])).Add(
                            d[last].Scale(B3(uPrime[i]))))))
            X[0] += A[i][0].Dot(tmp)
            X[1] += A[i][1].Dot(tmp)
        }
        
        // Compute the determinants of C and X
        let det_C0_C1 = C[0][0] * C[1][1] - C[1][0] * C[0][1]
        let det_C0_X  = C[0][0] * X[1]    - C[1][0] * X[0]
        let det_X_C1  = X[0]    * C[1][1] - X[1]    * C[0][1]
        
        // Finally, derive alpha values
        let alpha_l = (det_C0_C1 == 0) ? 0.0 : det_X_C1 / det_C0_C1
        let alpha_r = (det_C0_C1 == 0) ? 0.0 : det_C0_X / det_C0_C1
        
        // If alpha negative, use the Wu/Barsky heuristic (see text)
        // (if alpha is 0, you get coincident control points that lead to
        // divide by zero in any subsequent NewtonRaphsonRootFind() call.
        let segLength = d[last].DistanceBetween(d[first])
        let epsilon = 1.0e-6 * segLength
        if alpha_l < epsilon || alpha_r < epsilon {
            // fall back on standard (probably inaccurate) formula, and subdivide further if needed.
            let dist = segLength / 3.0
            return [
                d[first],
                d[first].Add(tHat1.Scale(dist)),
                d[last].Add(tHat2.Scale(dist)),
                d[last],
            ]
        }
        
        //  First and last control points of the Bezier curve are
        //  positioned exactly at the first and last data points
        //  Control points 1 and 2 are positioned an alpha distance out
        //  on the tangent vectors, left and right, respectively.
        return [
            d[first],
            d[first].Add(tHat1.Scale(alpha_l)),
            d[last].Add(tHat2.Scale(alpha_r)),
            d[last],
        ]
    }
    
    // Reparameterize: Given set of points and their parameterization, try to find
    //   a better parameterization.
    //    d                 /*  Array of digitized points   */
    //    first, last       /*  Indices defining region     */
    //    u                 /*  Current parameter values    */
    //    bezCurve          /*  Current fitted curve        */
    func Reparameterize(_ d : [Point2], first : Int, last : Int, u : [CGFloat], bezCurve : BezierSegmentPoints) -> [CGFloat] {
        let         nPts = last-first+1;
        var uPrime = [CGFloat](repeating: 0.0, count: nPts)
        for i in first...last {
            uPrime[i-first] = NewtonRaphsonRootFind(bezCurve, P: d[i], u: u[i-first])
        }
        return uPrime
    }
    
    // NewtonRaphsonRootFind uses Newton-Raphson iteration to find better root.
    //    BezierSegmentPoints       Q               /*  Current fitted curve        */
    //    Point2            P               /*  Digitized point             */
    //    double            u               /*  Parameter value for "P"     */
    func NewtonRaphsonRootFind(_ Q : BezierSegmentPoints, P : Point2, u : CGFloat) -> CGFloat {
        // Compute Q(u)
        let Q_u = BezierII(3, V: Q, t: u)
        
        // Generate control vertices for Q'
        let Q1 = [
            Point2(x: (Q[1].x - Q[0].x) * 3, y: (Q[1].y - Q[0].y) * 3),
            Point2(x: (Q[2].x - Q[1].x) * 3, y: (Q[2].y - Q[1].y) * 3),
            Point2(x: (Q[3].x - Q[2].x) * 3, y: (Q[3].y - Q[2].y) * 3),
        ]
        
        // Generate control vertices for Q''
        let Q2 = [
            Point2(x: (Q1[1].x - Q1[0].x) * 2, y: (Q1[1].y - Q1[0].y) * 2),
            Point2(x: (Q1[2].x - Q1[1].x) * 2, y: (Q1[2].y - Q1[1].y) * 2),
        ]
        
        // Compute Q'(u) and Q''(u)
        let Q1_u = BezierII(2, V: Q1, t: u)
        let Q2_u = BezierII(1, V: Q2, t: u)
        
        // Compute f(u)/f'(u)
        let numerator = (Q_u.x - P.x) * (Q1_u.x) + (Q_u.y - P.y) * (Q1_u.y)
        let denominator = (Q1_u.x) * (Q1_u.x) + (Q1_u.y) * (Q1_u.y) +
            (Q_u.x - P.x) * (Q2_u.x) + (Q_u.y - P.y) * (Q2_u.y)
        if denominator == 0 {
            return u
        }
        
        // u - f(u)/f'(u)
        return u - (numerator/denominator)
    }
    
    //  Bezier evaluates a Bezier curve at a particular parameter value.
    //
    //  degree : the degree of the bezier curve
    //  V : array of control points
    //  t : parametric value to find point for
    func BezierII(_ degree : Int, V : [Point2], t : CGFloat) -> Point2 {
        var Vtemp = V
        for i in 1...degree {
            for j in 0 ... degree - i {
                Vtemp[j].x = (1.0 - t) * Vtemp[j].x + t * Vtemp[j+1].x
                Vtemp[j].y = (1.0 - t) * Vtemp[j].y + t * Vtemp[j+1].y
            }
        }
        
        return Vtemp[0]
    }
    
    //  ComputeMaxError finds the maximum squared distance of digitized points to
    //  fitted curve.
    //
    //  d : Array of digitized points
    //  first, last : indexes of the region
    //  bezCurve : fitted Bezier curve
    //  u : parameterization of pointer
    //
    // Returns: (maxDist, splitPoint)
    //
    //   maxDist : maximum squared distance
    //   splitPoint : point of maximum error
    func ComputeMaxError(_ d : [Point2], first : Int, last : Int, bezCurve : BezierSegmentPoints, u : [CGFloat]) -> (CGFloat, Int) {
        var splitPoint = (last - first + 1) / 2
        var maxDist : CGFloat = 0.0
        
        for i in (first + 1) ..< last {
            let P = BezierII(3, V: bezCurve, t: u[i-first])
            let v = P.Sub(d[i])
            let dist = v.SquaredLength()
            if dist >= maxDist {
                maxDist = dist
                splitPoint = i
            }
        }
        return (maxDist, splitPoint)
    }
    
    // ChordLengthParameterize assigsn parameter values to digitized points using
    // relative distances between points.
    func ChordLengthParameterize(_ d : [Point2], first : Int, last : Int) -> [CGFloat] {
        var u = [CGFloat](repeating: 0.0, count: last - first + 1)
        for i in (first + 1)...last {
            u[i-first] = u[i-first-1] + d[i].DistanceBetween(d[i-1])
        }
        for i in (first + 1)...last {
            u[i-first] = u[i-first] / u[last-first]
        }
        return u
    }
    
    // ComputeLeftTangent approximates the unit tangent at the left endpoint.
    func ComputeLeftTangent(_ d : [Point2], end : Int) -> Vector2 {
        return d[end+1].Sub(d[end]).Normalize()
    }
    
    // ComputeRightTangent approximates the unit tangent at the left endpoint.
    func ComputeRightTangent(_ d : [Point2], end : Int) -> Vector2 {
        return d[end-1].Sub(d[end]).Normalize()
    }
    
    // ComputeCenterTangent approximates the unit tangent at the center.
    func ComputeCenterTangent(_ d : [Point2], center : Int) -> Vector2 {
        let V1 = d[center-1].Sub(d[center])
        let V2 = d[center].Sub(d[center+1])
        return Vector2(x : (V1.x + V2.x) / 2, y : (V1.y + V2.y) / 2).Normalize()
    }
    
    // Bezier multipliers.
    func B0(_ u : CGFloat) -> CGFloat {
        let tmp = 1 - u
        return tmp * tmp * tmp
    }
    
    func B1(_ u : CGFloat) -> CGFloat {
        let tmp = 1 - u
        return 3 * u * tmp * tmp
    }
    
    func B2(_ u : CGFloat) -> CGFloat {
        let tmp = 1 - u
        return 3 * u * u * tmp
    }
    
    func B3(_ u : CGFloat) -> CGFloat {
        return u * u * u
    }
}
