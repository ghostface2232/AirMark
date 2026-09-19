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
    /// Every link reference definition the parse resolved links against, in the order cmark ranks
    /// them: those given as `before`, then the source's own (`ownDefinitions`), then those given as `after`.
    let definitions: [ReferenceDefinition]
    let ownDefinitions: Swift.Range<Int>
    /// False when `after` could not be ranked after the source's own definitions: cmark makes a
    /// paragraph's definitions when the paragraph closes, and one still open when the source ends closes
    /// in `cmark_parser_finish`, by which time `after` is in the map. A source that ends in a blank
    /// line, as a reparse window before other blocks does, has nothing open.
    let definitionsAreOrdered: Bool
    /// Bytes of destinations and titles the parse's reference links expanded to, which cmark caps.
    let referenceExpansion: Int

    /// Parses `source` as part of a document whose other link reference definitions are `before` and
    /// `after` it. cmark collects definitions while it builds blocks and reads them only when it
    /// parses inlines, in `cmark_parser_finish`, taking the earliest of two with one label; so
    /// definitions put into its map around the feed resolve this source's links exactly as the whole
    /// document would. cmark has no API for that. Its headers, which swift-cmark exports and this
    /// package pins, declare the map, and entries are made here as `cmark_reference_create` makes
    /// them, except that the values are already cleaned and are copied as they are.
    init(parsing source: MarkdownParser.Bytes, before: [ReferenceDefinition] = [], after: [ReferenceDefinition] = []) {
        cmark_gfm_core_extensions_ensure_registered()
        let parser = cmark_parser_new(CMARK_OPT_TABLE_SPANS | CMARK_OPT_SMART | CMARK_OPT_SOURCEPOS)!
        defer { cmark_parser_free(parser) }
        for name in ["table", "strikethrough", "tasklist"] {
            cmark_parser_attach_syntax_extension(parser, cmark_find_syntax_extension(name))
        }
        cmark_parser_attach_syntax_extension(parser, Self.referenceReader)
        let map = parser.pointee.refmap!
        for definition in before { definition.insert(into: map) }
        source.withMemoryRebound(to: CChar.self) { cmark_parser_feed(parser, $0.baseAddress, $0.count) }
        let own = before.count..<map.pointee.size
        let open = parser.pointee.linebuf.size > 0 || parser.pointee.current?.pointee.type == UInt16(CMARK_NODE_PARAGRAPH.rawValue)
        definitionsAreOrdered = after.isEmpty || !open
        for definition in after { definition.insert(into: map) }
        document = cmark_parser_finish(parser)
        let storage = Thread.current.threadDictionary
        let read = storage[Self.referenceKey] as? References
        storage.removeObject(forKey: Self.referenceKey)
        definitions = read?.definitions ?? []
        // A paragraph still open at the end made its definitions in `finish`; with no `after` they are the last.
        ownDefinitions = after.isEmpty ? before.count..<definitions.count : own
        referenceExpansion = read?.expansion ?? 0
    }

    /// The map as `cmark_parser_finish` leaves it, which it frees before it returns. An extension's
    /// postprocess hook is the one call cmark makes between resolving the links and freeing the map,
    /// so an extension with nothing but that hook reads it, on the thread that is parsing.
    private final class References {
        let definitions: [ReferenceDefinition], expansion: Int
        init(_ map: UnsafeMutablePointer<cmark_map>) {
            var entries: [(age: Int, definition: ReferenceDefinition)] = []
            var entry = map.pointee.refs
            while let current = entry {
                entries.append((current.pointee.age, ReferenceDefinition(current)))
                entry = current.pointee.next
            }
            definitions = entries.sorted { $0.age < $1.age }.map(\.definition)
            expansion = map.pointee.ref_size
        }
    }
    private static let referenceKey = "AirMark.MarkdownTree.references"
    /// Made once and never freed; cmark only reads it.
    nonisolated(unsafe) private static let referenceReader: UnsafeMutablePointer<cmark_syntax_extension> = {
        let reader = cmark_syntax_extension_new("airmark-references")!
        cmark_syntax_extension_set_postprocess_func(reader) { _, parser, _ in
            if let map = parser?.pointee.refmap { Thread.current.threadDictionary[MarkdownTree.referenceKey] = References(map) }
            return nil
        }
        return reader
    }()

    deinit { cmark_node_free(document) }
}

/// A link reference definition as cmark keeps it: the label normalized, the destination and title
/// cleaned of their delimiters and escapes. Bytes, so nothing is decoded and encoded on the way back in.
public struct ReferenceDefinition: Hashable, Sendable {
    var label: [UInt8], destination: [UInt8], title: [UInt8]
    /// swift-cmark's `^[label]: attributes` form, which shares the map.
    var attributes: [UInt8]?
    /// What one use of this definition counts against cmark's expansion cap.
    var size: Int { attributes == nil ? destination.count + title.count : 0 }

    fileprivate init(_ entry: UnsafeMutablePointer<cmark_map_entry>) {
        let reference = UnsafeMutableRawPointer(entry).assumingMemoryBound(to: cmark_reference.self).pointee
        func bytes(_ chunk: cmark_chunk) -> [UInt8] { chunk.data.map { Array(UnsafeBufferPointer(start: $0, count: Int(chunk.len))) } ?? [] }
        label = Array(UnsafeBufferPointer(start: entry.pointee.label, count: strlen(entry.pointee.label)))
        destination = bytes(reference.url); title = bytes(reference.title)
        attributes = reference.is_attributes_reference ? bytes(reference.attributes) : nil
    }

    /// Appends this definition to `map`, younger than everything in it.
    fileprivate func insert(into map: UnsafeMutablePointer<cmark_map>) {
        let memory = map.pointee.mem.pointee
        func copy(_ bytes: [UInt8]) -> UnsafeMutablePointer<UInt8> {
            let data = memory.calloc(bytes.count + 1, 1)!.assumingMemoryBound(to: UInt8.self)
            data.update(from: bytes, count: bytes.count)
            return data
        }
        func chunk(_ bytes: [UInt8]) -> cmark_chunk { cmark_chunk(data: copy(bytes), len: bufsize_t(bytes.count), alloc: 1) }
        let reference = memory.calloc(1, MemoryLayout<cmark_reference>.size)!.assumingMemoryBound(to: cmark_reference.self)
        reference.pointee.is_attributes_reference = attributes != nil
        reference.pointee.url = chunk(destination); reference.pointee.title = chunk(title)
        reference.pointee.attributes = chunk(attributes ?? [])
        reference.pointee.entry = cmark_map_entry(next: map.pointee.refs, label: copy(label), age: map.pointee.size, size: size)
        map.pointee.refs = UnsafeMutableRawPointer(reference).assumingMemoryBound(to: cmark_map_entry.self)
        map.pointee.size += 1
    }
}
