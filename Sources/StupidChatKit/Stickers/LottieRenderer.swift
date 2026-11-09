import CoreGraphics
import Foundation

public extension LottieAnimation {
    /// Draws frame `frame` (0 ..< `frameCount`) into `context` (a bitmap context with its origin at the bottom left),
    /// fitted to `size` and centred, as rlottie draws it.
    func render(frame: Int, in context: CGContext, size: CGSize) {
        let scale = min(size.width / self.size.width, size.height / self.size.height)
        let fit = CGAffineTransform(scaleX: scale, y: scale)
            .concatenating(CGAffineTransform(translationX: (size.width - self.size.width * scale) / 2, y: (size.height - self.size.height * scale) / 2))
        context.saveGState()
        context.translateBy(x: 0, y: size.height)
        context.scaleBy(x: 1, y: -1)
        let renderer = LottieRenderer(animation: self, context: context)
        renderer.composition(layers, frame: min(inFrame + Double(frame), outFrame), matrix: fit, alpha: 1, depth: 0)
        context.restoreGState()
    }

    /// A frame as an image `pixelSize` big, premultiplied BGRA (what image views draw fastest).
    func image(frame: Int, pixelSize: CGSize) -> CGImage? {
        guard let context = CGContext(
            data: nil, width: Int(pixelSize.width), height: Int(pixelSize.height), bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue,
        ) else { return nil }
        render(frame: frame, in: context, size: pixelSize)
        return context.makeImage()
    }
}

/// Draws an animation's layers and shapes with Core Graphics, following Telegram's rlottie fork (`lottieitem.cpp`):
/// paints draw the paths before them in their group and its subgroups, later items draw underneath, trims cut each
/// path from its untrimmed shape, a shape layer's opacity multiplies into each paint, a precomp's composites when it
/// has more than one layer, and mattes compose the layer under them.
struct LottieRenderer {
    let animation: LottieAnimation
    let context: CGContext

    private static let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
    private static let maxDepth = 8

    func composition(_ layers: [LottieLayer], frame: Double, matrix: CGAffineTransform, alpha: Double, depth: Int) {
        guard depth < Self.maxDepth else { return }
        let byIndex = Dictionary(layers.compactMap { layer in layer.index.map { ($0, layer) } }, uniquingKeysWith: { first, _ in first })
        func layerMatrix(_ layer: LottieLayer, _ depth: Int = 0) -> CGAffineTransform {
            let own = layer.transform.matrix(at: frame)
            guard depth < 64, let parentIndex = layer.parent, let parent = byIndex[parentIndex] else { return own }
            return own.concatenating(layerMatrix(parent, depth + 1))
        }
        func visible(_ layer: LottieLayer) -> Bool {
            frame >= layer.inFrame && frame < layer.outFrame
        }
        // Back to front; a layer with a matte is drawn through the layer above it.
        var matted: LottieLayer?
        for layer in layers.reversed() {
            if layer.matte != nil {
                matted = layer
                continue
            }
            defer { matted = nil }
            guard visible(layer) else { continue }
            if let content = matted {
                guard visible(content), let mode = content.matte else { continue }
                context.beginTransparencyLayer(auxiliaryInfo: nil)
                draw(content, frame: frame, matrix: layerMatrix(content).concatenating(matrix), alpha: alpha, depth: depth)
                context.saveGState()
                context.setBlendMode(mode == .alpha ? .destinationIn : .destinationOut)
                context.beginTransparencyLayer(auxiliaryInfo: nil)
                context.setBlendMode(.normal)
                draw(layer, frame: frame, matrix: layerMatrix(layer).concatenating(matrix), alpha: alpha, depth: depth)
                context.endTransparencyLayer()
                context.restoreGState()
                context.endTransparencyLayer()
            } else {
                draw(layer, frame: frame, matrix: layerMatrix(layer).concatenating(matrix), alpha: alpha, depth: depth)
            }
        }
    }

