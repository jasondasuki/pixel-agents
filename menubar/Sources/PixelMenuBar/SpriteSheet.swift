import AppKit
import CoreGraphics

/// One tight-cropped animation frame.
struct SpriteFrame {
    let image: CGImage
    let width: Int
    let height: Int
}

/// A pet's side-view walk cycle and its idle pose.
///
/// pet.png is 96x96 (core/src/assets/pngDecoder.ts `decodePetPng`):
/// - `walkRight`: three 32x32 cells at y=64.
/// - `idleDown`: three 16x32 cells at y=0, after the three `walkDown` cells (x = 48...).
/// The office-only directions (walkDown/walkUp/idleUp) are not used here.
struct PetSprites {
    let name: String
    let walk: [SpriteFrame]
    let idle: [SpriteFrame]
}

enum PetLoader {
    static let sheetSize = 96
    static let alphaThreshold: UInt8 = 8

    /// Folder holding `<pet>/pet.png`. The .app bundle copies it into Resources;
    /// `swift run` falls back to the copy in the package.
    static var resourceDirectory: URL {
        if let override = ProcessInfo.processInfo.environment["PIXEL_MENUBAR_PETS"] {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        if let bundled = Bundle.main.resourceURL?.appendingPathComponent("pets", isDirectory: true),
           FileManager.default.fileExists(atPath: bundled.path) {
            return bundled
        }
        return URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Resources/pets", isDirectory: true)
    }

    static func loadAll(from directory: URL = resourceDirectory) -> [PetSprites] {
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []).sorted()
        return names.compactMap { name in
            load(name: name, url: directory.appendingPathComponent(name).appendingPathComponent("pet.png"))
        }
    }

    static func load(name: String, url: URL) -> PetSprites? {
        guard let pixels = decodeRGBA(url: url) else {
            FileHandle.standardError.write(Data("[PixelMenuBar] could not decode \(url.path)\n".utf8))
            return nil
        }
        let walkBoxes = (0..<3).map { Box(x: $0 * 32, y: 64, w: 32, h: 32) }
        let idleBoxes = (0..<3).map { Box(x: 48 + $0 * 16, y: 0, w: 16, h: 32) }

        // Sheets this dark vanish on a dark menu bar; give them a light 1px outline.
        let outline = meanLuminance(pixels, boxes: walkBoxes) < 0.3
        guard let walk = frames(pixels, boxes: walkBoxes, outline: outline),
              let idle = frames(pixels, boxes: idleBoxes, outline: outline) else { return nil }
        return PetSprites(name: name, walk: walk, idle: idle)
    }

    // MARK: pixel work

    struct Box { let x, y, w, h: Int }
    struct Pixels { let data: [UInt8]; let width: Int; let height: Int }

    /// Premultiplied RGBA, row 0 at the top.
    static func decodeRGBA(url: URL) -> Pixels? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
              image.width == sheetSize, image.height == sheetSize else { return nil }
        var data = [UInt8](repeating: 0, count: sheetSize * sheetSize * 4)
        let drew = data.withUnsafeMutableBytes { buffer -> Bool in
            guard let ctx = CGContext(
                data: buffer.baseAddress, width: sheetSize, height: sheetSize,
                bitsPerComponent: 8, bytesPerRow: sheetSize * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: sheetSize, height: sheetSize))
            return true
        }
        return drew ? Pixels(data: data, width: sheetSize, height: sheetSize) : nil
    }

    static func meanLuminance(_ p: Pixels, boxes: [Box]) -> Double {
        var sum = 0.0, count = 0.0
        for b in boxes {
            for y in b.y..<(b.y + b.h) {
                for x in b.x..<(b.x + b.w) {
                    let i = (y * p.width + x) * 4
                    let a = Double(p.data[i + 3])
                    guard a > Double(alphaThreshold) else { continue }
                    // Un-premultiply, then Rec. 709 luma.
                    let r = Double(p.data[i]) / a, g = Double(p.data[i + 1]) / a, bl = Double(p.data[i + 2]) / a
                    sum += 0.2126 * r + 0.7152 * g + 0.0722 * bl
                    count += 1
                }
            }
        }
        return count == 0 ? 1 : sum / count
    }

    /// Crops every frame to the union of their opaque bounds, so the pet does not
    /// jitter between frames, and optionally adds the outline.
    static func frames(_ p: Pixels, boxes: [Box], outline: Bool) -> [SpriteFrame]? {
        var minX = Int.max, minY = Int.max, maxX = -1, maxY = -1
        for b in boxes {
            for y in 0..<b.h {
                for x in 0..<b.w where p.data[((b.y + y) * p.width + b.x + x) * 4 + 3] > alphaThreshold {
                    minX = min(minX, x); maxX = max(maxX, x)
                    minY = min(minY, y); maxY = max(maxY, y)
                }
            }
        }
        guard maxX >= minX, maxY >= minY else { return nil }
        let w = maxX - minX + 1, h = maxY - minY + 1

        return boxes.compactMap { b -> SpriteFrame? in
            var crop = [UInt8](repeating: 0, count: w * h * 4)
            for y in 0..<h {
                let src = ((b.y + minY + y) * p.width + b.x + minX) * 4
                crop.replaceSubrange((y * w * 4)..<((y + 1) * w * 4), with: p.data[src..<(src + w * 4)])
            }
            let (out, ow, oh) = outline ? addOutline(crop, w: w, h: h) : (crop, w, h)
            guard let image = makeImage(out, w: ow, h: oh) else { return nil }
            return SpriteFrame(image: image, width: ow, height: oh)
        }
    }

    /// 1px light border around the opaque pixels (4-neighbourhood), on a 1px pad.
    static func addOutline(_ src: [UInt8], w: Int, h: Int) -> ([UInt8], Int, Int) {
        let ow = w + 2, oh = h + 2
        var out = [UInt8](repeating: 0, count: ow * oh * 4)
        func opaque(_ x: Int, _ y: Int) -> Bool {
            x >= 0 && y >= 0 && x < w && y < h && src[(y * w + x) * 4 + 3] > alphaThreshold
        }
        for y in 0..<oh {
            for x in 0..<ow {
                let sx = x - 1, sy = y - 1
                let o = (y * ow + x) * 4
                if opaque(sx, sy) {
                    let i = (sy * w + sx) * 4
                    out.replaceSubrange(o..<(o + 4), with: src[i..<(i + 4)])
                } else if opaque(sx - 1, sy) || opaque(sx + 1, sy) || opaque(sx, sy - 1) || opaque(sx, sy + 1) {
                    out[o] = 232; out[o + 1] = 232; out[o + 2] = 232; out[o + 3] = 255
                }
            }
        }
        return (out, ow, oh)
    }

    static func makeImage(_ data: [UInt8], w: Int, h: Int) -> CGImage? {
        guard let provider = CGDataProvider(data: Data(data) as CFData) else { return nil }
        return CGImage(
            width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent
        )
    }
}
