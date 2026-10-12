import Foundation

/// Removes metadata from JPEG, PNG and WebP files without re-encoding them, and reads picture sizes from file headers.
/// Used by the Linux picture preparation (there is no ImageIO there); it is plain Swift, so it also builds on the Mac.
enum ImageStripper {
    /// What a JPEG's EXIF block says about orientation (1 when it says nothing or there is none).
    static func jpegOrientation(_ data: Data) -> Int {
        let b = [UInt8](data)
        guard b.count > 4, b[0] == 0xFF, b[1] == 0xD8 else { return 1 }
        var at = 2
        while at + 4 <= b.count {
            guard b[at] == 0xFF else { return 1 }
            let marker = b[at + 1]
            if marker == 0xFF { at += 1; continue }
            if marker == 0xDA || marker == 0xD9 { return 1 }
            if marker == 0x01 || (0xD0...0xD8).contains(marker) { at += 2; continue }
            let length = Int(b[at + 2]) << 8 | Int(b[at + 3])
            guard length >= 2, at + 2 + length <= b.count else { return 1 }
            if marker == 0xE1, length >= 16, Array(b[(at + 4)..<(at + 10)]) == Array("Exif\0\0".utf8) {
                let t = at + 10                                   // the TIFF header
                let little = b[t] == 0x49
                func u16(_ o: Int) -> Int { little ? Int(b[t + o]) | Int(b[t + o + 1]) << 8 : Int(b[t + o]) << 8 | Int(b[t + o + 1]) }
                func u32(_ o: Int) -> Int { little ? u16(o) | u16(o + 2) << 16 : u16(o) << 16 | u16(o + 2) }
                guard t + 8 <= at + 2 + length else { return 1 }
                let ifd = u32(4)
                guard t + ifd + 2 <= at + 2 + length else { return 1 }
                for index in 0..<min(u16(ifd), 64) {
                    let entry = ifd + 2 + index * 12
                    guard t + entry + 12 <= at + 2 + length else { return 1 }
                    if u16(entry) == 0x0112 { let value = u16(entry + 8); return (1...8).contains(value) ? value : 1 }
                }
                return 1
            }
            at += 2 + length
        }
        return 1
    }

    /// The JPEG without its APP1 (EXIF, XMP), APP13 (Photoshop) and comment segments; everything else is copied unchanged.
    /// Nil when the data is not a well-formed JPEG up to its image data.
    static func stripJPEG(_ data: Data) -> Data? {
        let b = [UInt8](data)
        guard b.count > 4, b[0] == 0xFF, b[1] == 0xD8 else { return nil }
        var out: [UInt8] = [0xFF, 0xD8]
        var at = 2
        while at + 2 <= b.count {
            guard b[at] == 0xFF else { return nil }
            let marker = b[at + 1]
            if marker == 0xFF { at += 1; continue }
            if marker == 0xDA {                                   // image data: copy the rest as it is
                out += b[at...]
                return Data(out)
            }
            if marker == 0x01 || (0xD0...0xD8).contains(marker) { out += [0xFF, marker]; at += 2; continue }
            if marker == 0xD9 { out += [0xFF, 0xD9]; return Data(out) }
            guard at + 4 <= b.count else { return nil }
            let length = Int(b[at + 2]) << 8 | Int(b[at + 3])
            guard length >= 2, at + 2 + length <= b.count else { return nil }
            if ![0xE1, 0xED, 0xFE].contains(marker) { out += b[at..<(at + 2 + length)] }
            at += 2 + length
        }
        return nil
    }

