import Foundation
import cmark_gfm
import cmark_gfm_extensions

/// cmark-gfm's parse of a document, read in place.
///
/// swift-markdown parses with the same cmark-gfm and then converts the whole tree into its own
/// values. Sampled on a 10MB document, cmark was about 5% of a parse; the conversion was 37% and
/// walking the converted tree, mostly dynamic casts from `any Markup` and child wrappers made per
/// visit, another 42%. The parser needs a node's type, its source positions and a few strings, all of
/// which cmark's nodes already hold, so it reads them there. The options and extensions are the ones
/// swift-markdown's `Document(parsing:)` uses, and positions are adjusted as it adjusts them, so both
/// describe a document identically; `ParserDifferentialTests` holds them to that.
final class MarkdownTree {
    enum Kind {
        case document, blockQuote, list, listItem, codeBlock, htmlBlock, paragraph, heading, thematicBreak
        case text, softBreak, lineBreak, inlineCode, inlineHTML, emphasis, strong, link, image
        case strikethrough, table, other
    }

    /// One-based lines and UTF-8 columns; the upper bound is one past the node's last byte.
    struct Range {
        var lowerLine: Int, lowerColumn: Int, upperLine: Int, upperColumn: Int
    }

    /// Valid while the tree it came from is alive.
    struct Node {
        fileprivate let pointer: UnsafeMutablePointer<cmark_node>

        var kind: Kind {
            switch cmark_node_get_type(pointer) {
            case CMARK_NODE_DOCUMENT: return .document
            case CMARK_NODE_BLOCK_QUOTE: return .blockQuote
            case CMARK_NODE_LIST: return .list
            case CMARK_NODE_ITEM: return .listItem
            case CMARK_NODE_CODE_BLOCK: return .codeBlock
            case CMARK_NODE_HTML_BLOCK: return .htmlBlock
            case CMARK_NODE_PARAGRAPH: return .paragraph
            case CMARK_NODE_HEADING: return .heading
            case CMARK_NODE_THEMATIC_BREAK: return .thematicBreak
            case CMARK_NODE_TEXT: return .text
            case CMARK_NODE_SOFTBREAK: return .softBreak
            case CMARK_NODE_LINEBREAK: return .lineBreak
            case CMARK_NODE_CODE: return .inlineCode
            case CMARK_NODE_HTML_INLINE: return .inlineHTML
            case CMARK_NODE_EMPH: return .emphasis
            case CMARK_NODE_STRONG: return .strong
            case CMARK_NODE_LINK: return .link
            case CMARK_NODE_IMAGE: return .image
            default:
                // Extension types are numbered when the extension registers and named only by string.
                guard let name = cmark_node_get_type_string(pointer) else { return .other }
                if strcmp(name, "strikethrough") == 0 { return .strikethrough }
                if strcmp(name, "table") == 0 { return .table }
                return .other
            }
        }

        var isBlock: Bool { cmark_node_get_type(pointer).rawValue & UInt32(CMARK_NODE_TYPE_MASK) == UInt32(CMARK_NODE_TYPE_BLOCK) }

        /// Where cmark found the node, or nil when it did not track it. A code span's positions are
        /// widened to take in its backticks.
        var range: Range? {
            let startLine = Int(cmark_node_get_start_line(pointer)), startColumn = Int(cmark_node_get_start_column(pointer))
            guard startLine > 0, startColumn > 0 else { return nil }
            let endLine = Int(cmark_node_get_end_line(pointer)), endColumn = Int(cmark_node_get_end_column(pointer)) + 1
            guard endLine > 0, endColumn > 0 else { return nil }
            let backticks = Int(cmark_node_get_backtick_count(pointer))
            let range = Range(lowerLine: startLine, lowerColumn: startColumn - backticks, upperLine: endLine, upperColumn: endColumn + backticks)
            // cmark sometimes reports an end before the start.
            guard (range.lowerLine, range.lowerColumn) <= (range.upperLine, range.upperColumn) else { return nil }
            return range
        }

        var firstChild: Node? { cmark_node_first_child(pointer).map(Node.init) }
        var lastChild: Node? { cmark_node_last_child(pointer).map(Node.init) }
        var children: Children { Children(cursor: cmark_node_first_child(pointer)) }

        var headingLevel: Int { Int(cmark_node_get_heading_level(pointer)) }
        /// A text node's text, a code span's or block's code, an HTML node's source.
        var literal: String { cmark_node_get_literal(pointer).map { String(cString: $0) } ?? "" }
        var fenceInfo: String { cmark_node_get_fence_info(pointer).map { String(cString: $0) } ?? "" }
        /// A link's or image's destination.
        var destination: String { cmark_node_get_url(pointer).map { String(cString: $0) } ?? "" }

        /// The text a reader sees: text and code as written, a line break as a space.
        var plainText: String {
            switch kind {
            case .text, .inlineCode: return literal
            case .softBreak, .lineBreak: return " "
            default: return children.map(\.plainText).joined()
            }
        }
    }

    struct Children: Sequence, IteratorProtocol {
        fileprivate var cursor: UnsafeMutablePointer<cmark_node>?
        mutating func next() -> Node? {
            guard let current = cursor else { return nil }
            cursor = cmark_node_next(current)
            return Node(pointer: current)
        }
    }

    private let document: UnsafeMutablePointer<cmark_node>
    var root: Node { Node(pointer: document) }

    init(parsing source: MarkdownParser.Bytes) {
        cmark_gfm_core_extensions_ensure_registered()
        let parser = cmark_parser_new(CMARK_OPT_TABLE_SPANS | CMARK_OPT_SMART | CMARK_OPT_SOURCEPOS)
        defer { cmark_parser_free(parser) }
        for name in ["table", "strikethrough", "tasklist"] {
            cmark_parser_attach_syntax_extension(parser, cmark_find_syntax_extension(name))
        }
        source.withMemoryRebound(to: CChar.self) { cmark_parser_feed(parser, $0.baseAddress, $0.count) }
        document = cmark_parser_finish(parser)
    }

    deinit { cmark_node_free(document) }
}
