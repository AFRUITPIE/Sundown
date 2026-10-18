import TetherProtocol
@testable import SundownUI

// Test-only views of the enums' cases, so a test can `try #require` one rather than `guard case`.

extension Composer.Attachment.Kind {
    var image: (base64: String, mediaType: UserInput.Image.MediaType)? {
        if case .image(let base64, let mediaType) = self { (base64, mediaType) } else { nil }
    }
    var text: (content: String, name: String)? {
        if case .text(let content, let name) = self { (content, name) } else { nil }
    }
}

extension Composer.Prepared {
    var attachment: Composer.Attachment? { if case .attachment(let attachment) = self { attachment } else { nil } }
    var mention: String? { if case .mention(let path) = self { path } else { nil } }
}
