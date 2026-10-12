import XCTest
#if canImport(ImageIO)
import ImageIO
#endif
#if os(Linux)
import Glibc
#endif
@testable import BlackTeamKit

final class ImageRulesTests: XCTestCase {
    func upload(_ data: Data = TestImage.jpeg(), name: String = "a.jpg") -> ImageUpload { ImageUpload(name: name, data: data) }

    func testUpToFourImagesAreAccepted() throws {
        XCTAssertEqual(try ImageRules.validate([]), [])
        XCTAssertEqual(try ImageRules.validate(Array(repeating: upload(), count: 4)), Array(repeating: .jpeg, count: 4))
    }

    func testFiveImagesAreRefused() {
        XCTAssertThrowsError(try ImageRules.validate(Array(repeating: upload(), count: 5))) { XCTAssertEqual($0 as? BlackTeamError, BlackTeamError("Choose up to 4 images.")) }
    }

    func testMagicNumbersDecideTheType() throws {
        XCTAssertEqual(ImageRules.kind(of: TestImage.png()), .png)
        XCTAssertEqual(ImageRules.kind(of: TestImage.jpeg()), .jpeg)
        var webp = Data("RIFF".utf8); webp.append(contentsOf: [0, 0, 0, 0]); webp.append(Data("WEBPVP8 ".utf8))
        XCTAssertEqual(ImageRules.kind(of: webp), .webp)
        XCTAssertNil(ImageRules.kind(of: Data("GIF89a".utf8)))
        XCTAssertNil(ImageRules.kind(of: Data("%PDF-1.7 not an image".utf8)))
        XCTAssertNil(ImageRules.kind(of: Data()))
    }

    func testBadMagicAndWrongTypeAreRefusedWithTheDailyWording() {
        XCTAssertThrowsError(try ImageRules.validate([upload(Data("not an image at all".utf8))])) {
            XCTAssertEqual($0 as? BlackTeamError, BlackTeamError("The image data is invalid. Choose the image again."))
        }
        // A PNG whose signature is damaged.
        var broken = TestImage.png(); broken[1] = 0
        XCTAssertThrowsError(try ImageRules.validate([upload(broken)])) { XCTAssertEqual(messageOf($0), ImageRules.badDataMessage) }
    }

    func testOversizeAndLongNamesAreRefused() {
        var big = TestImage.jpeg(); big.append(Data(repeating: 0, count: ImageRules.maxBytes))
        XCTAssertThrowsError(try ImageRules.validate([upload(big)])) { XCTAssertEqual(messageOf($0), "Use PNG, JPEG or WebP images up to 1 MB after resizing.") }
        XCTAssertThrowsError(try ImageRules.validate([upload(name: String(repeating: "n", count: 201))])) { XCTAssertEqual(messageOf($0), "Invalid image attachment.") }
        XCTAssertNoThrow(try ImageRules.validate([upload(name: String(repeating: "n", count: 200))]))
    }

    func testModelContentIsTextThenOneImagePartEach() {
        let content = ImageRules.modelContent(text: "What is this?", dataURLs: ["data:image/jpeg;base64,AAAA", "data:image/png;base64,BBBB"])
        XCTAssertEqual(content.array?.count, 3)
        XCTAssertEqual(content[0], ["type": "text", "text": "What is this?"])
        XCTAssertEqual(content[1], ["type": "image_url", "image_url": ["url": "data:image/jpeg;base64,AAAA"]])
        XCTAssertEqual(content[2]?["image_url"]?["url"]?.string, "data:image/png;base64,BBBB")
    }

    // MARK: Preparation

