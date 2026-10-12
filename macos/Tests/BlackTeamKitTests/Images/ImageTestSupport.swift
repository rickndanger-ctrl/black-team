import XCTest
import ImageIO
import CoreGraphics
import UniformTypeIdentifiers
@testable import BlackTeamKit

/// Pictures made on the spot: a solid colour (with or without transparency), encoded as PNG or JPEG, optionally tagged
/// with an EXIF orientation and a GPS position.
enum TestImage {
    static func cgImage(width: Int, height: Int, red: CGFloat = 1, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 1) -> CGImage {
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(red: red * alpha, green: green * alpha, blue: blue * alpha, alpha: alpha))
        context.clear(CGRect(x: 0, y: 0, width: width, height: height))
        if alpha > 0 { context.setFillColor(CGColor(red: red, green: green, blue: blue, alpha: alpha)); context.fill(CGRect(x: 0, y: 0, width: width, height: height)) }
        return context.makeImage()!
    }

    static func encode(_ image: CGImage, type: UTType, properties: [CFString: Any] = [:]) -> Data {
        let data = NSMutableData()
        let destination = CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        CGImageDestinationFinalize(destination)
        return data as Data
    }

    static func png(width: Int = 64, height: Int = 48, alpha: CGFloat = 1) -> Data { encode(cgImage(width: width, height: height, alpha: alpha), type: .png) }
    static func jpeg(width: Int = 64, height: Int = 48, properties: [CFString: Any] = [:]) -> Data { encode(cgImage(width: width, height: height), type: .jpeg, properties: properties) }

    /// The colour of one pixel of encoded image data, as 0...255 red, green, blue.
    static func pixel(_ data: Data, x: Int, y: Int) -> (Int, Int, Int) {
        let source = CGImageSourceCreateWithData(data as CFData, nil)!
        let image = CGImageSourceCreateImageAtIndex(source, 0, nil)!
        var bytes = [UInt8](repeating: 0, count: 4)
        let context = CGContext(data: &bytes, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.draw(image, in: CGRect(x: -x, y: -(image.height - 1 - y), width: image.width, height: image.height))
        return (Int(bytes[0]), Int(bytes[1]), Int(bytes[2]))
    }

    static func properties(_ data: Data) -> [CFString: Any] {
        CGImageSourceCopyPropertiesAtIndex(CGImageSourceCreateWithData(data as CFData, nil)!, 0, nil) as? [CFString: Any] ?? [:]
    }
}
