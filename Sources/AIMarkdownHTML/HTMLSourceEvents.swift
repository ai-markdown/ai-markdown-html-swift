import Foundation

/// Optional source events for AIMarkdownHTML; ranges refer to the original HTML UTF-8 buffer before normalization.
/// bytes contains actual output values; non-copy pieces do not establish an exact, reversible character mapping.
public struct SourceEventPiece: Codable, Sendable {
    public var bytes: [UInt8]
    public var range: [Int]?
    public var kind: String
    public var emissions: [String]
    public init(bytes: [UInt8], range: [Int]?, kind: String, emissions: [String] = []) {
        self.bytes = bytes; self.range = range; self.kind = kind; self.emissions = emissions
    }
}
public struct SourceInputEmission: Codable, Sendable {
    public let id: String
    public let kind: String
    public let role: String
    public let value: String
    public let rawUTF8Start: Int
    public let rawUTF8End: Int
    public init(id: String, kind: String, role: String, value: String, rawUTF8Start: Int, rawUTF8End: Int) {
        self.id = id; self.kind = kind; self.role = role; self.value = value
        self.rawUTF8Start = rawUTF8Start; self.rawUTF8End = rawUTF8End
    }
}
public struct SourceEventRecord: Codable, Sendable {
    public let sequence: Int
    public let kind: String
    public let node: Int?
    public let token: Int?
    public let triggerToken: Int?
    public let parent: Int?
    public let related: [Int]
    public let note: String?
}
public struct SourceTokenRecord: Codable, Sendable {
    public let id: Int
    public let kind: String
    public let name: String?
    public let range: [Int]?
    public let pieces: [SourceEventPiece]
    public let emissions: [String]
}
public struct SourceNodeRecord: Codable, Sendable {
    public let id: Int
    public let name: String
    public var kind: String
    public var startTokens: [Int] = []
    public var endTokens: [Int] = []
    public var derivedFrom: [Int] = []
    public var pieces: [SourceEventPiece] = []
    public var gaps: [String] = []
    public var legacyRange: [Int]?
    public var parent: Int?
    public var finalPath: [Int]?
}
public struct SourceDOMNode: Codable, Sendable {
    public let type: String
    public let name: String?
    public let value: String?
    public let attributes: [String: String]?
    public let children: [SourceDOMNode]?
}
public struct HTMLSourceSnapshot: Codable, Sendable {
    public let scope: UUID
    public let semantic: SourceDOMNode
    public let tokens: [SourceTokenRecord]
    public let nodes: [SourceNodeRecord]
    public let events: [SourceEventRecord]
    public let gaps: [String]
    /// Physical line-ending transformations before the reader, including attributes and comments that do not produce character pieces.
    /// Record original input coverage and output LF only, not an exact inverse mapping of final nodes.
    public let inputNormalizations: [SourceEventPiece]
    private enum CodingKeys: String, CodingKey { case scope, semantic, tokens, nodes, events, gaps, inputNormalizations }
    init(scope: UUID, semantic: SourceDOMNode, tokens: [SourceTokenRecord], nodes: [SourceNodeRecord], events: [SourceEventRecord], gaps: [String], inputNormalizations: [SourceEventPiece] = []) {
        self.scope = scope; self.semantic = semantic; self.tokens = tokens; self.nodes = nodes
        self.events = events; self.gaps = gaps; self.inputNormalizations = inputNormalizations
    }
    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        scope = try values.decode(UUID.self, forKey: .scope); semantic = try values.decode(SourceDOMNode.self, forKey: .semantic)
        tokens = try values.decode([SourceTokenRecord].self, forKey: .tokens); nodes = try values.decode([SourceNodeRecord].self, forKey: .nodes)
        events = try values.decode([SourceEventRecord].self, forKey: .events); gaps = try values.decode([String].self, forKey: .gaps)
        inputNormalizations = try values.decodeIfPresent([SourceEventPiece].self, forKey: .inputNormalizations) ?? []
    }
}

public struct HTMLSourceIdentity: Codable, Hashable, Sendable {
    public let scope: UUID
    public let ordinal: Int
}

public struct HTMLSourceParseResult {
    public let roots: [Node]
    public let trace: HTMLSourceSnapshot?
}

