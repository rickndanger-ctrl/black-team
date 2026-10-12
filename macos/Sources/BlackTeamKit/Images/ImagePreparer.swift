import Foundation
#if canImport(ImageIO)
import ImageIO
import CoreGraphics
import UniformTypeIdentifiers

/// Gets a picture ready to send: what `prepareImage` in `src/ImageAttachments.jsx` does in a browser, done natively.
/// Anything macOS can decode is accepted (the browser could not read HEIC, the Mac can). The longer side is scaled
/// down to 1280 pixels, EXIF orientation is applied, transparency is flattened onto white, and the result is a
/// fresh JPEG at quality 0.85 with no metadata (no EXIF, no GPS), because the picture is redrawn, not copied.
public enum ImagePreparer {
    public static let notAnImage = "Choose an image file (JPEG, PNG, WebP, HEIC, TIFF or GIF)."
    public static let tooBigSource = "Choose an image smaller than 20 MB."
    public static let tooBigResult = "This image is too large after resizing. Choose a smaller image."

    public static func prepare(url: URL) throws -> ImageUpload {
        var info = CStat()
        if stat(url.path, &info) != 0 || (info.st_mode & S_IFMT) != S_IFREG { throw BlackTeamError("Could not read image.") }
        if Int(info.st_size) > ImageRules.maxSourceBytes { throw BlackTeamError(tooBigSource) }
        guard let data = try? Data(contentsOf: url) else { throw BlackTeamError("Could not read image.") }
        return try prepare(data: data, name: url.lastPathComponent)
    }

    public static func prepare(data: Data, name: String) throws -> ImageUpload {
        if data.count > ImageRules.maxSourceBytes { throw BlackTeamError(tooBigSource) }
        guard let source = CGImageSourceCreateWithData(data as CFData, nil), CGImageSourceGetCount(source) > 0,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
              let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue, width > 0, height > 0 else {
            throw BlackTeamError(notAnImage)
        }
        // A small file can still hold an enormous picture; refuse it rather than decode it.
        if width * height > 200_000_000 { throw BlackTeamError(tooBigResult) }
        // The thumbnail call applies the orientation and never enlarges: the cap is the long side or 1280, whichever is smaller.
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true, kCGImageSourceThumbnailMaxPixelSize: min(ImageRules.maxSide, max(width, height)),
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { throw BlackTeamError("Could not decode image.") }
        let w = image.width, h = image.height
        guard let context = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { throw BlackTeamError("Could not decode image.") }
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: w, height: h))
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let flat = context.makeImage() else { throw BlackTeamError("Could not decode image.") }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.jpeg.identifier as CFString, 1, nil) else { throw BlackTeamError("Could not decode image.") }
        CGImageDestinationAddImage(destination, flat, [kCGImageDestinationLossyCompressionQuality: ImageRules.jpegQuality] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw BlackTeamError("Could not decode image.") }
        if output.length > ImageRules.maxBytes { throw BlackTeamError(tooBigResult) }
        return ImageUpload(name: String(name.prefix(200)), data: output as Data)
    }

    /// Pixel size of encoded image data, as stored (no orientation: stored files are already upright).
    public static func dimensions(of data: Data) -> (width: Int, height: Int)? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil), CGImageSourceGetCount(source) > 0,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
              let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue, width > 0, height > 0 else { return nil }
        return (width, height)
    }
}
#else
/// Gets a picture ready to send, on Linux (there is no ImageIO). A JPEG, PNG or WebP that is already small enough is kept
/// as it is, with its metadata removed and without re-encoding it. Anything else is resized with ImageMagick when that is
/// installed, in the way the Mac does it; without ImageMagick the person is told what to do.
public enum ImagePreparer {
    public static let notAnImage = "Choose an image file (JPEG, PNG, WebP, HEIC, TIFF or GIF)."
    public static let tooBigSource = "Choose an image smaller than 20 MB."
    public static let tooBigResult = "This image is too large after resizing. Choose a smaller image."
    public static let needsResizing = "This picture needs resizing first. On Linux, Black Team can resize pictures when ImageMagick is installed, or you can send a JPEG or PNG up to 1280 pixels and 1 MB."

    /// Where ImageMagick is looked for (the PATH); tests point it elsewhere.
    nonisolated(unsafe) static var searchPath: String? = nil

    public static func prepare(url: URL) throws -> ImageUpload {
        var info = CStat()
        if stat(url.path, &info) != 0 || (info.st_mode & S_IFMT) != S_IFREG { throw BlackTeamError("Could not read image.") }
        if Int(info.st_size) > ImageRules.maxSourceBytes { throw BlackTeamError(tooBigSource) }
        guard let data = try? Data(contentsOf: url) else { throw BlackTeamError("Could not read image.") }
        return try prepare(data: data, name: url.lastPathComponent)
    }

    public static func prepare(data: Data, name: String) throws -> ImageUpload {
        if data.count > ImageRules.maxSourceBytes { throw BlackTeamError(tooBigSource) }
        let kind = ImageRules.kind(of: data)
        let size = ImageStripper.dimensions(of: data)
        let name = String(name.prefix(200))
        // A picture the person's phone turned by a tag has to be turned for real before the tag is removed, which
        // needs ImageMagick. Without it the picture is refused below with the resize message, rather than sent to
        // the model on its side.
        let needsTurning = kind == .jpeg && ImageStripper.jpegOrientation(data) != 1
        if let kind, let size, data.count <= ImageRules.maxBytes, max(size.width, size.height) <= ImageRules.maxSide {
            if !needsTurning {
                guard let clean = ImageStripper.stripped(data, kind: kind), let after = ImageStripper.dimensions(of: clean),
                      after.width == size.width, after.height == size.height else { throw BlackTeamError("Could not decode image.") }
                return ImageUpload(name: name, data: clean)
            }
        }
        guard let coder = ImageMagick.coder(for: data) else { throw BlackTeamError(notAnImage) }
        if let size, size.width * size.height > 200_000_000 { throw BlackTeamError(tooBigResult) }
        guard let program = ImageMagick.find(path: searchPath ?? ProcessInfo.processInfo.environment["PATH"]) else { throw BlackTeamError(needsResizing) }
        let result = try ImageMagick.resize(data, coder: coder, program: program)
        if result.count > ImageRules.maxBytes { throw BlackTeamError(tooBigResult) }
        guard let after = ImageStripper.dimensions(of: result), max(after.width, after.height) <= ImageRules.maxSide else { throw BlackTeamError("Could not decode image.") }
        return ImageUpload(name: name, data: result)
    }

    /// Pixel size from the file header of a PNG, JPEG or WebP.
    public static func dimensions(of data: Data) -> (width: Int, height: Int)? { ImageStripper.dimensions(of: data) }
}
#endif
