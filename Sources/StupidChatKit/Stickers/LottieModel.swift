import CoreGraphics
import Foundation

/// A Lottie animation as Telegram's animated stickers (TGS, gzipped Lottie JSON) use it, parsed for `LottieRenderer`.
///
/// It reads what rlottie, Telegram's renderer, reads, and leaves out what rlottie leaves out (skew, merge paths,
/// expressions, effects, masks, text and images), so stickers look as they do in Telegram. `scripts/lottie-census.py`
/// counts which features stickers use; `scripts/lottie-compare.py` compares frames with rlottie's.
public final class LottieAnimation: @unchecked Sendable {
    public enum ParseError: Error {
        case notGzip
        case invalidJSON
        case missingField(String)
    }

    public let size: CGSize
    public let frameRate: Double
    public let inFrame: Double
    public let outFrame: Double
    let layers: [LottieLayer]
    let assets: [String: [LottieLayer]]

    /// The number of frames, as rlottie counts them (`op - ip`).
    public var frameCount: Int {
        max(Int(outFrame - inFrame), 1)
    }

    public var duration: Double {
        Double(frameCount) / frameRate
    }

    /// A TGS file: gzipped Lottie JSON.
    public convenience init(tgs data: Data) throws {
        try self.init(json: LottieAnimation.gunzip(data))
    }

    public init(json data: Data) throws {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw ParseError.invalidJSON }
        guard let width = root.double("w"), let height = root.double("h") else { throw ParseError.missingField("w/h") }
        size = CGSize(width: width, height: height)
        frameRate = max(root.double("fr") ?? 60, 1)
        inFrame = root.double("ip") ?? 0
        outFrame = root.double("op") ?? 0
        layers = (root["layers"] as? [[String: Any]] ?? []).compactMap(LottieLayer.init)
        var assets: [String: [LottieLayer]] = [:]
        for asset in root["assets"] as? [[String: Any]] ?? [] {
            if let id = asset["id"] as? String, let layers = asset["layers"] as? [[String: Any]] {
                assets[id] = layers.compactMap(LottieLayer.init)
            }
        }
        self.assets = assets
    }

    /// Gzip's header and trailer around raw deflate, which `NSData` inflates.
    static func gunzip(_ data: Data) throws -> Data {
        let bytes = [UInt8](data)
        guard bytes.count > 18, bytes[0] == 0x1F, bytes[1] == 0x8B, bytes[2] == 8 else { throw ParseError.notGzip }
        let flags = bytes[3]
        var offset = 10
        if flags & 0x04 != 0 {
            guard offset + 2 <= bytes.count else { throw ParseError.notGzip }
            offset += 2 + Int(bytes[offset]) + Int(bytes[offset + 1]) << 8
        }
        for flag: UInt8 in [0x08, 0x10] where flags & flag != 0 {
            while offset < bytes.count, bytes[offset] != 0 {
                offset += 1
            }
            offset += 1
        }
        if flags & 0x02 != 0 {
            offset += 2
        }
        guard offset < bytes.count - 8 else { throw ParseError.notGzip }
        let deflated = data.subdata(in: data.startIndex + offset ..< data.endIndex - 8)
        guard let inflated = try? (deflated as NSData).decompressed(using: .zlib) else { throw ParseError.notGzip }
        return inflated as Data
    }
}

// MARK: - Animated values

/// A cubic-bezier easing from `(0, 0)` to `(1, 1)`, as a keyframe's `o` and `i` handles give it.
struct LottieEasing {
    let x1, y1, x2, y2: Double

    func progress(_ x: Double) -> Double {
        if x <= 0 { return 0 }
        if x >= 1 { return 1 }
        if x1 == y1, x2 == y2 { return x }
        // Newton's method on x(t), falling back to bisection.
        var t = x
        for _ in 0 ..< 8 {
            let error = sample(t, x1, x2) - x
            if abs(error) < 1e-6 { return sample(t, y1, y2) }
            let slope = slope(t, x1, x2)
            if abs(slope) < 1e-6 { break }
            t -= error / slope
        }
        var low = 0.0, high = 1.0
        t = x
        for _ in 0 ..< 30 {
            let value = sample(t, x1, x2)
            if abs(value - x) < 1e-6 { break }
            if value < x { low = t } else { high = t }
            t = (low + high) / 2
        }
        return sample(t, y1, y2)
    }