    func testALargeImageIsScaledToTheLongSide1280() throws {
        #if !canImport(ImageIO)
        let wide = try ImagePreparer.prepare(data: try LinuxPicture.make(width: 4000, height: 3000, format: "png"), name: "huge.png")
        #else
        let wide = try ImagePreparer.prepare(data: TestImage.png(width: 4000, height: 3000), name: "huge.png")
        #endif
        let size = try XCTUnwrap(ImagePreparer.dimensions(of: wide.data))
        XCTAssertEqual(size.width, 1280)
        XCTAssertEqual(size.height, 960)
        XCTAssertEqual(ImageRules.kind(of: wide.data), .jpeg)
        XCTAssertLessThanOrEqual(wide.data.count, ImageRules.maxBytes)
        #if !canImport(ImageIO)
        let tall = try ImagePreparer.prepare(data: try LinuxPicture.make(width: 1500, height: 3000, format: "png"), name: "tall.png")
        #else
        let tall = try ImagePreparer.prepare(data: TestImage.png(width: 1500, height: 3000), name: "tall.png")
        #endif
        XCTAssertEqual(ImagePreparer.dimensions(of: tall.data)?.height, 1280)
        XCTAssertEqual(ImagePreparer.dimensions(of: tall.data)?.width, 640)
    }

    func testASmallImageIsNotEnlarged() throws {
        let small = try ImagePreparer.prepare(data: TestImage.png(width: 100, height: 50), name: "small.png")
        XCTAssertEqual(ImagePreparer.dimensions(of: small.data)?.width, 100)
        XCTAssertEqual(ImagePreparer.dimensions(of: small.data)?.height, 50)
        XCTAssertEqual(small.name, "small.png")
    }

    func testExifOrientationIsApplied() throws {
        #if !canImport(ImageIO)
        // 200 wide by 100 high, tagged "turn to display": it shows as 100 wide by 200 high.
        let tagged = TestImage.inject(exifInto: try LinuxPicture.make(width: 200, height: 100, format: "jpg"), orientation: 6)
        XCTAssertEqual(ImageStripper.jpegOrientation(tagged), 6)
        let prepared = try ImagePreparer.prepare(data: tagged, name: "phone.jpg")
        let size = try XCTUnwrap(ImagePreparer.dimensions(of: prepared.data))
        XCTAssertEqual(size.width, 100)
        XCTAssertEqual(size.height, 200)
        XCTAssertEqual(ImageStripper.jpegOrientation(prepared.data), 1)
        #else
        // 200 wide by 100 high, tagged "rotate 90 clockwise to display": it shows as 100 wide by 200 high.
        let tagged = TestImage.jpeg(width: 200, height: 100, properties: [kCGImagePropertyOrientation: 6])
        let prepared = try ImagePreparer.prepare(data: tagged, name: "phone.jpg")
        let size = try XCTUnwrap(ImagePreparer.dimensions(of: prepared.data))
        XCTAssertEqual(size.width, 100)
        XCTAssertEqual(size.height, 200)
        // And the result carries no orientation tag that would turn it a second time.
        XCTAssertNil(TestImage.properties(prepared.data)[kCGImagePropertyOrientation].flatMap { ($0 as? NSNumber)?.intValue }.flatMap { $0 == 1 ? nil : $0 })
        #endif
    }

