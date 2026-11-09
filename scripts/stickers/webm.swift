// Decodes a WebM video sticker with the app's decoder (Sources/StupidChatKit/Stickers/WebMSticker.swift) on the
// Mac and writes frames as PNGs, for comparison with ffmpeg's libvpx decode (scripts/webm-compare.sh).
//
//   webm <file.webm> <out dir> [frame...]    every frame when none are named
//   webm --time <file.webm>                  milliseconds per frame, decoding in order

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let arguments = CommandLine.arguments
let timing = arguments.count == 3 && arguments[1] == "--time"
let path = timing ? arguments[2] : arguments[1]
guard let sticker = try WebMSticker(data: Data(contentsOf: URL(fileURLWithPath: path))), let decoder = WebMStickerDecoder(sticker: sticker) else {
    FileHandle.standardError.write("cannot decode \(path)\n".data(using: .utf8)!)
    exit(1)
}

if timing {
    let started = Date()
    for frame in 0 ..< sticker.frameCount {
        _ = decoder.image(frame: frame)
    }
    print(String(format: "%.2f ms/frame over %d frames, %dx%d at %.0f fps", Date().timeIntervalSince(started) * 1000 / Double(sticker.frameCount), sticker.frameCount, sticker.width, sticker.height, sticker.frameRate))
    exit(0)
}

let frames = arguments.count > 3 ? arguments[3...].compactMap { Int($0) } : Array(0 ..< sticker.frameCount)
for frame in frames {
    guard let image = decoder.image(frame: frame) else {
        print("frame \(frame): no image")
        continue
    }
    let url = URL(fileURLWithPath: arguments[2]).appendingPathComponent("\(frame).png")
    let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, image, nil)
    CGImageDestinationFinalize(destination)
}

print("\(sticker.frameCount) frames, \(sticker.width)x\(sticker.height) at \(sticker.frameRate) fps")