    private func sample(_ t: Double, _ p1: Double, _ p2: Double) -> Double {
        let u = 1 - t
        return 3 * u * u * t * p1 + 3 * u * t * t * p2 + t * t * t
    }

    private func slope(_ t: Double, _ p1: Double, _ p2: Double) -> Double {
        let u = 1 - t
        return 3 * u * u * p1 + 6 * u * t * (p2 - p1) + 3 * t * t * (1 - p2)
    }
}

protocol LottieInterpolatable {
    static func lerp(_ from: Self, _ to: Self, _ t: Double) -> Self
}

extension [Double]: LottieInterpolatable {
    static func lerp(_ from: [Double], _ to: [Double], _ t: Double) -> [Double] {
        guard from.count == to.count else { return t < 1 ? from : to }
        return zip(from, to).map { $0 + ($1 - $0) * t }
    }
}

/// One shape's points: vertices with in and out tangents relative to them.
struct LottiePathData: LottieInterpolatable {
    var closed: Bool
    var vertices: [CGPoint]
    var inTangents: [CGPoint]
    var outTangents: [CGPoint]

    /// Point by point; with different counts, the longer path is cut to the shorter, as Telegram's rlottie does.
    static func lerp(_ from: LottiePathData, _ to: LottiePathData, _ t: Double) -> LottiePathData {
        func mix(_ a: [CGPoint], _ b: [CGPoint]) -> [CGPoint] {
            zip(a, b).map { CGPoint(x: $0.x + ($1.x - $0.x) * t, y: $0.y + ($1.y - $0.y) * t) }
        }
        return LottiePathData(closed: from.closed, vertices: mix(from.vertices, to.vertices), inTangents: mix(from.inTangents, to.inTangents), outTangents: mix(from.outTangents, to.outTangents))
    }

    init(closed: Bool, vertices: [CGPoint], inTangents: [CGPoint], outTangents: [CGPoint]) {
        self.closed = closed
        self.vertices = vertices
        self.inTangents = inTangents
        self.outTangents = outTangents
    }

    init?(_ json: Any?) {
        // Keyframed shapes wrap the shape in a one-element array.
        let object = (json as? [String: Any]) ?? ((json as? [Any])?.first as? [String: Any])
        guard let object else { return nil }
        func points(_ key: String) -> [CGPoint] {
            (object[key] as? [[Any]] ?? []).map { pair in
                CGPoint(x: (pair.first as? NSNumber)?.doubleValue ?? 0, y: (pair.count > 1 ? (pair[1] as? NSNumber)?.doubleValue : nil) ?? 0)
            }
        }
        closed = object["c"] as? Bool ?? false
        vertices = points("v")
        inTangents = points("i")
        outTangents = points("o")
    }

    /// The bezier contour rlottie builds: a cubic per vertex pair, and a closing one when closed.
    var path: LottiePath {
        guard let first = vertices.first else { return [] }
        func tangent(_ list: [CGPoint], _ index: Int) -> CGPoint {
            index < list.count ? list[index] : .zero
        }
        var contour = LottieContour(start: first, closed: closed)
        for index in vertices.indices.dropFirst() {
            let previous = vertices[index - 1]
            contour.segments.append(LottieSegment(
                c1: previous + tangent(outTangents, index - 1),
                c2: vertices[index] + tangent(inTangents, index),
                end: vertices[index],
            ))
        }
        if closed, let last = vertices.last {
            contour.segments.append(LottieSegment(c1: last + tangent(outTangents, vertices.count - 1), c2: first + tangent(inTangents, 0), end: first))
        }
        return [contour]
    }
}

/// A point keyframe's path: from the start value along `start + out` and `end + in`, travelled at a constant speed
/// (by arc length), as rlottie moves it.
struct LottieSpatialCurve {
    let segment: LottieSegment
    let start: CGPoint
    let length: Double