    private func draw(_ layer: LottieLayer, frame: Double, matrix: CGAffineTransform, alpha parentAlpha: Double, depth: Int) {
        guard !layer.isHidden else { return }
        let alpha = parentAlpha * layer.transform.opacity(at: frame)
        // Only exactly transparent layers are skipped: an overshooting opacity below 0 still draws, wrapped.
        guard abs(alpha) > 1e-6 else { return }
        switch layer.kind {
        case .null:
            break
        case let .solid(color, size):
            context.saveGState()
            context.setFillColor(color.copy(alpha: Double(Self.byte(255 * alpha)) / 255) ?? color)
            context.addPath(CGPath(rect: CGRect(origin: .zero, size: size), transform: [matrix]))
            context.fillPath()
            context.restoreGState()
        case let .shape(shapes):
            drawShapes(shapes, frame: frame, matrix: matrix, alpha: alpha)
        case let .precomp(refId, size):
            guard let layers = animation.assets[refId] else { return }
            context.saveGState()
            if size.width > 0, size.height > 0 {
                context.addPath(CGPath(rect: CGRect(origin: .zero, size: size), transform: [matrix]))
                context.clip()
            }
            let childFrame = frame - layer.startTime
            if abs(alpha - 1) > 1e-6, layers.count > 1 {
                // Drawn offscreen and composited with `uchar(alpha * 255)`.
                withOpacity(Double(Self.byte(255 * alpha)) / 255) {
                    composition(layers, frame: childFrame, matrix: matrix, alpha: 1, depth: depth + 1)
                }
            } else {
                composition(layers, frame: childFrame, matrix: matrix, alpha: alpha, depth: depth + 1)
            }
            context.restoreGState()
        }
    }

    private func withOpacity(_ alpha: Double, _ body: () -> Void) {
        guard alpha < 0.999 else {
            body()
            return
        }
        context.saveGState()
        context.setAlpha(alpha)
        context.beginTransparencyLayer(auxiliaryInfo: nil)
        body()
        context.endTransparencyLayer()
        context.restoreGState()
    }

    // MARK: Shapes

    private final class PathItem {
        let local: LottiePath
        var current: LottiePath
        let matrix: CGAffineTransform

        init(_ path: LottiePath, matrix: CGAffineTransform) {
            local = path
            current = path
            self.matrix = matrix
        }
    }

    private struct PaintOp {
        let paint: LottieShape
        let matrix: CGAffineTransform
        let alpha: Double
        let items: [PathItem]
    }

    private struct TrimOp {
        let start: Double
        let end: Double
        let offset: Double
        let individually: Bool
        let items: [PathItem]
    }

    private func drawShapes(_ shapes: [LottieShape], frame: Double, matrix: CGAffineTransform, alpha: Double) {
        var items: [PathItem] = []
        var paints: [PaintOp] = []
        var trims: [TrimOp] = []
        collect(shapes, frame: frame, matrix: matrix, alpha: alpha, items: &items, paints: &paints, trims: &trims)
        for trim in trims {
            apply(trim)
        }
        for paint in paints.reversed() {
            draw(paint, frame: frame)
        }
    }

    private func collect(_ shapes: [LottieShape], frame: Double, matrix: CGAffineTransform, alpha: Double, items: inout [PathItem], paints: inout [PaintOp], trims: inout [TrimOp]) {
        let first = items.count
        for shape in shapes {
            switch shape {
            case let .group(children, transform):
                let groupMatrix = (transform?.matrix(at: frame) ?? .identity).concatenating(matrix)
                let groupAlpha = alpha * (transform?.opacity(at: frame) ?? 1)
                collect(children, frame: frame, matrix: groupMatrix, alpha: groupAlpha, items: &items, paints: &paints, trims: &trims)
            case let .path(path):
                items.append(PathItem(path.value(at: frame).path, matrix: matrix))
            case let .rect(position, size, roundness, clockwise):
                items.append(PathItem(Self.rect(center: position.point(at: frame), size: size.point(at: frame), roundness: roundness.scalar(at: frame), clockwise: clockwise), matrix: matrix))
            case let .ellipse(position, size, clockwise):
                items.append(PathItem(Self.ellipse(center: position.point(at: frame), size: size.point(at: frame), clockwise: clockwise), matrix: matrix))
            case .fill, .stroke, .gradientFill, .gradientStroke:
                paints.append(PaintOp(paint: shape, matrix: matrix, alpha: alpha, items: Array(items[first...])))
            case let .trim(start, end, offset, individually):
                trims.append(TrimOp(start: start.scalar(at: frame), end: end.scalar(at: frame), offset: offset.scalar(at: frame), individually: individually, items: Array(items[first...])))
            }
        }
    }

