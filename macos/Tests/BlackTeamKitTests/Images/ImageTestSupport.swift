import XCTest
#if canImport(ImageIO)
import ImageIO
import CoreGraphics
import UniformTypeIdentifiers
#endif
@testable import BlackTeamKit

#if canImport(ImageIO)

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
#else
/// Linux has no image library in this build: these are small files with the right signature and a size header,
/// enough for the format checks and for storing; they are not pictures that can be decoded or drawn.
/// Real pictures for the tests that need them come from ImageMagick (`LinuxPicture`).
enum TestImage {
    static func png(width: Int = 64, height: Int = 48, alpha: CGFloat = 1) -> Data {
        func be(_ value: Int) -> [UInt8] { [UInt8(value >> 24 & 255), UInt8(value >> 16 & 255), UInt8(value >> 8 & 255), UInt8(value & 255)] }
        var bytes: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A] + be(13) + Array("IHDR".utf8) + be(width) + be(height) + [8, 6, 0, 0, 0, 0, 0, 0, 0]
        bytes += be(0) + Array("IEND".utf8) + be(0)
        return Data(bytes)
    }

    /// An APP1 segment holding an EXIF block with a GPS position, a note, a camera make and the given orientation.
    static func exifSegment(orientation: Int = 1) -> [UInt8] {
        let tiff: [UInt8] = Array("MM".utf8) + [0, 42, 0, 0, 0, 8] + [0, 1, 0x01, 0x12, 0, 3, 0, 0, 0, 1, 0, UInt8(orientation), 0, 0, 0, 0, 0, 0]
        let notes = Array("GPSLatitude=51.5 GPSLongitude=-0.12 private note SecretCam".utf8)
        let body = Array("Exif\0\0".utf8) + tiff + notes
        let length = body.count + 2
        return [0xFF, 0xE1, UInt8(length >> 8 & 255), UInt8(length & 255)] + body
    }

    static func jpeg(width: Int = 64, height: Int = 48, exif: Bool = false, orientation: Int = 1) -> Data {
        var bytes: [UInt8] = [0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10] + Array("JFIF".utf8) + [0, 1, 1, 0, 0, 1, 0, 1, 0, 0]
        if exif { bytes += exifSegment(orientation: orientation) }
        bytes += [0xFF, 0xC0, 0x00, 0x11, 8, UInt8(height >> 8 & 255), UInt8(height & 255), UInt8(width >> 8 & 255), UInt8(width & 255), 3, 1, 0x11, 0, 2, 0x11, 0, 3, 0x11, 0]
        bytes += [0xFF, 0xD9]
        return Data(bytes)
    }

    /// A real JPEG with an EXIF/GPS segment placed right after its start marker.
    static func inject(exifInto jpeg: Data, orientation: Int = 1) -> Data { Data(jpeg.prefix(2)) + Data(exifSegment(orientation: orientation)) + Data(jpeg.dropFirst(2)) }
}

/// Real pictures for the tests that need ImageMagick; those tests are skipped, saying so, when it is not installed.
enum LinuxPicture {
    static func program() throws -> String {
        guard let program = ImageMagick.find() else { throw XCTSkip("ImageMagick is not installed here, so the picture-resizing path cannot be tested") }
        return program
    }

    private static func run(_ program: String, _ arguments: [String], input: Data = Data()) throws -> (Int32, Data) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: program)
        process.arguments = arguments
        let stdin = Pipe(), stdout = Pipe()
        process.standardInput = stdin; process.standardOutput = stdout; process.standardError = FileHandle.nullDevice
        try process.run()
        DispatchQueue.global().async { try? stdin.fileHandleForWriting.write(contentsOf: input); try? stdin.fileHandleForWriting.close() }
        let output = stdout.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, output)
    }

    static func make(width: Int, height: Int, format: String, color: String = "red", extra: [String] = []) throws -> Data {
        let (status, output) = try run(try program(), ["-size", "\(width)x\(height)", "xc:\(color)"] + extra + ["\(format):-"])
        guard status == 0, !output.isEmpty else { throw XCTSkip("ImageMagick could not make a test picture") }
        return output
    }

    private static func identify(_ data: Data, _ format: String) throws -> String {
        let program = try program()
        let (_, output) = try run(program, (program.hasSuffix("magick") ? ["identify"] : []) + ["-format", format, "-"], input: data)
        return String(decoding: output, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }
    static func size(_ data: Data) throws -> String { try identify(data, "%wx%h") }
    static func pixel(_ data: Data, x: Int, y: Int) throws -> String { try identify(data, "%[pixel:p{\(x),\(y)}]") }
}
#endif