    init?(from: [Double], to: [Double], outTangent: [Double], inTangent: [Double]) {
        guard from.count >= 2, to.count >= 2 else { return nil }
        let start = CGPoint(x: from[0], y: from[1])
        let end = CGPoint(x: to[0], y: to[1])
        let out = CGPoint(x: outTangent.first ?? 0, y: outTangent.count > 1 ? outTangent[1] : 0)
        let `in` = CGPoint(x: inTangent.first ?? 0, y: inTangent.count > 1 ? inTangent[1] : 0)
        segment = LottieSegment(c1: start + out, c2: end + `in`, end: end)
        self.start = start
        length = segment.length(from: start)
        if length < 1e-4 { return nil }
    }

    func point(at progress: Double) -> [Double] {
        let t = segment.t(atLength: progress * length, from: start)
        let point = segment.point(at: t, from: start)
        return [point.x, point.y]
    }
}

struct LottieKeyframe<Value: LottieInterpolatable> {
    var start: Double
    var end: Double
    var from: Value
    var to: Value
    /// `nil` holds `from` until the next keyframe.
    var easing: LottieEasing?
    var spatial: LottieSpatialCurve?

    func value(at frame: Double) -> Value {
        guard let easing, end > start else { return from }
        let progress = easing.progress((frame - start) / (end - start))
        if let spatial, let point = spatial.point(at: progress) as? Value {
            return point
        }
        return Value.lerp(from, to, progress)
    }
}

/// A property that is fixed or animated by keyframes, evaluated as rlottie does: before the first keyframe its start
/// value, after the last its end value.
enum LottieProperty<Value: LottieInterpolatable> {
    case fixed(Value)
    case animated([LottieKeyframe<Value>])

    func value(at frame: Double) -> Value {
        switch self {
        case let .fixed(value):
            return value
        case let .animated(keyframes):
            guard let first = keyframes.first, let last = keyframes.last else { fatalError("animated property without keyframes") }
            if first.start >= frame { return first.from }
            if last.end <= frame { return last.to }
            for keyframe in keyframes where frame >= keyframe.start && frame < keyframe.end {
                return keyframe.value(at: frame)
            }
            return last.to
        }
    }

    var isAnimated: Bool {
        if case .animated = self { true } else { false }
    }
}

extension LottieProperty where Value == [Double] {
    /// A number or vector property (`{"a": 0, "k": …}`), or `fallback` when absent. Two-dimensional keyframes with
    /// `to`/`ti` handles follow that curve, as in Telegram's rlottie (any point value, not only positions).
    init(_ json: Any?, default fallback: [Double]) {
        guard let object = json as? [String: Any], let k = object["k"] else {
            self = .fixed(fallback)
            return
        }
        if let keyframes = k as? [[String: Any]], !keyframes.isEmpty, keyframes[0]["t"] != nil {
            let parsed = LottieProperty.keyframes(keyframes, value: { $0.map(LottieProperty.numbers) ?? nil }, spatial: true)
            self = parsed.isEmpty ? .fixed(LottieProperty.numbers(keyframes[0]["s"]) ?? fallback) : .animated(parsed)
        } else {
            self = .fixed(LottieProperty.numbers(k) ?? fallback)
        }
    }

    static func numbers(_ json: Any) -> [Double]? {
        if let number = json as? NSNumber { return [number.doubleValue] }
        if let array = json as? [Any] { return array.compactMap { ($0 as? NSNumber)?.doubleValue } }
        return nil
    }

    func scalar(at frame: Double) -> Double {
        value(at: frame).first ?? 0
    }

    func point(at frame: Double) -> CGPoint {
        let value = value(at: frame)
        return CGPoint(x: value.first ?? 0, y: value.count > 1 ? value[1] : 0)
    }
}

extension LottieProperty where Value == LottiePathData {
    init?(path json: Any?) {
        guard let object = json as? [String: Any], let k = object["k"] else { return nil }
        if let keyframes = k as? [[String: Any]], !keyframes.isEmpty, keyframes[0]["t"] != nil {
            let parsed = LottieProperty.keyframes(keyframes, value: { LottiePathData($0) }, spatial: false)
            guard !parsed.isEmpty else {
                guard let value = LottiePathData(keyframes[0]["s"]) else { return nil }
                self = .fixed(value)
                return
            }
            self = .animated(parsed)
        } else {
            guard let value = LottiePathData(k) else { return nil }
            self = .fixed(value)
        }
    }
}