/// One collector per parser; retain value events without owning Nodes or promising concurrent mutation support.
public final class SourceEventRecorder {
    public private(set) var tokens: [SourceTokenRecord] = []
    public private(set) var events: [SourceEventRecord] = []
    public var gaps: [String] = []
    public var activeToken: Int?
    public let bytes: [UInt8]
    public let emissions: [SourceInputEmission]
    public let scope = UUID()
    private var records: [SourceNodeRecord] = []
    private let rawEmissions: RawEmissionIndex
    public init(bytes: [UInt8], emissions: [SourceInputEmission]) {
        self.bytes = bytes; self.emissions = emissions; rawEmissions = RawEmissionIndex(emissions)
    }
    public func checked(_ range: [Int]?) -> [Int]? {
        guard let range, range.count == 2, range[0] >= 0, range[0] <= range[1], range[1] <= bytes.count else { return nil }
        func boundary(_ offset: Int) -> Bool { offset == bytes.count || bytes[offset] & 0xc0 != 0x80 }
        guard boundary(range[0]), boundary(range[1]) else { return nil }
        return range
    }
    public func emissionIDs(_ range: [Int]?) -> [String] {
        guard let range = checked(range) else { return [] }
        return rawEmissions.ids(overlapping: range)
    }
    public func event(_ kind: String, node: Int? = nil, token: Int? = nil, parent: Int? = nil, related: [Int] = [], note: String? = nil) {
        events.append(SourceEventRecord(sequence: events.count + 1, kind: kind, node: node, token: token, triggerToken: activeToken, parent: parent, related: related, note: note))
    }
    public func id(_ node: Node) -> Int {
        if let identity = node.sourceEventIdentity, identity.scope == scope { return identity.ordinal }
        node.sourceEventRecorder?.endedIdentity(node, reason: "scope-reassociation")
        let id = records.count + 1
        node.sourceEventIdentity = HTMLSourceIdentity(scope: scope, ordinal: id)
        node.sourceEventRecorder = self
        records.append(SourceNodeRecord(id: id, name: String(decoding: node.nodeNameUTF8(), as: UTF8.self), kind: "observed-without-create-event", gaps: ["unobserved-create-site"]))
        return id
    }
    public func endedIdentity(_ node: Node, reason: String) {
        guard let identity = node.sourceEventIdentity, identity.scope == scope else { return }
        records[identity.ordinal - 1].gaps.append("identity-ended:" + reason)
        records[identity.ordinal - 1].finalPath = nil
        event("identity-end", node: identity.ordinal, note: reason)
    }
    private func refresh(_ node: Node) {
        let identity = id(node)
        let parentID = node.parent().map(id)
        records[identity - 1].parent = parentID
        records[identity - 1].legacyRange = node.sourceRange.map { [$0.start, $0.end] }
    }
    public func token(_ token: Token, generated: Bool = false) {
        let identity = tokens.count + 1
        token.sourceEventID = identity
        let range = checked(token.sourceRange.map { [$0.start, $0.end] })
        let name: String?
        if let tag = token as? Token.Tag { name = tag.normalName().map { String(decoding: $0, as: UTF8.self) } }
        else { name = nil }
        var pieces = token.sourceEventPieces
        if let char = token as? Token.Char {
            let value = char.getDataSlice().map(Array.init) ?? char.getData() ?? []
            if !pieces.flatMap(\.bytes).elementsEqual(value) {
                pieces = [SourceEventPiece(bytes: value, range: nil, kind: "uncovered-character-emission")]
                gaps.append("uncovered-character-emission")
            }
        }
        pieces = pieces.map { piece in
            var copy = piece
            if piece.range != nil, checked(piece.range) == nil { copy.range = nil; copy.kind = "invalid-source-boundary"; gaps.append(copy.kind) }
            copy.emissions = copy.emissions + emissionIDs(copy.range)
            if copy.range == nil && copy.kind != "hast-generated-text" { gaps.append(copy.kind) }
            return copy
        }
        token.sourceEventPieces = pieces
        let kind = generated ? "generated-characters" : String(describing: token.type)
        tokens.append(SourceTokenRecord(id: identity, kind: kind, name: name, range: range, pieces: pieces, emissions: emissionIDs(range)))
        activeToken = identity
        event("token", token: identity, note: kind)
    }
    public func created(_ node: Node, token: Token?, generated: String? = nil) {
        let identity = id(node)
        records[identity - 1].kind = generated ?? "token-created"
        records[identity - 1].gaps.removeAll { $0 == "unobserved-create-site" }
        if let token, let tokenID = token.sourceEventID {
            records[identity - 1].startTokens.append(tokenID)
            if token.sourceRange == nil { records[identity - 1].gaps.append("missing-start-token-range") }
        } else if generated == nil { records[identity - 1].gaps.append("missing-create-token") }
        event("create", node: identity, token: token?.sourceEventID, note: generated)
    }
    public func character(_ node: Node, token: Token, merge: Bool) {
        let identity = id(node)
        if records[identity - 1].kind == "observed-without-create-event" { records[identity - 1].kind = "character-created"; records[identity - 1].gaps.removeAll { $0 == "unobserved-create-site" } }
        var pieces = token.sourceEventPieces
        if pieces.isEmpty {
            let char = token as? Token.Char
            let value = char?.getDataSlice().map(Array.init) ?? char?.getData() ?? []
            pieces = [SourceEventPiece(bytes: value, range: nil, kind: "parser-character-without-pieces")]
            records[identity - 1].gaps.append("parser-character-without-pieces")
        }
        refresh(node)
        records[identity - 1].pieces += pieces
        event(merge ? "text-merge" : "text-create", node: identity, token: token.sourceEventID)
    }
    public func moved(_ node: Node, from: Node?, to: Node?) {
        let identity = id(node)
        refresh(node)
        event(from == nil ? "attach" : to == nil ? "detach" : "move", node: identity, token: activeToken, parent: to.map(id), related: from.map { [id($0)] } ?? [])
    }
    public func placed(_ node: Node, foster: Bool) {
        refresh(node)
        event(foster ? "foster-insert" : "insert", node: id(node), token: activeToken, parent: node.parent().map(id))
    }
    public func invalidatedFosterContainerRange(_ node: Node) {
        let identity = id(node)
        let reason = "fostered-content-is-not-container-subtree"
        records[identity - 1].legacyRange = nil
        if !records[identity - 1].gaps.contains(reason) { records[identity - 1].gaps.append(reason) }
        event("legacy-range-clear", node: identity, note: reason)
    }
    public func fosteredCharacter(_ node: Node, token: Token, before: Node?, merged: Bool) {
        refresh(node)
        event("foster-text", node: id(node), token: token.sourceEventID, parent: node.parent().map(id), related: before.map { [id($0)] } ?? [], note: merged ? "merge-at-destination" : "insert-at-destination")
    }
    public func fosterTextBypass(_ node: Node) {
        let identity = id(node)
        records[identity - 1].gaps.append("foster-text-bypasses-insertNode")
        gaps.append("foster-text-bypasses-insertNode")
        event("foster-text-bypass", node: identity, token: activeToken, parent: node.parent().map(id))
    }
    public func cloned(_ source: Node, _ target: Node, reason: String) {
        let sourceID = id(source), targetID = id(target)
        refresh(target)
        records[targetID - 1].kind = "clone"
        records[targetID - 1].gaps.removeAll { $0 == "unobserved-create-site" }
        records[targetID - 1].startTokens = []
        records[targetID - 1].derivedFrom.append(sourceID)
        records[targetID - 1].gaps.append("clone-has-no-author-start-token")
        event("clone", node: targetID, token: activeToken, related: [sourceID], note: reason)
    }
    public func closed(_ node: Node, token: Token?) {
        let identity = id(node)
        let matching = (token as? Token.EndTag)?.normalName().map { name in
            if let element = node as? Element, element.htmlNamespace != .html { return ForeignContent.matchesEndTag(element, name: name) }
            return name == node.nodeNameUTF8()
        } == true
        if matching, let tokenID = token?.sourceEventID, token?.sourceRange != nil {
            if !records[identity - 1].endTokens.contains(tokenID) { records[identity - 1].endTokens.append(tokenID) }
            event("explicit-close", node: identity, token: tokenID)
        } else { event("implicit-close", node: identity, token: activeToken) }
    }
    public func stackChanged(before: [Element], after: [Element]) {
        let remaining = Set(after.map(ObjectIdentifier.init))
        for element in before where !remaining.contains(ObjectIdentifier(element)) {
            event("stack-exit", node: id(element), token: activeToken)
        }
    }
    public func legacyEnd(_ node: Node, _ end: Int) {
        let identity = id(node)
        if let start = node.sourceRange?.start { records[identity - 1].legacyRange = [start, end] }
        event("legacy-range-end", node: id(node), token: activeToken, note: String(end))
    }
    public func mergedLegacyRangeCleared(_ node: Node, token: Token) {
        let identity = id(node)
        let reason = "merged-character-node-has-no-single-raw-range"
        records[identity - 1].legacyRange = nil
        if !records[identity - 1].gaps.contains(reason) { records[identity - 1].gaps.append(reason) }
        if !gaps.contains(reason) { gaps.append(reason) }
        event("legacy-range-clear", node: identity, token: token.sourceEventID, note: reason)
    }
    public func result(_ roots: [Node]) -> HTMLSourceSnapshot {
        for index in records.indices { records[index].finalPath = nil }
        // Build snapshots with an explicit postorder work stack; ordinary background threads must not recurse with HTML depth either.
        struct Work {
            let node: Node
            let path: [Int]
            let closing: Bool
        }
        var work = roots.enumerated().reversed().map { Work(node: $0.element, path: [$0.offset], closing: false) }
        var projected: [SourceDOMNode] = []
        while let frame = work.popLast() {
            let node = frame.node
            let children = node.getChildNodes()
            if !frame.closing {
                let identity = id(node)
                refresh(node)
                records[identity - 1].finalPath = frame.path
                work.append(Work(node: node, path: frame.path, closing: true))
                for (index, child) in children.enumerated().reversed() {
                    work.append(Work(node: child, path: frame.path + [index], closing: false))
                }
                continue
            }
            let childValues = Array(projected.suffix(children.count))
            projected.removeLast(children.count)
            let value: SourceDOMNode
            if let text = node as? TextNode {
                value = SourceDOMNode(type: "text", name: nil, value: text.getWholeText(), attributes: nil, children: nil)
            } else if let data = node as? DataNode {
                value = SourceDOMNode(type: "text", name: nil, value: data.getWholeData(), attributes: nil, children: nil)
            } else if let comment = node as? Comment {
                value = SourceDOMNode(type: "comment", name: nil, value: comment.getData(), attributes: nil, children: nil)
            } else {
                let element = node as? Element
                var attributes: [String: String] = [:]
                for attribute in element?.getAttributes()?.asList() ?? [] { attributes[attribute.getKey()] = attribute.getValue() }
                value = SourceDOMNode(type: "element", name: element?.tagName() ?? node.nodeName(), value: nil, attributes: attributes, children: childValues)
            }
            projected.append(value)
        }
        return HTMLSourceSnapshot(scope: scope, semantic: SourceDOMNode(type: "root", name: nil, value: nil, attributes: nil, children: projected), tokens: tokens, nodes: records, events: events, gaps: Array(Set(gaps)).sorted())
    }
}

