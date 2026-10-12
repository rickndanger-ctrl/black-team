import Foundation

// Image attachments, the rules of `companion-images.cjs` and `src/ImageAttachments.jsx`: up to 4 images a message,
// PNG, JPEG or WebP data of at most 1 MB each after resizing, checked by their magic numbers.

/// One prepared image on its way into a message: the name to show and the encoded bytes. Nothing is stored yet.
public struct ImageUpload: Equatable, Sendable {
    public var name: String
    public var data: Data
    public init(name: String, data: Data) { self.name = name; self.data = data }
}

/// What a message keeps of an attached image: the file is in the data folder, never in the conversation.
public struct ImageRef: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var bytes: Int
    public var width: Int
    public var height: Int

    public var json: JSONValue {
        ["id": .string(id), "name": .string(name), "bytes": .number(Double(bytes)), "width": .number(Double(width)), "height": .number(Double(height))]
    }

    /// A message's `images` entry, or nil when it is not shaped like one (an edited or damaged file).
    public init?(_ json: JSONValue) {
        guard let id = json["id"]?.string, History.validID(id), let name = json["name"]?.string, name.utf16.count <= 200,
              let bytes = json["bytes"]?.int, let width = json["width"]?.int, let height = json["height"]?.int else { return nil }
        self.id = id; self.name = name; self.bytes = bytes; self.width = width; self.height = height
    }

    public init(id: String, name: String, bytes: Int, width: Int, height: Int) {
        self.id = id; self.name = name; self.bytes = bytes; self.width = width; self.height = height
    }
}

public enum ImageRules {
    public static let maxImages = 4
    /// After resizing, one image may be at most 1 MB.
    public static let maxBytes = 1024 * 1024
    /// A file chosen by the person may be at most 20 MB before it is resized.
    public static let maxSourceBytes = 20 * 1024 * 1024
    public static let maxSide = 1280
    public static let jpegQuality = 0.85
    public static let defaultMessage = "Describe these images."
    public static let tooManyMessage = "Choose up to 4 images."
    public static let tooManyPerMessage = "Choose up to 4 images per message."
    public static let badTypeMessage = "Use PNG, JPEG or WebP images up to 1 MB after resizing."
    public static let badDataMessage = "The image data is invalid. Choose the image again."
    public static let invalidAttachment = "Invalid image attachment."
    public static let codeRefusal = "Use Chat mode to send images in this local test."
    public static let needsVisionFile = "Image chat needs a vision-capable model and its matching projector loaded. This model has no vision file yet: add its projector (mmproj) first."
    public static let visionRequired = "Image chat needs a vision-capable model and its matching projector loaded. Check the server vision configuration."

    public enum Kind: String, Sendable { case png, jpeg, webp
        public var mime: String { "image/" + rawValue }
        public var fileExtension: String { self == .jpeg ? "jpg" : rawValue }
    }

    /// The type the first bytes say it is, or nil. The same three checks as the JavaScript.
    public static func kind(of data: Data) -> Kind? {
        let bytes = [UInt8](data.prefix(12))
        if bytes.count >= 8, bytes[0..<8].elementsEqual([137, 80, 78, 71, 13, 10, 26, 10]) { return .png }
        if bytes.count >= 3, bytes[0] == 255, bytes[1] == 216, bytes[2] == 255 { return .jpeg }
        if bytes.count >= 12, bytes[0..<4].elementsEqual(Array("RIFF".utf8)), bytes[8..<12].elementsEqual(Array("WEBP".utf8)) { return .webp }
        return nil
    }

    /// Throws the daily app's message for the first thing wrong; returns the type of each image.
    @discardableResult
    public static func validate(_ images: [ImageUpload]) throws -> [Kind] {
        if images.count > maxImages { throw BlackTeamError(tooManyMessage) }
        return try images.map { image in
            if image.name.utf16.count > 200 { throw BlackTeamError(invalidAttachment) }
            guard let kind = kind(of: image.data), image.data.count <= maxBytes else {
                throw BlackTeamError(image.data.count > maxBytes ? badTypeMessage : badDataMessage)
            }
            return kind
        }
    }

    /// A short digest of the images for the request fingerprint: names and content, not the bytes themselves.
    static func digest(_ images: [ImageUpload]) -> JSONValue {
        .array(images.map { ["name": .string($0.name), "sha256": .string(SHA256.hash(data: $0.data).map { String(format: "%02x", $0) }.joined())] })
    }

    /// The content a model receives for a message with images: its text, then one `image_url` part per image.
    public static func modelContent(text: String, dataURLs: [String]) -> JSONValue {
        .array([["type": "text", "text": .string(text)]] + dataURLs.map { ["type": "image_url", "image_url": ["url": .string($0)]] })
    }

    public static func dataURL(_ data: Data, mime: String) -> String { "data:\(mime);base64,\(data.base64EncodedString())" }
}