private extension LottieProperty {
    /// rlottie's keyframe list: each keyframe ends where the next starts and, without its own `e`, ends at the next
    /// one's `s`. Hold keyframes (`h: 1`) keep their value; a keyframe without easing (the last) only ends the one
    /// before it. Easing uses each handle's first dimension, as rlottie does.
    static func keyframes(_ list: [[String: Any]], value: (Any?) -> Value?, spatial: Bool) -> [LottieKeyframe<Value>] {
        var result: [LottieKeyframe<Value>] = []
        var spatialTangents: [(out: [Double], in: [Double])?] = []
        for json in list {
            let start = (json["t"] as? NSNumber)?.doubleValue ?? 0
            let from = value(json["s"])
            let explicitEnd = value(json["e"])
            if !result.isEmpty {
                result[result.count - 1].end = start
                // Without `e` (bodymovin 5.5+), the next keyframe's start is this one's end.
                if let from, json["e"] == nil {
                    result[result.count - 1].to = from
                }
            }
            let hold = (json["h"] as? NSNumber)?.intValue == 1
            guard let from else { continue }
            if hold {
                result.append(LottieKeyframe(start: start, end: start, from: from, to: from, easing: nil))
                spatialTangents.append(nil)
            } else if let i = json["i"] as? [String: Any], let o = json["o"] as? [String: Any] {
                func first(_ value: Any?) -> Double {
                    (value as? NSNumber)?.doubleValue ?? ((value as? [Any])?.first as? NSNumber)?.doubleValue ?? 0
                }
                let easing = LottieEasing(x1: first(o["x"]), y1: first(o["y"]), x2: first(i["x"]), y2: first(i["y"]))
                result.append(LottieKeyframe(start: start, end: start, from: from, to: explicitEnd ?? from, easing: easing))
                if spatial, json["to"] != nil || json["ti"] != nil {
                    spatialTangents.append((LottieProperty<[Double]>.numbers(json["to"] ?? []) ?? [], LottieProperty<[Double]>.numbers(json["ti"] ?? []) ?? []))
                } else {
                    spatialTangents.append(nil)
                }
            }
        }
        if spatial {
            for index in result.indices {
                guard let tangents = spatialTangents[index], let from = result[index].from as? [Double], let to = result[index].to as? [Double] else { continue }
                result[index].spatial = LottieSpatialCurve(from: from, to: to, outTangent: tangents.out, inTangent: tangents.in)
            }
        }
        return result
    }
}

// MARK: - Layers and shapes

struct LottieTransform {
    var anchor: LottieProperty<[Double]>
    var position: LottieProperty<[Double]>
    var positionX: LottieProperty<[Double]>?
    var positionY: LottieProperty<[Double]>?
    var scale: LottieProperty<[Double]>
    var rotation: LottieProperty<[Double]>
    var opacity: LottieProperty<[Double]>

    init(_ json: [String: Any]?) {
        let json = json ?? [:]
        anchor = LottieProperty(json["a"], default: [0, 0])
        let p = json["p"] as? [String: Any]
        if p?["s"] as? Bool == true {
            position = .fixed([0, 0])
            positionX = LottieProperty(p?["x"], default: [0])
            positionY = LottieProperty(p?["y"], default: [0])
        } else {
            position = LottieProperty(p, default: [0, 0])
        }
        scale = LottieProperty(json["s"], default: [100, 100])
        rotation = LottieProperty(json["r"] ?? json["rz"], default: [0])
        opacity = LottieProperty(json["o"], default: [100])
    }

    /// rlottie's order: anchor, scale, rotation, position. Skew isn't applied, as in rlottie.
    func matrix(at frame: Double) -> CGAffineTransform {
        let anchor = anchor.point(at: frame)
        let position = if let positionX, let positionY {
            CGPoint(x: positionX.scalar(at: frame), y: positionY.scalar(at: frame))
        } else {
            position.point(at: frame)
        }
        let scale = scale.value(at: frame)
        let rotation = rotation.scalar(at: frame)
        return CGAffineTransform(translationX: -anchor.x, y: -anchor.y)
            .concatenating(CGAffineTransform(scaleX: (scale.first ?? 100) / 100, y: (scale.count > 1 ? scale[1] : scale.first ?? 100) / 100))
            .concatenating(CGAffineTransform(rotationAngle: rotation * .pi / 180))
            .concatenating(CGAffineTransform(translationX: position.x, y: position.y))
    }