    func testOutputIsAJpegWithNoMetadata() throws {
        #if !canImport(ImageIO)
        let source = TestImage.jpeg(width: 80, height: 60, exif: true)
        XCTAssertTrue(String(decoding: source, as: UTF8.self).contains("private note"), "the test picture must carry EXIF and GPS")
        let prepared = try ImagePreparer.prepare(data: source, name: "geo.jpg")
        XCTAssertEqual(ImageRules.kind(of: prepared.data), .jpeg)
        let text = String(decoding: prepared.data, as: UTF8.self)
        XCTAssertFalse(text.contains("private note")); XCTAssertFalse(text.contains("SecretCam")); XCTAssertFalse(text.contains("Exif"))
        XCTAssertEqual(ImagePreparer.dimensions(of: prepared.data)?.width, 80)
        XCTAssertEqual(ImagePreparer.dimensions(of: prepared.data)?.height, 60)
        #else
        let gps: [CFString: Any] = [kCGImagePropertyGPSDictionary: [kCGImagePropertyGPSLatitude: 51.5, kCGImagePropertyGPSLongitude: -0.12, kCGImagePropertyGPSLatitudeRef: "N", kCGImagePropertyGPSLongitudeRef: "W"],
                                    kCGImagePropertyExifDictionary: [kCGImagePropertyExifUserComment: "private note"],
                                    kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFMake: "SecretCam"]]
        let source = TestImage.jpeg(width: 80, height: 60, properties: gps)
        XCTAssertNotNil(TestImage.properties(source)[kCGImagePropertyGPSDictionary], "the test picture must carry GPS")
        let prepared = try ImagePreparer.prepare(data: source, name: "geo.jpg")
        XCTAssertEqual(ImageRules.kind(of: prepared.data), .jpeg)
        let found = TestImage.properties(prepared.data)
        XCTAssertNil(found[kCGImagePropertyGPSDictionary])
        XCTAssertNil(found[kCGImagePropertyTIFFDictionary])
        XCTAssertNil((found[kCGImagePropertyExifDictionary] as? [CFString: Any])?[kCGImagePropertyExifUserComment])
        XCTAssertFalse(String(decoding: prepared.data, as: UTF8.self).contains("private note"))
        XCTAssertFalse(String(decoding: prepared.data, as: UTF8.self).contains("SecretCam"))
        #endif
    }

    func testTransparencyIsFlattenedOntoWhite() throws {
        #if !canImport(ImageIO)
        // (A transparent picture already within the limits is kept as it is; this one is too wide, so it is redrawn.)
        let prepared = try ImagePreparer.prepare(data: try LinuxPicture.make(width: 1500, height: 40, format: "png", color: "none"), name: "clear.png")
        XCTAssertEqual(ImageRules.kind(of: prepared.data), .jpeg)
        XCTAssertTrue(["srgb(255,255,255)", "gray(255)"].contains(try LinuxPicture.pixel(prepared.data, x: 16, y: 16)))
        #else
        let prepared = try ImagePreparer.prepare(data: TestImage.png(width: 32, height: 32, alpha: 0), name: "clear.png")
        let (r, g, b) = TestImage.pixel(prepared.data, x: 16, y: 16)
        XCTAssertGreaterThan(r, 245); XCTAssertGreaterThan(g, 245); XCTAssertGreaterThan(b, 245)
        #endif
    }

    func testOtherFormatsMacCanReadAreAccepted() throws {
        #if !canImport(ImageIO)
        let tiff = try LinuxPicture.make(width: 40, height: 30, format: "tiff")
        XCTAssertEqual(ImagePreparer.dimensions(of: try ImagePreparer.prepare(data: tiff, name: "scan.tiff").data)?.width, 40)
        let gif = try LinuxPicture.make(width: 20, height: 20, format: "gif")
        XCTAssertEqual(ImageRules.kind(of: try ImagePreparer.prepare(data: gif, name: "a.gif").data), .jpeg)
        #else
        let tiff = TestImage.encode(TestImage.cgImage(width: 40, height: 30), type: .tiff)
        XCTAssertEqual(ImagePreparer.dimensions(of: try ImagePreparer.prepare(data: tiff, name: "scan.tiff").data)?.width, 40)
        let gif = TestImage.encode(TestImage.cgImage(width: 20, height: 20), type: .gif)
        XCTAssertEqual(ImageRules.kind(of: try ImagePreparer.prepare(data: gif, name: "a.gif").data), .jpeg)
        #endif
    }

    func testNotAnImageAndTooBigSourcesAreRefused() throws {
        XCTAssertThrowsError(try ImagePreparer.prepare(data: Data("hello".utf8), name: "x.txt")) { XCTAssertEqual(messageOf($0), ImagePreparer.notAnImage) }
        XCTAssertThrowsError(try ImagePreparer.prepare(data: Data(count: ImageRules.maxSourceBytes + 1), name: "x.png")) { XCTAssertEqual(messageOf($0), "Choose an image smaller than 20 MB.") }
    }

    func testPreparingAFileRefusesOneOver20MB() throws {
        let dir = makeTemporaryFolder(self)
        let path = dir + "/big.png"
        FileManager.default.createFile(atPath: path, contents: Data(count: ImageRules.maxSourceBytes + 1))
        XCTAssertThrowsError(try ImagePreparer.prepare(url: URL(fileURLWithPath: path))) { XCTAssertEqual(messageOf($0), ImagePreparer.tooBigSource) }
        let good = dir + "/ok.png"
        try TestImage.png().write(to: URL(fileURLWithPath: good))
        XCTAssertEqual(try ImagePreparer.prepare(url: URL(fileURLWithPath: good)).name, "ok.png")
        XCTAssertThrowsError(try ImagePreparer.prepare(url: URL(fileURLWithPath: dir + "/missing.png")))
    }

    // MARK: Storage

    func testStoredFilesArePrivateAndReadBack() throws {
        let dir = makeTemporaryFolder(self)
        let store = ImageStore(dataFolder: dir)
        let thread = newID()
        let image = upload(TestImage.jpeg(width: 30, height: 20))
        let refs = try store.save([image], kinds: [.jpeg], threadId: thread)
        XCTAssertEqual(refs.count, 1)
        XCTAssertEqual(refs[0].width, 30); XCTAssertEqual(refs[0].height, 20); XCTAssertEqual(refs[0].bytes, image.data.count)
        let folder = dir + "/attachments/" + thread
        XCTAssertEqual(mode(dir + "/attachments"), 0o700)
        XCTAssertEqual(mode(folder), 0o700)
        XCTAssertEqual(mode("\(folder)/\(refs[0].id).jpg"), 0o600)
        let back = try store.read(threadId: thread, imageId: refs[0].id)
        XCTAssertEqual(back.data, image.data)
        XCTAssertEqual(back.mime, "image/jpeg")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder).count, 1, "no temporary file is left")
    }

    func testIdsAreValidatedAndTraversalIsRefused() throws {
        let dir = makeTemporaryFolder(self)
        let store = ImageStore(dataFolder: dir)
        let thread = newID()
        let ref = try store.save([upload()], kinds: [.jpeg], threadId: thread)[0]
        for bad in ["../x", "..", "", "../../etc/passwd", ref.id + "/../" + ref.id, "ABCDEF"] {
            XCTAssertThrowsError(try store.read(threadId: thread, imageId: bad), bad)
            XCTAssertThrowsError(try store.read(threadId: bad, imageId: ref.id), bad)
        }
        XCTAssertThrowsError(try store.save([upload()], kinds: [.jpeg], threadId: "../escape"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir + "/escape"))
        // A file that is really a link to somewhere else is not followed.
        let secret = dir + "/secret.jpg"
        try TestImage.jpeg().write(to: URL(fileURLWithPath: secret))
        let linked = newID()
        try FileManager.default.createDirectory(atPath: "\(dir)/attachments/\(thread)", withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: "\(dir)/attachments/\(thread)/\(linked).jpg", withDestinationPath: secret)
        XCTAssertThrowsError(try store.read(threadId: thread, imageId: linked))
        // A conversation folder that is a link to elsewhere is refused too.
        let other = newID()
        try FileManager.default.createSymbolicLink(atPath: "\(dir)/attachments/\(other)", withDestinationPath: dir)
        XCTAssertThrowsError(try store.read(threadId: other, imageId: ref.id))
    }

    func testRemovingAFailedSubmitsFilesLeavesNothing() throws {
        let dir = makeTemporaryFolder(self)
        let store = ImageStore(dataFolder: dir)
        let thread = newID()
        let refs = try store.save([upload(), upload()], kinds: [.jpeg, .jpeg], threadId: thread)
        store.remove(refs, threadId: thread)
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir + "/attachments/" + thread))
    }

    func testReferencesRoundTripAndRejectMalformedOnes() {
        let ref = ImageRef(id: newID(), name: "a.jpg", bytes: 10, width: 2, height: 3)
        XCTAssertEqual(ImageRef(ref.json), ref)
        XCTAssertNil(ImageRef(["id": "../x", "name": "a", "bytes": 1, "width": 1, "height": 1]))
        XCTAssertNil(ImageRef(["name": "a"]))
    }
}

