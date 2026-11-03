import CoreGraphics

/// A cubic bezier from the previous segment's end (or the contour's start).
struct LottieSegment {
    var c1: CGPoint
    var c2: CGPoint
    var end: CGPoint

    func point(at t: Double, from start: CGPoint) -> CGPoint {
        let u = 1 - t
        let a = u * u * u, b = 3 * u * u * t, c = 3 * u * t * t, d = t * t * t
        return CGPoint(x: a * start.x + b * c1.x + c * c2.x + d * end.x, y: a * start.y + b * c1.y + c * c2.y + d * end.y)
    }

    /// rlottie's `VBezier::length`: the control polygon's length once it is within 0.01 of the chord, splitting in
    /// halves until then, with rlottie's approximate distances (`rlottieLength`).
    func length(from start: CGPoint) -> Double {
        let polygon = start.rlottieLength(to: c1) + c1.rlottieLength(to: c2) + c2.rlottieLength(to: end)
        let chord = start.rlottieLength(to: end)
        guard polygon - chord > 0.01 else { return polygon }
        let (left, right) = split(at: 0.5, start: start)
        return left.length(from: start) + right.segment.length(from: right.start)
    }

    /// rlottie's `VBezier::tAtLength`: its search until the part before `t` is within 0.01 of `length`, which can
    /// take around 100 steps; rlottie has no limit, the cap only guards against looping forever. Even a line doesn't
    /// move at a constant speed in `t`, since its handles sit on its ends.
    func t(atLength length: Double, from start: CGPoint) -> Double {
        let total = self.length(from: start)
        if length >= total || abs(length - total) < 1e-6 { return 1 }
        var t = 0.5
        var lastBigger = 1.0
        for _ in 0 ..< 1000 {
            let (left, _) = split(at: t, start: start)
            let leftLength = left.length(from: start)
            if abs(leftLength - length) < 0.01 { break }
            if leftLength < length {
                t += (lastBigger - t) * 0.5
            } else {
                lastBigger = t
                t -= t * 0.5
            }
        }
        return t
    }

    /// The part of the segment between `t0` and `t1`.
    func slice(from t0: Double, to t1: Double, start: CGPoint) -> (start: CGPoint, segment: LottieSegment) {
        let (head, _) = split(at: t1, start: start)
        guard t1 > 0 else { return (start, LottieSegment(c1: start, c2: start, end: start)) }
        let (_, tail) = head.split(at: t0 / t1, start: start)
        return tail
    }

    /// De Casteljau's split into the parts before and after `t`.
    func split(at t: Double, start: CGPoint) -> (LottieSegment, (start: CGPoint, segment: LottieSegment)) {
        let p01 = start.mix(c1, t), p12 = c1.mix(c2, t), p23 = c2.mix(end, t)
        let p012 = p01.mix(p12, t), p123 = p12.mix(p23, t)
        let mid = p012.mix(p123, t)
        return (LottieSegment(c1: p01, c2: p012, end: mid), (mid, LottieSegment(c1: p123, c2: p23, end: end)))
    }
}

struct LottieContour {
    var start: CGPoint
    var segments: [LottieSegment] = []
    var closed: Bool

    static func line(_ points: [CGPoint], closed: Bool) -> LottieContour {
        var contour = LottieContour(start: points[0], closed: closed)
        var previous = points[0]
        for point in points.dropFirst() + (closed ? [points[0]] : []) {
            contour.segments.append(LottieSegment(c1: previous, c2: point, end: point))
            previous = point
        }
        return contour
    }
}

typealias LottiePath = [LottieContour]

extension [LottieContour] {
    func cgPath(transform: CGAffineTransform) -> CGPath {
        let path = CGMutablePath()
        for contour in self {
            path.move(to: contour.start, transform: transform)
            var previous = contour.start
            for segment in contour.segments {
                if segment.c1 == previous, segment.c2 == segment.end {
                    path.addLine(to: segment.end, transform: transform)
                } else {
                    path.addCurve(to: segment.end, control1: segment.c1, control2: segment.c2, transform: transform)
                }
                previous = segment.end
            }
            if contour.closed {
                path.closeSubpath()
            }
        }
        return path
    }

    var length: Double {
        reduce(0) { total, contour in
            var previous = contour.start
            return total + contour.segments.reduce(0) { sum, segment in
                defer { previous = segment.end }
                return sum + segment.length(from: previous)
            }
        }
    }

    /// The part between `from` and `to` (lengths along the whole path), as open contours.
    func extract(from: Double, to: Double) -> LottiePath {
        guard to > from else { return [] }
        var result: LottiePath = []
        var travelled = 0.0
        for contour in self {
            var piece: LottieContour?
            var previous = contour.start
            for segment in contour.segments {
                let length = segment.length(from: previous)
                let segmentStart = travelled, segmentEnd = travelled + length
                defer {
                    travelled = segmentEnd
                    previous = segment.end
                }
                guard segmentEnd > from, segmentStart < to, length > 0 else { continue }
                let t0 = from > segmentStart ? segment.t(atLength: from - segmentStart, from: previous) : 0
                let t1 = to < segmentEnd ? segment.t(atLength: to - segmentStart, from: previous) : 1
                let sliced = (t0 == 0 && t1 == 1) ? (previous, segment) : segment.slice(from: t0, to: t1, start: previous)
                if piece == nil {
                    piece = LottieContour(start: sliced.0, closed: false)
                }
                piece?.segments.append(sliced.1)
            }
            if let piece {
                result.append(piece)
            }
        }
        return result
    }

    /// rlottie's trim: `start < end` keeps that stretch; `start > end` wraps, keeping `[0, end]` and `[start, 1]`.
    func trimmed(start: Double, end: Double) -> LottiePath {
        if abs(start - end) < 1e-6 { return [] }
        if (start < 1e-6 && end > 1 - 1e-6) || (start > 1 - 1e-6 && end < 1e-6) { return self }
        let length = length
        if start < end {
            return extract(from: start * length, to: end * length)
        }
        return extract(from: 0, to: end * length) + extract(from: start * length, to: length)
    }
}

extension CGPoint {
    static func + (lhs: CGPoint, rhs: CGPoint) -> CGPoint {
        CGPoint(x: lhs.x + rhs.x, y: lhs.y + rhs.y)
    }

    func distance(to other: CGPoint) -> Double {
        hypot(other.x - x, other.y - y)
    }

    /// rlottie's `VLine::length`, which measures every path, trim and motion path: the "alpha max plus beta min"
    /// estimate of the distance, `max + 3/8 min`, up to about 7 % long. Motion along a curve and trims depend on it, so
    /// they use it too to match Telegram.
    func rlottieLength(to other: CGPoint) -> Double {
        let dx = abs(other.x - x), dy = abs(other.y - y)
        return dx > dy ? dx + 0.375 * dy : dy + 0.375 * dx
    }

    func mix(_ other: CGPoint, _ t: Double) -> CGPoint {
        CGPoint(x: x + (other.x - x) * t, y: y + (other.y - y) * t)
    }
}