    func opacity(at frame: Double) -> Double {
        opacity.scalar(at: frame) / 100
    }
}

struct LottieGradient {
    /// 1 linear, 2 radial.
    var type: Int
    var colorCount: Int
    var stops: LottieProperty<[Double]>
    var start: LottieProperty<[Double]>
    var end: LottieProperty<[Double]>
    var highlightLength: LottieProperty<[Double]>
    var highlightAngle: LottieProperty<[Double]>

    init(_ json: [String: Any]) {
        type = (json["t"] as? NSNumber)?.intValue ?? 1
        let g = json["g"] as? [String: Any]
        colorCount = (g?["p"] as? NSNumber)?.intValue ?? -1
        stops = LottieProperty(g?["k"], default: [])
        start = LottieProperty(json["s"], default: [0, 0])
        end = LottieProperty(json["e"], default: [0, 0])
        highlightLength = LottieProperty(json["h"], default: [0])
        highlightAngle = LottieProperty(json["a"], default: [0])
    }
}

struct LottieStrokeStyle {
    var width: LottieProperty<[Double]>
    /// 1 butt, 2 round, 3 square.
    var cap: Int
    /// 1 miter, 2 round, 3 bevel.
    var join: Int
    var miterLimit: Double
    /// Dash and gap lengths in order, then the offset (`n` "d", "g", "o").
    var dashes: [LottieProperty<[Double]>]
    var dashOffset: LottieProperty<[Double]>?

    init(_ json: [String: Any]) {
        width = LottieProperty(json["w"], default: [0])
        cap = (json["lc"] as? NSNumber)?.intValue ?? 1
        join = (json["lj"] as? NSNumber)?.intValue ?? 1
        miterLimit = (json["ml"] as? NSNumber)?.doubleValue ?? 0
        var dashes: [LottieProperty<[Double]>] = []
        for dash in json["d"] as? [[String: Any]] ?? [] {
            if dash["n"] as? String == "o" {
                dashOffset = LottieProperty(dash["v"], default: [0])
            } else {
                dashes.append(LottieProperty(dash["v"], default: [0]))
            }
        }
        self.dashes = dashes
    }
}

indirect enum LottieShape {
    case group([LottieShape], LottieTransform?)
    case path(LottieProperty<LottiePathData>)
    case rect(position: LottieProperty<[Double]>, size: LottieProperty<[Double]>, roundness: LottieProperty<[Double]>, clockwise: Bool)
    case ellipse(position: LottieProperty<[Double]>, size: LottieProperty<[Double]>, clockwise: Bool)
    case fill(color: LottieProperty<[Double]>, opacity: LottieProperty<[Double]>, evenOdd: Bool)
    case stroke(color: LottieProperty<[Double]>, opacity: LottieProperty<[Double]>, style: LottieStrokeStyle)
    case gradientFill(LottieGradient, opacity: LottieProperty<[Double]>, evenOdd: Bool)
    case gradientStroke(LottieGradient, opacity: LottieProperty<[Double]>, style: LottieStrokeStyle)
    /// `individually` (mode 2) trims all the paths before it as one.
    case trim(start: LottieProperty<[Double]>, end: LottieProperty<[Double]>, offset: LottieProperty<[Double]>, individually: Bool)

    /// `nil` for hidden items and those rlottie doesn't draw (merge paths, polystars, repeaters, rounded corners).
    static func parse(_ json: [String: Any]) -> LottieShape? {
        guard json["hd"] as? Bool != true, let type = json["ty"] as? String else { return nil }
        let clockwise = (json["d"] as? NSNumber)?.intValue != 3
        switch type {
        case "gr":
            let items = json["it"] as? [[String: Any]] ?? []
            let transform = items.first { $0["ty"] as? String == "tr" }.map(LottieTransform.init)
            return .group(items.compactMap(parse), transform)
        case "sh":
            return LottieProperty(path: json["ks"]).map { .path($0) }
        case "rc":
            return .rect(position: LottieProperty(json["p"], default: [0, 0]), size: LottieProperty(json["s"], default: [0, 0]), roundness: LottieProperty(json["r"], default: [0]), clockwise: clockwise)
        case "el":
            return .ellipse(position: LottieProperty(json["p"], default: [0, 0]), size: LottieProperty(json["s"], default: [0, 0]), clockwise: clockwise)
        case "fl":
            return .fill(color: LottieProperty(json["c"], default: [0, 0, 0]), opacity: LottieProperty(json["o"], default: [100]), evenOdd: (json["r"] as? NSNumber)?.intValue == 2)
        case "st":
            return .stroke(color: LottieProperty(json["c"], default: [0, 0, 0]), opacity: LottieProperty(json["o"], default: [100]), style: LottieStrokeStyle(json))
        case "gf":
            return .gradientFill(LottieGradient(json), opacity: LottieProperty(json["o"], default: [100]), evenOdd: (json["r"] as? NSNumber)?.intValue == 2)
        case "gs":
            return .gradientStroke(LottieGradient(json), opacity: LottieProperty(json["o"], default: [100]), style: LottieStrokeStyle(json))
        case "tm":
            return .trim(start: LottieProperty(json["s"], default: [0]), end: LottieProperty(json["e"], default: [100]), offset: LottieProperty(json["o"], default: [0]), individually: (json["m"] as? NSNumber)?.intValue == 2)
        default:
            return nil
        }
    }
}