    /// rlottie's `Trim::segment` and `Trim::update`.
    private func apply(_ trim: TrimOp) {
        var start = trim.start / 100, end = trim.end / 100
        let offset = trim.offset.truncatingRemainder(dividingBy: 360) / 360
        let segment: (Double, Double)
        let difference = abs(start - end)
        if difference < 1e-6 {
            segment = (0, 0)
        } else if abs(difference - 1) < 1e-6 {
            segment = (0, 1)
        } else {
            start += offset
            end += offset
            func noLoop(_ a: Double, _ b: Double) -> (Double, Double) {
                (min(a, b), max(a, b))
            }
            func loop(_ a: Double, _ b: Double) -> (Double, Double) {
                (max(a, b), min(a, b))
            }
            if offset > 0 {
                if start <= 1, end <= 1 {
                    segment = noLoop(start, end)
                } else if start > 1, end > 1 {
                    segment = noLoop(start - 1, end - 1)
                } else {
                    segment = start > 1 ? loop(start - 1, end) : loop(start, end - 1)
                }
            } else {
                if start >= 0, end >= 0 {
                    segment = noLoop(start, end)
                } else if start < 0, end < 0 {
                    segment = noLoop(1 + start, 1 + end)
                } else {
                    segment = start < 0 ? loop(1 + start, end) : loop(start, 1 + end)
                }
            }
        }
        if abs(segment.0 - segment.1) < 1e-6 {
            for item in trim.items {
                item.current = []
            }
            return
        }
        if abs(abs(segment.0 - segment.1) - 1) < 1e-6 {
            for item in trim.items {
                item.current = item.local
            }
            return
        }
        guard trim.individually else {
            for item in trim.items {
                item.current = item.local.trimmed(start: segment.0, end: segment.1)
            }
            return
        }
        let lengths = trim.items.map(\.local.length)
        let total = lengths.reduce(0, +)
        let from = total * segment.0, to = total * segment.1
        guard from < to else { return }
        var travelled = 0.0
        for (item, length) in zip(trim.items, lengths) {
            defer { travelled += length }
            if travelled > to || travelled + length < from {
                item.current = []
            } else if from <= travelled, to >= travelled + length {
                continue
            } else if length > 0 {
                let localStart = max(from - travelled, 0) / length
                let localEnd = (travelled + length < to ? length : to - travelled) / length
                item.current = item.local.trimmed(start: localStart, end: localEnd)
            }
        }
    }

    private func draw(_ paint: PaintOp, frame: Double) {
        let path = CGMutablePath()
        for item in paint.items {
            path.addPath(item.current.cgPath(transform: item.matrix))
        }
        guard !path.isEmpty else { return }
        context.saveGState()
        defer { context.restoreGState() }
        switch paint.paint {
        case let .fill(color, opacity, evenOdd):
            guard let color = Self.paintColor(color.value(at: frame), opacity: opacity.scalar(at: frame) / 100, parentAlpha: paint.alpha) else { return }
            context.setFillColor(color)
            context.addPath(path)
            context.fillPath(using: evenOdd ? .evenOdd : .winding)
        case let .stroke(color, opacity, style):
            guard let color = Self.paintColor(color.value(at: frame), opacity: opacity.scalar(at: frame) / 100, parentAlpha: paint.alpha),
                  setStroke(style, frame: frame, matrix: paint.matrix) else { return }
            context.setStrokeColor(color)
            context.addPath(path)
            context.strokePath()
        case let .gradientFill(gradient, opacity, evenOdd):
            context.addPath(path)
            context.clip(using: evenOdd ? .evenOdd : .winding)
            drawGradient(gradient, frame: frame, matrix: paint.matrix, opacity: paint.alpha * opacity.scalar(at: frame) / 100)
        case let .gradientStroke(gradient, opacity, style):
            guard setStroke(style, frame: frame, matrix: paint.matrix) else { return }
            context.addPath(path)
            context.replacePathWithStrokedPath()
            guard !context.isPathEmpty else { return }
            context.clip()
            drawGradient(gradient, frame: frame, matrix: paint.matrix, opacity: paint.alpha * opacity.scalar(at: frame) / 100)
        default:
            break
        }
    }