#if !canImport(ImageIO)
/// Linux picture preparation: metadata stripping that needs no extra program, the message without ImageMagick, and the
/// ImageMagick path (those tests are skipped, saying so, when ImageMagick is not installed).
final class LinuxImageTests: XCTestCase {
    private func withoutImageMagick<T>(_ body: () throws -> T) rethrows -> T {
        let saved = ImagePreparer.searchPath
        ImagePreparer.searchPath = "/nonexistent-bt-folder"
        defer { ImagePreparer.searchPath = saved }
        return try body()
    }

    func testAJpegWithAGPSBlockComesOutWithoutItAndWithTheSameSize() throws {
        let source = TestImage.jpeg(width: 321, height: 123, exif: true)
        XCTAssertTrue(String(decoding: source, as: UTF8.self).contains("GPSLatitude"))
        let prepared = try ImagePreparer.prepare(data: source, name: "geo.jpg")
        XCTAssertFalse(String(decoding: prepared.data, as: UTF8.self).contains("GPSLatitude"))
        XCTAssertFalse(prepared.data.range(of: Data("Exif".utf8)) != nil)
        XCTAssertEqual(ImagePreparer.dimensions(of: prepared.data)?.width, 321)
        XCTAssertEqual(ImagePreparer.dimensions(of: prepared.data)?.height, 123)
        XCTAssertLessThan(prepared.data.count, source.count)
        // The segments that are not metadata (JFIF, the frame header) are untouched.
        XCTAssertNotNil(prepared.data.range(of: Data("JFIF".utf8)))
    }