struct LottieLayer {
    enum Kind {
        case precomp(refId: String, size: CGSize)
        case solid(color: CGColor, size: CGSize)
        case null
        case shape([LottieShape])
    }

    enum Matte {
        case alpha
        case alphaInverted
    }

    var index: Int?
    var parent: Int?
    var kind: Kind
    var inFrame: Double
    var outFrame: Double
    var startTime: Double
    var transform: LottieTransform
    var matte: Matte?
    var isMatteSource: Bool
    var isHidden: Bool

    init?(_ json: [String: Any]) {
        guard let type = (json["ty"] as? NSNumber)?.intValue else { return nil }
        let size = CGSize(width: (json["w"] as? NSNumber)?.doubleValue ?? 0, height: (json["h"] as? NSNumber)?.doubleValue ?? 0)
        switch type {
        case 0:
            guard let refId = json["refId"] as? String else { return nil }
            kind = .precomp(refId: refId, size: size)
        case 1:
            let hex = (json["sc"] as? String ?? "#000000").trimmingCharacters(in: CharacterSet(charactersIn: "#"))
            let value = UInt32(hex, radix: 16) ?? 0
            let color = CGColor(srgbRed: Double(value >> 16 & 0xFF) / 255, green: Double(value >> 8 & 0xFF) / 255, blue: Double(value & 0xFF) / 255, alpha: 1)
            kind = .solid(color: color, size: CGSize(width: (json["sw"] as? NSNumber)?.doubleValue ?? 0, height: (json["sh"] as? NSNumber)?.doubleValue ?? 0))
        case 3:
            kind = .null
        case 4:
            kind = .shape((json["shapes"] as? [[String: Any]] ?? []).compactMap(LottieShape.parse))
        default:
            // Images and text aren't in stickers; drawn as nothing, as a null layer, so parenting still works.
            kind = .null
        }
        index = (json["ind"] as? NSNumber)?.intValue
        parent = (json["parent"] as? NSNumber)?.intValue
        inFrame = (json["ip"] as? NSNumber)?.doubleValue ?? 0
        outFrame = (json["op"] as? NSNumber)?.doubleValue ?? 0
        startTime = (json["st"] as? NSNumber)?.doubleValue ?? 0
        transform = LottieTransform(json["ks"] as? [String: Any])
        // Luma mattes aren't in stickers; drawn as alpha mattes.
        matte = switch (json["tt"] as? NSNumber)?.intValue {
        case 1, 3: .alpha
        case 2, 4: .alphaInverted
        default: nil
        }
        isMatteSource = (json["td"] as? NSNumber)?.intValue == 1
        isHidden = json["hd"] as? Bool == true
    }
}

private extension [String: Any] {
    func double(_ key: String) -> Double? {
        (self[key] as? NSNumber)?.doubleValue
    }
}
