import Foundation
import ImageIO
import Testing
import TetherProtocol
import UniformTypeIdentifiers
@testable import SundownUI

/// Attachments are read and prepared off the main actor: an image Claude reads is sent as it came
/// unless it's larger than Claude reads, and only then drawn again, smaller.
@Suite
struct ComposerAttachmentTests {
    @Test func imagesAreKeptOrScaledDown() {
        #expect(Composer.imagePlan(type: .png, width: 1_440, height: 900) == .keep(.imagePng))
        #expect(Composer.imagePlan(type: .jpeg, width: 1_568, height: 1_000) == .keep(.imageJpeg))
        #expect(Composer.imagePlan(type: .gif, width: 400, height: 300) == .keep(.imageGif))
        #expect(Composer.imagePlan(type: .webP, width: 10, height: 1_568) == .keep(.imageWebp))
        // A Retina screenshot: still PNG, at the size Claude reads.
        #expect(Composer.imagePlan(type: .png, width: 2_880, height: 1_800) == .scale(longEdge: 1_568, jpeg: false))
        // A photo stays a photo.
        #expect(Composer.imagePlan(type: .jpeg, width: 4_032, height: 3_024) == .scale(longEdge: 1_568, jpeg: true))
        #expect(Composer.imagePlan(type: .heic, width: 4_032, height: 3_024) == .scale(longEdge: 1_568, jpeg: true))
        // A type Claude doesn't read is drawn again at its own size.
        #expect(Composer.imagePlan(type: .heic, width: 1_000, height: 800) == .scale(longEdge: 1_000, jpeg: true))
        #expect(Composer.imagePlan(type: .tiff, width: 800, height: 600) == .scale(longEdge: 800, jpeg: false))
        #expect(Composer.imagePlan(type: nil, width: 800, height: 600) == .scale(longEdge: 800, jpeg: false))
    }

    @Test func aSmallImageIsSentAsItCame() throws {
        let data = try Self.encoded(width: 200, height: 100, as: .jpeg)
        let attachment = try #require(Composer.prepareImage(data))
        let image = try #require(attachment.kind.image, "not an image")
        #expect(image.mediaType == .imageJpeg)
        #expect(Data(base64Encoded: image.base64) == data)
        // The chip's picture fills 56 points at 2x without being larger than the image.
        #expect(attachment.thumbnail?.width == 200)
    }

    @Test func aLargeImageIsScaledDownToWhatClaudeReads() throws {
        let data = try Self.encoded(width: 3_000, height: 2_000, as: .png)
        let attachment = try #require(Composer.prepareImage(data))
        let image = try #require(attachment.kind.image, "not an image")
        #expect(image.mediaType == .imagePng)
        let sent = try #require(Data(base64Encoded: image.base64).flatMap { CGImageSourceCreateWithData($0 as CFData, nil) })
        let properties = CGImageSourceCopyPropertiesAtIndex(sent, 0, nil) as? [CFString: Any]
        #expect(properties?[kCGImagePropertyPixelWidth] as? Int == 1_568)
        #expect(properties?[kCGImagePropertyPixelHeight] as? Int == 1_045)
        // Its short edge fills the chip.
        #expect(attachment.thumbnail.map { min($0.width, $0.height) } ?? 0 >= Composer.chipPixels - 1)
        #expect(attachment.thumbnail.map { max($0.width, $0.height) } ?? .max <= 1_024)
    }

    @Test func somethingThatIsntAnImageIsNotAttached() {
        #expect(Composer.prepareImage(Data("not an image".utf8)) == nil)
    }

    /// A text file goes with the message to a host that can't read it, if it's small; its size is
    /// checked before it's read.
    @Test func aRemoteHostGetsSmallTextFilesAndMentionsOfLargeOnes() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let small = folder.appending(path: "notes.txt"), large = folder.appending(path: "big.log")
        try Data("hello".utf8).write(to: small)
        try Data(repeating: UInt8(ascii: "a"), count: Composer.maxTextAttachment + 1).write(to: large)

        let text = try #require(Composer.read(file: small, hostIsLocal: false).attachment?.kind.text, "not attached as text")
        #expect(text.content == "hello" && text.name == "notes.txt")
        #expect(Composer.read(file: large, hostIsLocal: false).mention == large.path)
        // This Mac's Claude reads it where it is.
        #expect(Composer.read(file: small, hostIsLocal: true).mention != nil)
    }

    /// A prompt's image is decoded small, off the main actor, keeping the size it had whole.
    @Test func aPromptsImageIsDecodedSmallAtItsOwnSize() async throws {
        let data = try Self.encoded(width: 1_000, height: 500, as: .png)
        let decoded = try #require(await MessageImages.decode(data.base64EncodedString()))
        #expect(decoded.image.width == 480 && decoded.image.height == 240)
        #expect(decoded.size == CGSize(width: 1_000, height: 500))
        // Drawn at the whole image's size in points: 480 pixels over 1,000 points.
        let drawn = MessageImages.Decoded(decoded.image, size: decoded.size)
        #expect(abs(drawn.scale - 0.48) < 0.001)
        #expect(await MessageImages.decode("not base64") == nil)
    }

    private static func encoded(width: Int, height: Int, as type: UTType) throws -> Data {
        let context = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                             space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(red: 0.2, green: 0.5, blue: 0.8, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width / 2, height: height))
        let image = try #require(context.makeImage())
        let data = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
        return data as Data
    }
}