    /// Stroke width and dashes scale with the paint's group as rlottie's `VMatrix::scale()` measures it.
    private func setStroke(_ style: LottieStrokeStyle, frame: Double, matrix: CGAffineTransform) -> Bool {
        let diagonal = CGPoint(x: 1.41421, y: 1.41421).applying(matrix)
        let origin = CGPoint.zero.applying(matrix)
        let scale = origin.distance(to: diagonal) / 2
        let width = style.width.scalar(at: frame) * scale
        guard width > 0 else { return false }
        context.setLineWidth(width)
        context.setLineCap(style.cap == 2 ? .round : style.cap == 3 ? .square : .butt)
        context.setLineJoin(style.join == 2 ? .round : style.join == 3 ? .bevel : .miter)
        context.setMiterLimit(style.miterLimit)
        if !style.dashes.isEmpty {
            var lengths = style.dashes.map { $0.scalar(at: frame) * scale }
            if lengths.count % 2 == 1, let last = lengths.last {
                lengths.append(last)
            }
            if lengths.reduce(0, +) > 0, lengths.allSatisfy({ $0 >= 0 }) {
                context.setLineDash(phase: (style.dashOffset?.scalar(at: frame) ?? 0) * scale, lengths: lengths.map { CGFloat($0) })
            }
        }
        return true
    }

    private func drawGradient(_ gradient: LottieGradient, frame: Double, matrix: CGAffineTransform, opacity: Double) {
        guard let cgGradient = Self.gradient(gradient.stops.value(at: frame), colorCount: gradient.colorCount, opacity: opacity) else { return }
        context.concatenate(matrix)
        let start = gradient.start.point(at: frame), end = gradient.end.point(at: frame)
        let options: CGGradientDrawingOptions = [.drawsBeforeStartLocation, .drawsAfterEndLocation]
        if gradient.type == 1 {
            context.drawLinearGradient(cgGradient, start: start, end: end, options: options)
        } else {
            let radius = start.distance(to: end)
            guard radius > 0 else { return }
            var progress = gradient.highlightLength.scalar(at: frame) / 100
            if abs(progress - 1) < 1e-6 {
                progress = 0.99
            }
            let angle = (atan2(end.y - start.y, end.x - start.x) * 180 / .pi + gradient.highlightAngle.scalar(at: frame)) * .pi / 180
            let focal = CGPoint(x: start.x + cos(angle) * progress * radius, y: start.y + sin(angle) * progress * radius)
            context.drawRadialGradient(cgGradient, startCenter: focal, startRadius: 0, endCenter: start, endRadius: radius, options: options)
        }
    }