    /// The PNG without its tEXt, iTXt, zTXt and eXIf chunks. Nil when the chunks do not run cleanly to IEND.
    static func stripPNG(_ data: Data) -> Data? {
        let b = [UInt8](data)
        let signature: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
        guard b.count >= 8, Array(b[0..<8]) == signature else { return nil }
        var out = signature
        var at = 8
        let dropped: Set<String> = ["tEXt", "iTXt", "zTXt", "eXIf"]
        while at + 12 <= b.count {
            let length = Int(b[at]) << 24 | Int(b[at + 1]) << 16 | Int(b[at + 2]) << 8 | Int(b[at + 3])
            let end = at + 12 + length
            guard length >= 0, end <= b.count else { return nil }
            let type = String(decoding: b[(at + 4)..<(at + 8)], as: UTF8.self)
            if !dropped.contains(type) { out += b[at..<end] }
            at = end
            if type == "IEND" { return Data(out) }
        }
        return nil
    }

    /// The WebP without its EXIF and XMP chunks (and the flags that announce them).
    static func stripWebP(_ data: Data) -> Data? {
        let b = [UInt8](data)
        guard b.count >= 20, Array(b[0..<4]) == Array("RIFF".utf8), Array(b[8..<12]) == Array("WEBP".utf8) else { return nil }
        var body: [UInt8] = Array("WEBP".utf8)
        var at = 12
        while at + 8 <= b.count {
            let type = String(decoding: b[at..<(at + 4)], as: UTF8.self)
            let length = Int(b[at + 4]) | Int(b[at + 5]) << 8 | Int(b[at + 6]) << 16 | Int(b[at + 7]) << 24
            let padded = length + (length & 1)
            guard at + 8 + length <= b.count else { return nil }
            let end = min(at + 8 + padded, b.count)
            if type == "EXIF" || type == "XMP " { at = end; continue }
            var chunk = Array(b[at..<end])
            if type == "VP8X", chunk.count >= 9 { chunk[8] &= ~(0x08 | 0x04) }   // no EXIF, no XMP
            body += chunk
            at = end
        }
        let size = body.count
        return Data(Array("RIFF".utf8) + [UInt8(size & 255), UInt8(size >> 8 & 255), UInt8(size >> 16 & 255), UInt8(size >> 24 & 255)] + body)
    }

    /// The same file with its metadata removed, by what its first bytes say it is.
    static func stripped(_ data: Data, kind: ImageRules.Kind) -> Data? {
        switch kind {
        case .jpeg: return stripJPEG(data)
        case .png: return stripPNG(data)
        case .webp: return stripWebP(data)
        }
    }

    /// Pixel size from the file header of a PNG, JPEG or WebP (what can be read without an image library).
    static func dimensions(of data: Data) -> (width: Int, height: Int)? {
        let b = [UInt8](data.prefix(1 << 16))
        func be(_ at: Int, _ count: Int) -> Int { b[at..<at + count].reduce(0) { $0 << 8 | Int($1) } }
        func le(_ at: Int, _ count: Int) -> Int { b[at..<at + count].reversed().reduce(0) { $0 << 8 | Int($1) } }
        if b.count >= 24, Array(b[0..<8]) == [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A] {
            let (w, h) = (be(16, 4), be(20, 4))
            return w > 0 && h > 0 ? (w, h) : nil
        }
        if b.count >= 30, Array(b[0..<4]) == Array("RIFF".utf8), Array(b[8..<12]) == Array("WEBP".utf8) {
            switch String(decoding: b[12..<16], as: UTF8.self) {
            case "VP8 ":
                guard Array(b[23..<26]) == [0x9D, 0x01, 0x2A] else { return nil }
                let (w, h) = (le(26, 2) & 0x3FFF, le(28, 2) & 0x3FFF)
                return w > 0 && h > 0 ? (w, h) : nil
            case "VP8L":
                guard b[20] == 0x2F else { return nil }
                let bits = le(21, 4)
                return ((bits & 0x3FFF) + 1, ((bits >> 14) & 0x3FFF) + 1)
            case "VP8X":
                return (le(24, 3) + 1, le(27, 3) + 1)
            default: return nil
            }
        }
        guard b.count > 4, b[0] == 0xFF, b[1] == 0xD8 else { return nil }
        var at = 2
        while at + 9 < b.count {
            guard b[at] == 0xFF else { return nil }
            let marker = b[at + 1]
            if marker == 0xFF { at += 1; continue }
            if (0xC0...0xCF).contains(marker) && ![0xC4, 0xC8, 0xCC].contains(marker) {
                let (h, w) = (be(at + 5, 2), be(at + 7, 2))
                return w > 0 && h > 0 ? (w, h) : nil
            }
            at += 2 + be(at + 2, 2)
        }
        return nil
    }
}