/// Answers "which non-empty raw emissions overlap a UTF-8 range" in emission order. Validated parser input lays raw
/// emissions out contiguously, so their starts and ends both increase strictly and the matches form one contiguous run
/// found by binary search. Any other layout (only reachable through the public recorder initializer) keeps the linear scan.
private struct RawEmissionIndex {
    private let emissions: [SourceInputEmission]
    private let ordered: Bool

    init(_ input: [SourceInputEmission]) {
        emissions = input.filter { $0.kind == "raw" && $0.rawUTF8Start < $0.rawUTF8End }
        ordered = zip(emissions, emissions.dropFirst()).allSatisfy { $0.rawUTF8End <= $1.rawUTF8Start }
    }

    func ids(overlapping range: [Int]) -> [String] {
        guard ordered else {
            return emissions.filter { $0.rawUTF8Start < range[1] && $0.rawUTF8End > range[0] }.map(\.id)
        }
        var lower = 0, upper = emissions.count
        while lower < upper {
            let middle = lower + (upper - lower) / 2
            if emissions[middle].rawUTF8End > range[0] { upper = middle } else { lower = middle + 1 }
        }
        var result: [String] = []
        while lower < emissions.count, emissions[lower].rawUTF8Start < range[1] {
            result.append(emissions[lower].id)
            lower += 1
        }
        return result
    }
}