    func testARealJpegStillDecodesAfterItsMetadataIsRemoved() throws {
        let real = try LinuxPicture.make(width: 300, height: 200, format: "jpg")
        let tagged = TestImage.inject(exifInto: real)
        XCTAssertTrue(String(decoding: tagged, as: UTF8.self).contains("GPSLatitude"))
        let prepared = try ImagePreparer.prepare(data: tagged, name: "real.jpg")
        XCTAssertFalse(String(decoding: prepared.data, as: UTF8.self).contains("GPSLatitude"))
        XCTAssertEqual(try LinuxPicture.size(prepared.data), "300x200")
    }

    func testPngTextAndExifChunksAreDroppedAndTheRestKept() throws {
        func chunk(_ type: String, _ body: [UInt8]) -> [UInt8] {
            let n = body.count
            return [UInt8(n >> 24 & 255), UInt8(n >> 16 & 255), UInt8(n >> 8 & 255), UInt8(n & 255)] + Array(type.utf8) + body + [1, 2, 3, 4]
        }
        let ihdr: [UInt8] = [0, 0, 0, 40, 0, 0, 0, 30, 8, 2, 0, 0, 0]
        let signature: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
        let png = Data(signature + chunk("IHDR", ihdr) + chunk("tEXt", Array("Comment\0private note".utf8)) + chunk("eXIf", Array("GPSLatitude".utf8))
                       + chunk("iTXt", Array("XML:com.adobe.xmp".utf8)) + chunk("zTXt", [1, 2]) + chunk("IDAT", [9, 9, 9]) + chunk("IEND", []))
        let prepared = try ImagePreparer.prepare(data: png, name: "a.png")
        XCTAssertEqual(prepared.data, Data(signature + chunk("IHDR", ihdr) + chunk("IDAT", [9, 9, 9]) + chunk("IEND", [])))
        XCTAssertEqual(ImagePreparer.dimensions(of: prepared.data)?.width, 40)
        // A PNG that stops before IEND is not accepted as it is.
        XCTAssertThrowsError(try ImagePreparer.prepare(data: Data(png.prefix(png.count - 20)), name: "cut.png"))
    }