/// Resizing with ImageMagick, when it is installed (found on the PATH, never assumed).
enum ImageMagick {
    /// `magick` (ImageMagick 7) or else `convert` (ImageMagick 6), checked to really be ImageMagick.
    static func find(path: String? = ProcessInfo.processInfo.environment["PATH"]) -> String? {
        let dirs = (path ?? "").split(separator: ":", omittingEmptySubsequences: true).map(String.init).filter { $0.hasPrefix("/") }
        for name in ["magick", "convert"] {
            let file = findExecutable(name, in: dirs)
            if file.isEmpty { continue }
            if let (status, output) = try? RuntimeInstaller.run(file, ["-version"], timeout: 10), status == 0, output.contains("ImageMagick") { return file }
        }
        return nil
    }

    /// The format coder ImageMagick is told to use, from the file's first bytes. Only these are ever handed over, so a file
    /// cannot ask ImageMagick for a script, vector or remote-fetch format.
    static func coder(for data: Data) -> String? {
        let b = [UInt8](data.prefix(16))
        if b.count >= 3, b[0] == 0xFF, b[1] == 0xD8, b[2] == 0xFF { return "jpeg" }
        if b.count >= 8, Array(b[0..<8]) == [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A] { return "png" }
        if b.count >= 12, Array(b[0..<4]) == Array("RIFF".utf8), Array(b[8..<12]) == Array("WEBP".utf8) { return "webp" }
        if b.count >= 6, Array(b[0..<4]) == Array("GIF8".utf8) { return "gif" }
        if b.count >= 4, b[0..<4].elementsEqual([0x49, 0x49, 0x2A, 0x00]) || b[0..<4].elementsEqual([0x4D, 0x4D, 0x00, 0x2A]) { return "tiff" }
        if b.count >= 12, Array(b[4..<8]) == Array("ftyp".utf8), ["heic", "heix", "mif1", "msf1", "hevc", "heim", "heis"].contains(String(decoding: b[8..<12], as: UTF8.self)) { return "heic" }
        if b.count >= 2, b[0] == 0x42, b[1] == 0x4D { return "bmp" }
        return nil
    }

    /// Does what the Mac does: upright, longer side at most 1280, flattened onto white, JPEG at quality 85, no metadata.
    static func resize(_ data: Data, coder: String, program: String, timeout: TimeInterval = 60) throws -> Data {
        let fm = FileManager.default
        let folder = fm.temporaryDirectory.appendingPathComponent("bt-image-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? fm.removeItem(at: folder) }
        let input = folder.appendingPathComponent("in"), output = folder.appendingPathComponent("out.jpg")
        try data.write(to: input, options: .atomic)
        let side = ImageRules.maxSide
        let arguments = ["-limit", "memory", "512MiB", "-limit", "map", "1GiB", "-limit", "disk", "1GiB", "-limit", "time", "60",
                         "-limit", "width", "30000", "-limit", "height", "30000", "-limit", "area", "200MP",
                         "\(coder):\(input.path)[0]", "-auto-orient", "-resize", "\(side)x\(side)>",
                         "-background", "white", "-alpha", "remove", "-alpha", "off", "-strip",
                         "-quality", String(Int(ImageRules.jpegQuality * 100)), "jpeg:\(output.path)"]
        let status: Int32
        do { (status, _) = try RuntimeInstaller.run(program, arguments, timeout: timeout, directory: folder) }
        catch { throw BlackTeamError("Could not decode image.") }
        guard status == 0, let result = try? Data(contentsOf: output), ImageRules.kind(of: result) == .jpeg else { throw BlackTeamError("Could not decode image.") }
        return result
    }
}
