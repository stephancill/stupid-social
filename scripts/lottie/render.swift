// Renders frames of a TGS or Lottie JSON file with the app's renderer (Sources/StupidSocialCore/Stickers), on the Mac,
// for comparison with rlottie. Writes <out>/<frame>.png.
//
//   render <file.tgs|file.json> <out dir> <size> <frame>...
//   render --time <file.tgs> <size>    average milliseconds per frame over every frame
//
// Built by scripts/lottie-compare.py together with the renderer's sources.

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

func load(_ path: String) throws -> LottieAnimation {
    let data = try Data(contentsOf: URL(fileURLWithPath: path))
    return path.hasSuffix(".tgs") ? try LottieAnimation(tgs: data) : try LottieAnimation(json: data)
}

let arguments = CommandLine.arguments
if arguments.count == 4, arguments[1] == "--time" {
    let animation = try load(arguments[2])
    let side = Double(arguments[3])!
    let started = Date()
    for frame in 0 ..< animation.frameCount {
        _ = animation.image(frame: frame, pixelSize: CGSize(width: side, height: side))
    }
    print(String(format: "%.2f ms/frame over %d frames", Date().timeIntervalSince(started) * 1000 / Double(animation.frameCount), animation.frameCount))
    exit(0)
}

guard arguments.count >= 5 else {
    FileHandle.standardError.write("usage: render <file> <out dir> <size> <frame>...\n".data(using: .utf8)!)
    exit(2)
}

let animation = try load(arguments[1])
let side = Double(arguments[3])!
for frameArgument in arguments[4...] {
    let frame = Int(frameArgument)!
    guard let image = animation.image(frame: frame, pixelSize: CGSize(width: side, height: side)) else { exit(1) }
    let url = URL(fileURLWithPath: arguments[2]).appendingPathComponent("\(frame).png")
    let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, image, nil)
    CGImageDestinationFinalize(destination)
}

print("\(animation.frameCount) frames")