    /// Telegram's rlottie `LOTGradient::populate`: `colorCount` stops of position, red, green, blue, then position,
    /// opacity pairs. Opacity stops before a colour stop add a stop of that colour; a colour stop takes the opacity
    /// interpolated at its position.
    private static func gradient(_ values: [Double], colorCount: Int, opacity: Double) -> CGGradient? {
        var colorCount = colorCount
        if colorCount < 0 || colorCount > values.count / 4 {
            colorCount = values.count / 4
        }
        var opacities = Array(values.dropFirst(colorCount * 4))
        if opacities.count % 2 != 0 || (colorCount > opacities.count / 2 && opacities.count < 4) {
            opacities = []
        }
        var stops: [(location: Double, color: [Double], alpha: Double)] = []
        var j = 0
        for stop in 0 ..< colorCount {
            let position = values[stop * 4]
            let color = Array(values[stop * 4 + 1 ... stop * 4 + 3])
            guard !opacities.isEmpty else {
                stops.append((position, color, 1))
                continue
            }
            if j == opacities.count {
                guard j >= 4 else { continue }
                let stop1 = opacities[j - 4], op1 = opacities[j - 3], stop2 = opacities[j - 2], op2 = opacities[j - 1]
                stops.append((position, color, position > stop2 ? op2 : op1 + (position - stop1) / (stop2 - stop1) * (op2 - op1)))
                continue
            }
            while j < opacities.count {
                if opacities[j] < position {
                    stops.append((opacities[j], color, opacities[j + 1]))
                    j += 2
                    continue
                }
                if j == 0 {
                    stops.append((position, color, opacities[j + 1]))
                } else {
                    let progress = (position - opacities[j - 2]) / (opacities[j] - opacities[j - 2])
                    stops.append((position, color, opacities[j - 1] + progress * (opacities[j + 1] - opacities[j - 1])))
                }
                j += 2
                break
            }
        }
        if stops.isEmpty {
            stops = [(0, [1, 1, 1], 1)]
        }
        // `VGradientCache` premultiplies each stop with the paint's opacity (`VColor::premulARGB(float)`), packing
        // integers without masks as `toColor` does, and blends neighbouring stops premultiplied. Core Graphics blends
        // unpremultiplied colours, which darkens a fade to a transparent stop, so the blend between each pair of stops
        // is given as steps, each taken back unpremultiplied.
        let premultiplied = stops.map { stop -> [Double] in
            let (r, g, b, a) = rlottieColor(stop.color, alpha: stop.alpha)
            let alpha = int(Double(a) * opacity)
            let word = UInt32(bitPattern: alpha << 24 | ((Int32(r) &* alpha) / 255) << 16 | ((Int32(g) &* alpha) / 255) << 8 | (Int32(b) &* alpha) / 255)
            return [word >> 16 & 0xFF, word >> 8 & 0xFF, word & 0xFF, word >> 24].map { Double($0) / 255 }
        }
        var components: [CGFloat] = []
        var locations: [CGFloat] = []
        func add(_ color: [Double], at location: Double) {
            let alpha = color[3]
            components += (alpha > 0 ? color[0 ..< 3].map { min($0 / alpha, 1) } : [0, 0, 0]).map { CGFloat($0) } + [CGFloat(alpha)]
            locations.append(CGFloat(location))
        }
        let steps = 8
        for index in stops.indices {
            add(premultiplied[index], at: stops[index].location)
            guard index + 1 < stops.count, premultiplied[index] != premultiplied[index + 1] else { continue }
            for step in 1 ..< steps {
                let t = Double(step) / Double(steps)
                let color = zip(premultiplied[index], premultiplied[index + 1]).map { $0 + ($1 - $0) * t }
                add(color, at: stops[index].location + (stops[index + 1].location - stops[index].location) * t)
            }
        }
        return CGGradient(colorSpace: colorSpace, colorComponents: components, locations: locations, count: locations.count)
    }

    /// A solid paint's colour as Telegram's rlottie makes it: `toColor(opacity)`, then its alpha byte times the
    /// group and layer opacity (`uchar(color.a * parentAlpha())`). `nil` when that leaves it transparent.
    private static func paintColor(_ value: [Double], opacity: Double, parentAlpha: Double) -> CGColor? {
        let (r, g, b, a) = rlottieColor(value, alpha: opacity)
        let alpha = byte(Double(a) * parentAlpha)
        guard alpha > 0 else { return nil }
        return CGColor(colorSpace: colorSpace, components: [r, g, b, alpha].map { CGFloat($0) / 255 })!
    }

    /// A colour as rlottie's `LottieColor::toColor` makes it, `VColor(uchar(255 * r), …, uchar(255 * a))`. Clang
    /// (arm64, -O2) converts each channel to a saturating signed 32-bit integer and packs them into the colour's word
    /// (bytes a, r, g, b) with ORs and no masks, so a channel an overshooting easing pushes out of range wraps, and
    /// a negative one fills the bytes above it. Some emoji ease colours and opacity with `y: 10` and look as this
    /// draws them in Telegram (observed 2026-11-04, `scripts/lottie-compare.py`).
    static func rlottieColor(_ value: [Double], alpha: Double) -> (r: UInt8, g: UInt8, b: UInt8, a: UInt8) {
        func word(_ value: Double) -> UInt32 {
            UInt32(bitPattern: int(255 * value))
        }
        let packed = word(alpha) | word(value.first ?? 0) << 8 | word(value.count > 1 ? value[1] : 0) << 16 | word(value.count > 2 ? value[2] : 0) << 24
        return (UInt8(packed >> 8 & 0xFF), UInt8(packed >> 16 & 0xFF), UInt8(packed >> 24), UInt8(packed & 0xFF))
    }

    /// C's `int(value)` on arm64: truncated, saturating at the 32-bit limits.
    static func int(_ value: Double) -> Int32 {
        value.isNaN ? 0 : value <= -2_147_483_648 ? .min : value >= 2_147_483_647 ? .max : Int32(value)
    }

    /// `uchar(value)` on arm64: the low byte of `int(value)`.
    static func byte(_ value: Double) -> UInt8 {
        UInt8(truncatingIfNeeded: int(value))
    }

