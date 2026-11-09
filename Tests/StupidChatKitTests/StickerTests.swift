import CoreGraphics
import Foundation
@testable import StupidChatKit
import XCTest

/// The sticker renderers' parts, with values checked against Telegram's rlottie (`scripts/lottie-compare.py`) and
/// ffmpeg's VP9 decode (`scripts/webm-compare.sh`). Whole stickers are compared by those scripts, not here: the
/// corpus is other people's artwork and stays out of the repository.
final class StickerTests: XCTestCase {
    // MARK: Lottie

    func testATGSFileIsGzippedJSON() throws {
        let json = Data(#"{"w":512,"h":256,"fr":30,"ip":0,"op":90,"layers":[]}"#.utf8)
        let animation = try LottieAnimation(tgs: gzip(json))
        XCTAssertEqual(animation.size, CGSize(width: 512, height: 256))
        XCTAssertEqual(animation.frameCount, 90)
        XCTAssertEqual(animation.duration, 3)
        XCTAssertThrowsError(try LottieAnimation(tgs: json), "not gzipped")
    }

    func testEasingFollowsTheCurve() {
        let linear = LottieEasing(x1: 0.167, y1: 0.167, x2: 0.833, y2: 0.833)
        XCTAssertEqual(linear.progress(0.4), 0.4, accuracy: 1e-9)
        let easeInOut = LottieEasing(x1: 0.42, y1: 0, x2: 0.58, y2: 1)
        XCTAssertEqual(easeInOut.progress(0.5), 0.5, accuracy: 1e-4)
        XCTAssertLessThan(easeInOut.progress(0.25), 0.25)
        XCTAssertGreaterThan(easeInOut.progress(0.75), 0.75)
    }

    func testKeyframesHoldAndEndAtTheNextKeyframesStart() throws {
        let animation = try LottieAnimation(json: Data("""
        {"w":512,"h":512,"fr":60,"ip":0,"op":60,"layers":[{"ty":3,"ip":0,"op":60,"ks":{"o":{"a":1,"k":[
            {"t":10,"s":[20],"h":1},
            {"t":20,"s":[40],"i":{"x":[1],"y":[1]},"o":{"x":[0],"y":[0]}},
            {"t":30,"s":[80]}
        ]}}}]}
        """.utf8))
        let opacity = animation.layers[0].transform.opacity
        XCTAssertEqual(opacity.scalar(at: 0), 20, "before the first keyframe, its value")
        XCTAssertEqual(opacity.scalar(at: 15), 20, "held")
        XCTAssertEqual(opacity.scalar(at: 25), 60, accuracy: 1e-6)
        XCTAssertEqual(opacity.scalar(at: 45), 80, "after the last keyframe, its value")
    }

    /// rlottie moves along a position's curve by its approximate arc length; these are where it draws a box moved so
    /// (observed 2026-11-04).
    func testPositionsFollowTheirCurveAsRlottieMeasuresIt() throws {
        let animation = try LottieAnimation(json: Data("""
        {"w":512,"h":512,"fr":60,"ip":0,"op":60,"layers":[{"ty":3,"ip":0,"op":60,"ks":{"p":{"a":1,"k":[
            {"t":0,"s":[100,100,0],"to":[80,0,0],"ti":[0,-80,0],"i":{"x":1,"y":1},"o":{"x":0,"y":0}},
            {"t":60,"s":[400,400,0]}
        ]}}}]}
        """.utf8))
        let position = animation.layers[0].transform.position
        for (frame, x, y) in [(10.0, 165.4, 125.6), (20, 224.2, 168.9), (40, 331.1, 275.8), (50, 374.4, 334.6)] {
            XCTAssertEqual(position.point(at: frame).x, x, accuracy: 0.5, "frame \(frame)")
            XCTAssertEqual(position.point(at: frame).y, y, accuracy: 0.5, "frame \(frame)")
        }
    }

    func testDistancesAreRlottiesEstimate() {
        XCTAssertEqual(CGPoint.zero.rlottieLength(to: CGPoint(x: 3, y: 4)), 4 + 0.375 * 3)
        XCTAssertEqual(CGPoint.zero.rlottieLength(to: CGPoint(x: -10, y: 0)), 10)
    }

    func testTrimKeepsTheStretchBetweenStartAndEnd() throws {
        let line: LottiePath = [.line([CGPoint(x: 0, y: 0), CGPoint(x: 100, y: 0)], closed: false)]
        let middle = line.trimmed(start: 0.25, end: 0.75)
        XCTAssertEqual(middle.count, 1)
        XCTAssertEqual(middle[0].start.x, 25, accuracy: 0.05)
        XCTAssertEqual(try XCTUnwrap(middle[0].segments.last).end.x, 75, accuracy: 0.05)
        XCTAssertEqual(line.trimmed(start: 0.75, end: 0.25).count, 2, "start after end wraps: the ends of the path")
        XCTAssertTrue(line.trimmed(start: 0.5, end: 0.5).isEmpty)
    }

    /// rlottie packs colour channels into one word without masking them, so ones an overshooting easing pushes out
    /// of range wrap and spill into the next byte; these are the colours it draws (observed 2026-11-04).
    func testColoursOutOfRangeWrapAsInRlottie() {
        let inRange = LottieRenderer.rlottieColor([1, 0.5, 0], alpha: 1)
        XCTAssertEqual([inRange.r, inRange.g, inRange.b, inRange.a], [255, 127, 0, 255])
        let green = 0.502 + 3.746 * (0.275 - 0.502), blue = 3.746 * 0.141
        let wrapped = LottieRenderer.rlottieColor([1 + 3.746 * (0.929 - 1), green, blue], alpha: 1)
        XCTAssertEqual([wrapped.r, wrapped.g, wrapped.b], [187, 168, 255], "a negative green fills the blue byte")
    }

    func testRendersAFilledShape() throws {
        let animation = try LottieAnimation(json: Data("""
        {"w":100,"h":100,"fr":30,"ip":0,"op":30,"layers":[{"ty":4,"ip":0,"op":30,"ks":{},"shapes":[
            {"ty":"rc","p":{"a":0,"k":[50,50]},"s":{"a":0,"k":[50,50]},"r":{"a":0,"k":0}},
            {"ty":"fl","c":{"a":0,"k":[0,0,1,1]},"o":{"a":0,"k":100}}
        ]}]}
        """.utf8))
        let image = try XCTUnwrap(animation.image(frame: 0, pixelSize: CGSize(width: 100, height: 100)))
        XCTAssertEqual(pixel(image, x: 50, y: 50), [0, 0, 255, 255], "blue inside")
        XCTAssertEqual(pixel(image, x: 10, y: 10)[3], 0, "transparent outside")
    }

    // MARK: WebM

    /// 64×64, two frames of half-transparent red at 10 fps, VP9 with an alpha track, made with ffmpeg
    /// (`color=c=red:s=64x64:d=0.2:r=10,format=rgba,colorchannelmixer=aa=0.5`, libvpx-vp9, yuva420p).
    private let tinyWebM = Data(base64Encoded: "GkXfo59ChoEBQveBAULygQRC84EIQoKEd2VibUKHgQJChYECGFOAZwEAAAAAAAJSEU2bdLpNu4tTq4QVSalmU6yBoU27i1OrhBZUrmtTrIHWTbuMU6uEElTDZ1OsggEnTbuMU6uEHFO7a1OsggI87AEAAAAAAABZAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAVSalmsCrXsYMPQkBNgIxMYXZmNjEuNy4xMDBXQYxMYXZmNjEuNy4xMDBEiYhAaQAAAAAAABZUrmvMrgEAAAAAAABD14EBc8WIEZJH1NEXuz6cgQAitZyDdW5kiIEAhoVWX1ZQOYOBASPjg4QF9eEA4JSwgUC6gUCagQJTwIEBVbCEVbmBARJUw2dAf3Nzn2PAgGfImUWjh0VOQ09ERVJEh4xMYXZmNjEuNy4xMDBzc9pjwItjxYgRkkfU0Re7PmfIpUWjh0VOQ09ERVJEh5hMYXZjNjEuMTkuMTAxIGxpYnZweC12cDlnyKFFo4hEVVJBVElPTkSHkzAwOjAwOjAwLjIwMDAwMDAwMAAfQ7Z1QIrngQCg0qGvgQAAAIJJg0IAA/AD9gA4JBwYQgAAMGAAAGc///5plf////6Za/////9imB1EwAB1oZ6mnO6BAaWXgkmDQgAD8AP2ADgkHBhCAAAwYAAAT4CgsaGTgQBkAIYAQJKcAElAAAMgAABUcHWhlqaU7oEBpY+GAECSnABJQAADIAAAVHD7gZwcU7trkbuPs4EAt4r3gQHxggGs8IED")!

    func testReadsAWebMStickersFrames() throws {
        guard let sticker = WebMSticker(data: tinyWebM) else {
            throw XCTSkip("no VP9 decoder for apps before iOS 26.2")
        }
        XCTAssertEqual(sticker.width, 64)
        XCTAssertEqual(sticker.height, 64)
        XCTAssertEqual(sticker.frameCount, 2)
        XCTAssertEqual(sticker.frameRate, 10, accuracy: 0.01)
        XCTAssertTrue(sticker.frames.allSatisfy { $0.alpha != nil }, "each frame carries its alpha")
        XCTAssertTrue(sticker.frames[0].isKeyframe)
    }

    func testDecodesAWebMStickerWithItsAlpha() throws {
        guard let sticker = WebMSticker(data: tinyWebM), let decoder = WebMStickerDecoder(sticker: sticker) else {
            throw XCTSkip("no VP9 decoder here")
        }
        let image = try XCTUnwrap(decoder.image(frame: 1))
        let color = pixel(image, x: 32, y: 32)
        XCTAssertEqual(Double(color[3]), 128, accuracy: 6, "half transparent")
        XCTAssertEqual(Double(color[0]), 255, accuracy: 8, "red")
        XCTAssertLessThan(color[1], 10)
        XCTAssertNotNil(decoder.image(frame: 0), "looping back starts again from the first frame")
    }

    // MARK: Helpers

    /// Unpremultiplied RGBA.
    private func pixel(_ image: CGImage, x: Int, y: Int) -> [UInt8] {
        var data = [UInt8](repeating: 0, count: 4)
        let context = CGContext(data: &data, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.draw(image, in: CGRect(x: -x, y: y - image.height + 1, width: image.width, height: image.height))
        let alpha = data[3]
        guard alpha > 0 else { return [0, 0, 0, 0] }
        return data[0 ..< 3].map { UInt8(min(255, Int($0) * 255 / Int(alpha))) } + [alpha]
    }

    /// Gzip with no compression: a stored deflate block, as `LottieAnimation.gunzip` must read any deflate.
    private func gzip(_ data: Data) -> Data {
        var out = Data([0x1F, 0x8B, 8, 0, 0, 0, 0, 0, 0, 0xFF])
        out.append(1)
        let length = UInt16(data.count)
        out.append(contentsOf: [UInt8(length & 0xFF), UInt8(length >> 8), UInt8(~length & 0xFF), UInt8(~length >> 8)])
        out.append(data)
        out.append(contentsOf: [0, 0, 0, 0])
        out.append(contentsOf: [UInt8(data.count & 0xFF), UInt8(data.count >> 8 & 0xFF), 0, 0])
        return out
    }
}