    func testWebPExifAndXmpChunksAreDropped() throws {
        func le(_ n: Int) -> [UInt8] { [UInt8(n & 255), UInt8(n >> 8 & 255), UInt8(n >> 16 & 255), UInt8(n >> 24 & 255)] }
        func chunk(_ type: String, _ body: [UInt8]) -> [UInt8] { Array(type.utf8) + le(body.count) + body + (body.count % 2 == 1 ? [0] : []) }
        let vp8x: [UInt8] = [0x0C, 0, 0, 0] + [49, 0, 0] + [29, 0, 0]           // 50 x 30, EXIF and XMP flags set
        let body = Array("WEBP".utf8) + chunk("VP8X", vp8x) + chunk("VP8 ", [1, 2, 3, 4, 5]) + chunk("EXIF", Array("GPSLatitude".utf8)) + chunk("XMP ", Array("<x/>".utf8))
        let webp = Data(Array("RIFF".utf8) + le(body.count) + body)
        XCTAssertEqual(ImagePreparer.dimensions(of: webp)?.width, 50)
        let prepared = try ImagePreparer.prepare(data: webp, name: "a.webp")
        XCTAssertFalse(String(decoding: prepared.data, as: UTF8.self).contains("GPSLatitude"))
        XCTAssertEqual(ImageRules.kind(of: prepared.data), .webp)
        XCTAssertEqual(ImagePreparer.dimensions(of: prepared.data)?.height, 30)
        XCTAssertEqual(prepared.data[20] & 0x0C, 0)
        let riffSize = Int(prepared.data[4]) | Int(prepared.data[5]) << 8 | Int(prepared.data[6]) << 16
        XCTAssertEqual(riffSize, prepared.data.count - 8)
    }

    func testAPictureThatNeedsResizingIsRefusedPlainlyWithoutImageMagick() throws {
        let big = TestImage.png(width: 4000, height: 3000)
        try withoutImageMagick {
            XCTAssertThrowsError(try ImagePreparer.prepare(data: big, name: "huge.png")) {
                XCTAssertEqual(($0 as? BlackTeamError)?.message, "This picture needs resizing first. On Linux, Black Team can resize pictures when ImageMagick is installed, or you can send a JPEG or PNG up to 1280 pixels and 1 MB.")
            }
            // Over 1 MB with a small size is also a resize.
            var heavy = TestImage.jpeg(width: 100, height: 100); heavy.append(Data(count: ImageRules.maxBytes))
            XCTAssertThrowsError(try ImagePreparer.prepare(data: heavy, name: "heavy.jpg")) { XCTAssertTrue(($0 as? BlackTeamError)?.message.hasPrefix("This picture needs resizing first.") == true) }
            // Something that is no picture at all is told so.
            XCTAssertThrowsError(try ImagePreparer.prepare(data: Data("<svg xmlns='http://www.w3.org/2000/svg'/>".utf8), name: "x.svg")) { XCTAssertEqual(($0 as? BlackTeamError)?.message, ImagePreparer.notAnImage) }
        }
    }

    func testOrientationIsReadFromTheExifBlock() {
        XCTAssertEqual(ImageStripper.jpegOrientation(TestImage.jpeg(exif: true)), 1)
        XCTAssertEqual(ImageStripper.jpegOrientation(TestImage.jpeg(exif: true, orientation: 6)), 6)
        XCTAssertEqual(ImageStripper.jpegOrientation(TestImage.jpeg()), 1)
    }

    func testAnOversizedJpegIsResizedWithImageMagick() throws {
        let big = try LinuxPicture.make(width: 3000, height: 2000, format: "jpg", extra: ["-comment", "private note"])
        let prepared = try ImagePreparer.prepare(data: big, name: "big.jpg")
        XCTAssertEqual(ImagePreparer.dimensions(of: prepared.data)?.width, 1280)
        XCTAssertEqual(ImagePreparer.dimensions(of: prepared.data)?.height, 853)
        XCTAssertLessThanOrEqual(prepared.data.count, ImageRules.maxBytes)
        XCTAssertFalse(String(decoding: prepared.data, as: UTF8.self).contains("private note"))
    }

    func testImageMagickIsNeverHandedAScriptOrVectorFormat() {
        for text in ["<svg xmlns='http://www.w3.org/2000/svg' width='9' height='9'/>", "push graphic-context\nviewbox 0 0 9 9\npop graphic-context", "%!PS-Adobe-3.0\n", "https://example.com/x.png"] {
            XCTAssertNil(ImageMagick.coder(for: Data(text.utf8)), text)
        }
    }
}
#endif