    // MARK: Primitive paths (rlottie's VPath::addOval and addRoundRect)

    private static let kappa = 0.5522847498

    static func ellipse(center: CGPoint, size: CGPoint, clockwise: Bool) -> LottiePath {
        guard size.x != 0 || size.y != 0 else { return [] }
        let x = center.x - size.x / 2, y = center.y - size.y / 2
        let w = size.x, w2 = w / 2, w2k = w2 * kappa
        let h = size.y, h2 = h / 2, h2k = h2 * kappa
        var contour = LottieContour(start: CGPoint(x: x + w2, y: y), closed: true)
        func curve(_ c1x: Double, _ c1y: Double, _ c2x: Double, _ c2y: Double, _ ex: Double, _ ey: Double) {
            contour.segments.append(LottieSegment(c1: CGPoint(x: c1x, y: c1y), c2: CGPoint(x: c2x, y: c2y), end: CGPoint(x: ex, y: ey)))
        }
        if clockwise {
            curve(x + w2 + w2k, y, x + w, y + h2 - h2k, x + w, y + h2)
            curve(x + w, y + h2 + h2k, x + w2 + w2k, y + h, x + w2, y + h)
            curve(x + w2 - w2k, y + h, x, y + h2 + h2k, x, y + h2)
            curve(x, y + h2 - h2k, x + w2 - w2k, y, x + w2, y)
        } else {
            curve(x + w2 - w2k, y, x, y + h2 - h2k, x, y + h2)
            curve(x, y + h2 + h2k, x + w2 - w2k, y + h, x + w2, y + h)
            curve(x + w2 + w2k, y + h, x + w, y + h2 + h2k, x + w, y + h2)
            curve(x + w, y + h2 - h2k, x + w2 + w2k, y, x + w2, y)
        }
        return [contour]
    }

    static func rect(center: CGPoint, size: CGPoint, roundness: Double, clockwise: Bool) -> LottiePath {
        let x = center.x - size.x / 2, y = center.y - size.y / 2, w = size.x, h = size.y
        var r = roundness
        if 2 * r > w { r = w / 2 }
        if 2 * r > h { r = h / 2 }
        if r <= 0 {
            guard w != 0 || h != 0 else { return [] }
            let corners = clockwise
                ? [CGPoint(x: x + w, y: y), CGPoint(x: x + w, y: y + h), CGPoint(x: x, y: y + h), CGPoint(x: x, y: y)]
                : [CGPoint(x: x + w, y: y), CGPoint(x: x, y: y), CGPoint(x: x, y: y + h), CGPoint(x: x + w, y: y + h)]
            return [.line(corners, closed: true)]
        }
        let k = r * kappa
        var contour = LottieContour(start: CGPoint(x: x + w, y: y + r), closed: true)
        func line(_ px: Double, _ py: Double) {
            let point = CGPoint(x: px, y: py)
            let previous = contour.segments.last?.end ?? contour.start
            contour.segments.append(LottieSegment(c1: previous, c2: point, end: point))
        }
        func curve(_ c1x: Double, _ c1y: Double, _ c2x: Double, _ c2y: Double, _ ex: Double, _ ey: Double) {
            contour.segments.append(LottieSegment(c1: CGPoint(x: c1x, y: c1y), c2: CGPoint(x: c2x, y: c2y), end: CGPoint(x: ex, y: ey)))
        }
        if clockwise {
            line(x + w, y + h - r)
            curve(x + w, y + h - r + k, x + w - r + k, y + h, x + w - r, y + h)
            line(x + r, y + h)
            curve(x + r - k, y + h, x, y + h - r + k, x, y + h - r)
            line(x, y + r)
            curve(x, y + r - k, x + r - k, y, x + r, y)
            line(x + w - r, y)
            curve(x + w - r + k, y, x + w, y + r - k, x + w, y + r)
        } else {
            curve(x + w, y + r - k, x + w - r + k, y, x + w - r, y)
            line(x + r, y)
            curve(x + r - k, y, x, y + r - k, x, y + r)
            line(x, y + h - r)
            curve(x, y + h - r + k, x + r - k, y + h, x + r, y + h)
            line(x + w - r, y + h)
            curve(x + w - r + k, y + h, x + w, y + h - r + k, x + w, y + h - r)
            line(x + w, y + r)
        }
        return [contour]
    }
}