/// The reader buffer may be normalized; all exposed ranges still refer to the original serialized UTF-8 buffer.
/// hast-util-raw resets its preprocessor for each author raw node; CRLF must not collapse across emissions.
private struct HTMLRawInputNormalization {
    private struct Ending { let normalized: Int; let originalStart: Int; let originalEnd: Int }
    let original: [UInt8]
    let bytes: [UInt8]
    let emissions: [SourceInputEmission]
    private let originalEmissions: [SourceInputEmission]
    private let originalRawEmissions: RawEmissionIndex
    private let boundaries: [Int]
    private let endings: [Ending]

    init(_ input: [SourceInputEmission], raw: [UInt8]) {
        original = raw
        originalEmissions = input
        originalRawEmissions = RawEmissionIndex(input)
        // Both generated roles originate in HAST; encodedHTML changes only the encoding, not generated content into author raw markup.
        func preprocesses(_ emission: SourceInputEmission) -> Bool {
            emission.kind == "raw" && emission.role == "author-raw"
        }
        guard input.contains(where: { preprocesses($0) && $0.value.utf8.contains(13) }) else {
            bytes = raw; emissions = input; boundaries = []; endings = []; return
        }
        var output: [UInt8] = [], mapped = [0], changes: [Ending] = [], segments: [SourceInputEmission] = []
        output.reserveCapacity(raw.count); mapped.reserveCapacity(raw.count + 1)
        for emission in input {
            let start = output.count
            var value: [UInt8] = []
            if emission.kind == "raw" {
                let source = Array(emission.value.utf8)
                var cursor = 0
                while cursor < source.count {
                    let originalStart = emission.rawUTF8Start + cursor
                    let byte = source[cursor]
                    if preprocesses(emission), byte == 13 {
                        let size = cursor + 1 < source.count && source[cursor + 1] == 10 ? 2 : 1
                        changes.append(Ending(normalized: output.count, originalStart: originalStart, originalEnd: originalStart + size))
                        output.append(10); value.append(10); cursor += size
                    } else {
                        output.append(byte); value.append(byte); cursor += 1
                    }
                    mapped.append(emission.rawUTF8Start + cursor)
                }
            }
            segments.append(SourceInputEmission(id: emission.id, kind: emission.kind, role: emission.role,
                                                value: emission.kind == "raw" ? String(decoding: value, as: UTF8.self) : emission.value,
                                                rawUTF8Start: start, rawUTF8End: output.count))
        }
        bytes = output; emissions = segments; boundaries = mapped; endings = changes
    }
    private func boundary(_ value: Int) -> Int? {
        guard value >= 0, value <= bytes.count else { return nil }
        return boundaries.isEmpty ? value : boundaries[value]
    }
    private func range(_ value: [Int]?) -> [Int]? {
        guard let value, value.count == 2, value[0] <= value[1],
              let start = boundary(value[0]), let end = boundary(value[1]),
              (start == original.count || original[start] & 0xc0 != 0x80),
              (end == original.count || original[end] & 0xc0 != 0x80) else { return nil }
        return [start, end]
    }
    private func emissionIDs(_ range: [Int]?) -> [String] {
        guard let range else { return [] }
        return originalRawEmissions.ids(overlapping: range)
    }
    private func firstEnding(_ offset: Int) -> Int {
        var lower = 0, upper = endings.count
        while lower < upper {
            let middle = lower + (upper - lower) / 2
            if endings[middle].normalized < offset { lower = middle + 1 } else { upper = middle }
        }
        return lower
    }
    private func pieces(_ input: [SourceEventPiece]) -> [SourceEventPiece] {
        input.flatMap { piece -> [SourceEventPiece] in
            guard let sourceRange = piece.range else { return [piece] }
            guard let mapped = range(sourceRange) else {
                return [SourceEventPiece(bytes: piece.bytes, range: nil, kind: "invalid-normalized-source-boundary", emissions: piece.emissions)]
            }
            // Only actual reader-copy paths may split at boundaries; entities retain separate decoded-reference evidence.
            guard piece.kind == "copy" else {
                return [SourceEventPiece(bytes: piece.bytes, range: mapped, kind: piece.kind, emissions: emissionIDs(mapped))]
            }
            guard piece.bytes.elementsEqual(bytes[sourceRange[0] ..< sourceRange[1]]) else {
                return [SourceEventPiece(bytes: piece.bytes, range: nil, kind: "copy-piece-does-not-match-reader", emissions: piece.emissions)]
            }
            var result: [SourceEventPiece] = [], cursor = sourceRange[0], index = firstEnding(sourceRange[0])
            func copy(_ start: Int, _ end: Int) {
                guard start < end else { return }
                let mapped = range([start, end])
                result.append(SourceEventPiece(bytes: Array(bytes[start ..< end]), range: mapped, kind: "copy", emissions: emissionIDs(mapped)))
            }
            while index < endings.count, endings[index].normalized < sourceRange[1] {
                let ending = endings[index]
                copy(cursor, ending.normalized)
                let mapped = [ending.originalStart, ending.originalEnd]
                result.append(SourceEventPiece(bytes: [10], range: mapped, kind: "normalized-line-ending", emissions: emissionIDs(mapped)))
                cursor = ending.normalized + 1; index += 1
            }
            copy(cursor, sourceRange[1])
            return result
        }
    }
    func snapshot(_ source: HTMLSourceSnapshot) -> HTMLSourceSnapshot {
        guard !endings.isEmpty else { return source }
        var gaps = source.gaps
        let tokens = source.tokens.map { token in
            let mapped = range(token.range)
            if token.range != nil && mapped == nil { gaps.append("invalid-normalized-source-boundary") }
            let mappedPieces = pieces(token.pieces)
            gaps.append(contentsOf: mappedPieces.filter { $0.range == nil && $0.kind != "hast-generated-text" }.map(\.kind))
            return SourceTokenRecord(id: token.id, kind: token.kind, name: token.name, range: mapped, pieces: mappedPieces, emissions: emissionIDs(mapped))
        }
        let nodes = source.nodes.map { original -> SourceNodeRecord in
            var node = original
            node.pieces = pieces(node.pieces)
            for reason in node.pieces.filter({ $0.range == nil && $0.kind != "hast-generated-text" }).map(\.kind) where !node.gaps.contains(reason) { node.gaps.append(reason); gaps.append(reason) }
            node.legacyRange = range(node.legacyRange)
            if original.legacyRange != nil && node.legacyRange == nil { node.gaps.append("invalid-normalized-source-boundary"); gaps.append("invalid-normalized-source-boundary") }
            return node
        }
        let events = source.events.map { event in
            let note = event.kind == "legacy-range-end" ? event.note.flatMap(Int.init).flatMap(boundary).map(String.init) : event.note
            return SourceEventRecord(sequence: event.sequence, kind: event.kind, node: event.node, token: event.token, triggerToken: event.triggerToken, parent: event.parent, related: event.related, note: note)
        }
        return HTMLSourceSnapshot(scope: source.scope, semantic: source.semantic, tokens: tokens, nodes: nodes, events: events, gaps: Array(Set(gaps)).sorted(), inputNormalizations: endings.map { ending in
            let range = [ending.originalStart, ending.originalEnd]
            return SourceEventPiece(bytes: [10], range: range, kind: "normalized-line-ending", emissions: emissionIDs(range))
        })
    }
    func restoreOriginalRanges(_ roots: [Node]) {
        guard !endings.isEmpty else { return }
        let source = SourceBuffer(original, parsedAsXml: false)
        var stack = Array(roots.reversed())
        while let node = stack.popLast() {
            if let old = node.sourceRange {
                let mapped = range([old.start, old.end])
                node.sourceRange = mapped.map { SourceRange(start: $0[0], end: $0[1]) }
                if mapped == nil { node.sourceRangeIsComplete = false; node.sourceRangeDirty = true }
            }
            node.sourceBuffer = source
            stack.append(contentsOf: node.getChildNodes().reversed())
        }
    }
}

