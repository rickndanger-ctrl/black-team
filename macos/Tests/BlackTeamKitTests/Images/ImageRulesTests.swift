import XCTest
import ImageIO
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
        let wide = try ImagePreparer.prepare(data: TestImage.png(width: 4000, height: 3000), name: "huge.png")
        let size = try XCTUnwrap(ImagePreparer.dimensions(of: wide.data))
        XCTAssertEqual(size.width, 1280)
        XCTAssertEqual(size.height, 960)
        XCTAssertEqual(ImageRules.kind(of: wide.data), .jpeg)
        XCTAssertLessThanOrEqual(wide.data.count, ImageRules.maxBytes)
        let tall = try ImagePreparer.prepare(data: TestImage.png(width: 1500, height: 3000), name: "tall.png")
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
        // 200 wide by 100 high, tagged "rotate 90 clockwise to display": it shows as 100 wide by 200 high.
        let tagged = TestImage.jpeg(width: 200, height: 100, properties: [kCGImagePropertyOrientation: 6])
        let prepared = try ImagePreparer.prepare(data: tagged, name: "phone.jpg")
        let size = try XCTUnwrap(ImagePreparer.dimensions(of: prepared.data))
        XCTAssertEqual(size.width, 100)
        XCTAssertEqual(size.height, 200)
        // And the result carries no orientation tag that would turn it a second time.
        XCTAssertNil(TestImage.properties(prepared.data)[kCGImagePropertyOrientation].flatMap { ($0 as? NSNumber)?.intValue }.flatMap { $0 == 1 ? nil : $0 })
    }

    func testOutputIsAJpegWithNoMetadata() throws {
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
    }

    func testTransparencyIsFlattenedOntoWhite() throws {
        let prepared = try ImagePreparer.prepare(data: TestImage.png(width: 32, height: 32, alpha: 0), name: "clear.png")
        let (r, g, b) = TestImage.pixel(prepared.data, x: 16, y: 16)
        XCTAssertGreaterThan(r, 245); XCTAssertGreaterThan(g, 245); XCTAssertGreaterThan(b, 245)
    }

    func testOtherFormatsMacCanReadAreAccepted() throws {
        let tiff = TestImage.encode(TestImage.cgImage(width: 40, height: 30), type: .tiff)
        XCTAssertEqual(ImagePreparer.dimensions(of: try ImagePreparer.prepare(data: tiff, name: "scan.tiff").data)?.width, 40)
        let gif = TestImage.encode(TestImage.cgImage(width: 20, height: 20), type: .gif)
        XCTAssertEqual(ImageRules.kind(of: try ImagePreparer.prepare(data: gif, name: "a.gif").data), .jpeg)
    }

    func testNotAnImageAndTooBigSourcesAreRefused() {
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
