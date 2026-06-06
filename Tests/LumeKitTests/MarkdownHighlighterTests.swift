import Testing
import Foundation
@testable import LumeKit

struct MarkdownHighlighterTests {
    private func kinds(_ text: String) -> [HighlightKind] {
        MarkdownHighlighter.tokens(in: text).map(\.kind)
    }

    @Test func detectsHeading() {
        let text = "# Title"
        let tokens = MarkdownHighlighter.tokens(in: text)
        #expect(tokens.contains { $0.kind == .heading && $0.range == NSRange(location: 0, length: 7) })
    }

    @Test func detectsStrongAndEmphasis() {
        #expect(kinds("a **bold** b").contains(.strong))
        #expect(kinds("a _italic_ b").contains(.emphasis))
    }

    @Test func detectsInlineCodeAndLink() {
        #expect(kinds("use `code` here").contains(.code))
        #expect(kinds("see [docs](https://x.y)").contains(.link))
    }

    @Test func plainTextHasNoTokens() {
        #expect(MarkdownHighlighter.tokens(in: "just plain words").isEmpty)
    }
}