/// Fragment insertion context for `HTMLSourceParser`: `<body>` retains the body-context table rules; `<template>`
/// reproduces parse5 7.3 `Parser.getFragmentParser(undefined)` as used by hast-util-raw. Source-token injection and
/// HTML5 self-closing recovery apply in both contexts (the ordinary `parseBodyFragment` API keeps legacy recovery).
public enum HTMLFragmentContext: String, Sendable {
    case body
    case template
}

/// Parse a complete fragment in one call; caller-supplied emission records remain separate from author HTML attributes.
public enum HTMLSourceParser {
    public static func parseFragment(_ emissions: [SourceInputEmission], tracking: Bool = false, context: HTMLFragmentContext = .body) throws -> HTMLSourceParseResult {
        try parse(emissions, tracking: tracking, context: context)
    }

    // document/fast/copy are module-test helpers and do not expand the production fragment entry point.
    static func parse(_ emissions: [SourceInputEmission], tracking: Bool = false, context: HTMLFragmentContext = .body, document: Bool = false, trackRanges: Bool = true, copyControl: Bool = false) throws -> HTMLSourceParseResult {
        var offset = 0
        var ids = Set<String>()
        for emission in emissions {
            let validRole = emission.kind == "raw" ? ["author-raw", "hast-generated-tag", "serialized-generated-text"].contains(emission.role) : emission.role == "hast-generated-text"
            guard validRole, ids.insert(emission.id).inserted, ["raw", "characters"].contains(emission.kind), emission.rawUTF8Start == offset else {
                throw Exception.Error(type: .IllegalArgumentException, Message: "Invalid input emission records")
            }
            if emission.kind == "raw" { offset += emission.value.utf8.count }
            guard emission.rawUTF8End == offset else { throw Exception.Error(type: .IllegalArgumentException, Message: "Invalid input emission length") }
        }
        let raw = emissions.filter { $0.kind == "raw" }.map(\.value).joined()
        let normalized = HTMLRawInputNormalization(emissions, raw: Array(raw.utf8))
        let recorder = tracking ? SourceEventRecorder(bytes: normalized.bytes, emissions: normalized.emissions) : nil
        let builder = HtmlTreeBuilder()
        builder.sourceEvents = recorder
        defer { builder.sourceEvents = nil }
        // Every emission is one hast node for the tree builder's hast-util-raw loop (see `TreeBuilder.runParser`).
        // Serializer directories keep their own granularity (one tag may span several generated-markup emissions, such
        // as `<a href="` + url + `">`), so consecutive generated-markup emissions form one markup chunk.
        var segments: [TreeBuilder.EmissionSegment] = []
        for emission in normalized.emissions {
            switch (emission.kind, emission.role) {
            case ("characters", _): segments.append(.init(kind: .characters(value: Array(emission.value.utf8), id: emission.id), end: emission.rawUTF8End))
            case (_, "hast-generated-tag"):
                if let last = segments.last, case .generatedMarkup = last.kind { segments[segments.count - 1] = .init(kind: .generatedMarkup, end: emission.rawUTF8End) }
                else { segments.append(.init(kind: .generatedMarkup, end: emission.rawUTF8End)) }
            case (_, "serialized-generated-text"): segments.append(.init(kind: .encodedText, end: emission.rawUTF8End))
            default: segments.append(.init(kind: .authorRaw, end: emission.rawUTF8End))
            }
        }
        builder.sourceParserHTML5Mode = true
        builder.emissionSegments = segments
        builder.coalescesSourceCharacters = normalized.emissions.contains { $0.kind == "characters" }
        let settings = ParseSettings(false, false, trackRanges)
        let roots: [Node]
        if document {
            let document = try builder.parse(normalized.bytes, [], ParseErrorList.noTracking(), settings)
            roots = document.getChildNodes()
        } else {
            let contextElement = try Element(Tag.valueOf(context == .template ? "template" : "body"), "")
            roots = try builder.parseFragment(normalized.bytes, contextElement, [], ParseErrorList.noTracking(), settings)
        }
        recorder?.activeToken = nil
        // Return independent fragment roots by explicitly detaching the temporary container, keeping events consistent with returned parent relationships.
        try Node.detachInOrder(roots)
        if copyControl, let first = roots.first { _ = first.copy() }
        let trace = recorder.map { normalized.snapshot($0.result(roots)) }
        normalized.restoreOriginalRanges(roots)
        return HTMLSourceParseResult(roots: roots, trace: trace)
    }
}
