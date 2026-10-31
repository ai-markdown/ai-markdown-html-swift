//
//  TreeBuilder.swift
//  SwiftSoup
//
//  Created by Nabil Chatbi on 24/10/16.
//

import Foundation

public class TreeBuilder {
    public var reader: CharacterReader
    var tokeniser: Tokeniser
    public var doc: Document // current doc we are building into
    public var stack: Array<Element> // the stack of open elements
    public var baseUri: [UInt8] // current base uri, for creating new elements
    public var currentToken: Token? // currentToken is used only for error tracking.
    public var errors: ParseErrorList // null when not tracking errors
    public var settings: ParseSettings
    @usableFromInline var sourceEvents: SourceEventRecorder?
    /// hast-util-raw node sequence for `HTMLSourceParser`; empty for plain string parsing.
    var emissionSegments: [EmissionSegment] = []
    @usableFromInline var coalescesSourceCharacters = false
    public var tracksSourceRanges: Bool = false
    public var tracksErrors: Bool = false
    @usableFromInline
    var pendingAttributeElements: [Element] = []
    
    private let start: Token.StartTag = Token.StartTag() // start tag to process
    private let end: Token.EndTag  = Token.EndTag()
    
    /// Bulk-build suppression flag
    @usableFromInline
    var isBulkBuilding: Bool = false
    
    
    public func defaultSettings() -> ParseSettings {preconditionFailure("This method must be overridden")}
    
    public init() {
        doc =  Document([])
        reader = CharacterReader([])
        stack = Array<Element>()
        baseUri = []
        errors = ParseErrorList(0, 0)
        settings = ParseSettings(false, false)
        tokeniser = Tokeniser(reader, nil, settings)
    }
    
    @inline(__always)
    func beginBulkAppend() {
        isBulkBuilding = true
    }
    
    @inline(__always)
    func endBulkAppend() {
        isBulkBuilding = false
    }
    
    public func initialiseParse(_ input: [UInt8], _ baseUri: [UInt8], _ errors: ParseErrorList, _ settings: ParseSettings) {
        doc = Document(baseUri)
        tracksSourceRanges = settings.tracksSourceRanges()
        if tracksSourceRanges {
            doc.sourceBuffer = SourceBuffer(input, parsedAsXml: self is XmlTreeBuilder)
        } else {
            doc.sourceBuffer = nil
        }
        doc.parsedAsXml = false
        self.settings = settings
        let parseBuffer: [UInt8]
        if tracksSourceRanges, let sourceBuffer = doc.sourceBuffer {
            parseBuffer = sourceBuffer.bytes
        } else {
            parseBuffer = input
        }
        reader = CharacterReader(parseBuffer)
        self.errors = errors
        tracksErrors = errors.getMaxSize() > 0
        tokeniser = Tokeniser(reader, tracksErrors ? errors : nil, settings,
                              isXmlParser: self is XmlTreeBuilder,
                              normalizesHtmlNumericReferences: !(self is XmlTreeBuilder))
        sourceEvents?.created(doc, token: nil, generated: "parser-document")
        tokeniser.sourceEvents = sourceEvents
        tokeniser.sourceEventCapturesCharacters = sourceEvents != nil
        stack = Array<Element>()
        self.baseUri = baseUri
        pendingAttributeElements.removeAll(keepingCapacity: true)
    }

    public func initialiseParse(_ input: UnsafeBufferPointer<UInt8>, owner: AnyObject?, _ baseUri: [UInt8], _ errors: ParseErrorList, _ settings: ParseSettings) {
        doc = Document(baseUri)
        tracksSourceRanges = settings.tracksSourceRanges()
        if tracksSourceRanges {
            let copied = Array(input)
            doc.sourceBuffer = SourceBuffer(copied, parsedAsXml: self is XmlTreeBuilder)
            reader = CharacterReader(copied)
        } else {
            doc.sourceBuffer = nil
            reader = CharacterReader(input, owner: owner)
        }
        doc.parsedAsXml = false
        self.settings = settings
        self.errors = errors
        tracksErrors = errors.getMaxSize() > 0
        tokeniser = Tokeniser(reader, tracksErrors ? errors : nil, settings,
                              isXmlParser: self is XmlTreeBuilder,
                              normalizesHtmlNumericReferences: !(self is XmlTreeBuilder))
        sourceEvents?.created(doc, token: nil, generated: "parser-document")
        tokeniser.sourceEvents = sourceEvents
        tokeniser.sourceEventCapturesCharacters = sourceEvents != nil
        stack = Array<Element>()
        self.baseUri = baseUri
        pendingAttributeElements.removeAll(keepingCapacity: true)
    }
    
    func parse(_ input: [UInt8], _ baseUri: [UInt8],
               _ errors: ParseErrorList,
               _ settings: ParseSettings) throws -> Document {
        // Associate builder for node-level checks
        doc.treeBuilder = self
        
        // Suppress per-append index invalidation; rebuild once at end
        beginBulkAppend()
        defer { endBulkAppend() }
        
        initialiseParse(input, baseUri, errors, settings)
        try runParser()
        if !tracksSourceRanges, !pendingAttributeElements.isEmpty {
            for element in pendingAttributeElements {
                element.attributes?.ensureMaterialized()
            }
            pendingAttributeElements.removeAll(keepingCapacity: true)
        }
        return doc
    }

    func parse(_ input: UnsafeBufferPointer<UInt8>, owner: AnyObject?, _ baseUri: [UInt8],
               _ errors: ParseErrorList,
               _ settings: ParseSettings) throws -> Document {
        doc.treeBuilder = self
        beginBulkAppend()
        defer { endBulkAppend() }

        initialiseParse(input, owner: owner, baseUri, errors, settings)
        try runParser()
        if !tracksSourceRanges, !pendingAttributeElements.isEmpty {
            for element in pendingAttributeElements {
                element.attributes?.ensureMaterialized()
            }
            pendingAttributeElements.removeAll(keepingCapacity: true)
        }
        return doc
    }
    
    @inline(__always)
    func registerPendingAttributes(_ element: Element) {
        guard !tracksSourceRanges else { return }
        if let attributes = element.attributes,
           attributes.pendingAttributesCount > 0 {
            pendingAttributeElements.append(element)
        }
    }
    
    /// One hast node as hast-util-raw sees it. Raw segments cover `[start, end)` of the reader buffer; generated text
    /// has no bytes in the buffer and is injected as a character token.
    struct EmissionSegment {
        enum Kind {
            /// Author `raw` node: tokenized in the current state; the end is a hard boundary (`resetTokenizer`).
            case authorRaw
            /// Serializer-generated markup (start/end tags): tokenized on its own in the data state and processed as
            /// synthetic tokens (`startTag`/`endTag` in hast-util-raw) without disturbing the current tokenizer state.
            case generatedMarkup
            /// Generated text already encoded as raw HTML (`encodedHTML` input mode): continues the current state.
            case encodedText
            /// Generated text injected as one CHARACTER token (`text` in hast-util-raw).
            case characters(value: [UInt8], id: String)
        }
        let kind: Kind
        let end: Int
    }

    public func runParser() throws {
        if emissionSegments.isEmpty {
            while true {
                let token: Token = try tokeniser.read()
                try receive(token, synthetic: false)
                if token.type == .EOF { break }
            }
            return
        }
        // hast-util-raw `handleRaw` only resets the preprocessor: consecutive raw nodes continue one tokenizer run,
        // including an unfinished tag or comment and the pending character token. `resetTokenizer` runs before every
        // generated node and once after the last node (flush pending characters, drop an unfinished token); the parser
        // never receives EOF, so pending table characters at the end are not inserted.
        for (index, segment) in emissionSegments.enumerated() {
            switch segment.kind {
            case .authorRaw, .encodedText:
                let nextIsRaw: Bool
                if index + 1 < emissionSegments.count, case .authorRaw = emissionSegments[index + 1].kind { nextIsRaw = true }
                else if index + 1 < emissionSegments.count, case .encodedText = emissionSegments[index + 1].kind { nextIsRaw = true }
                else { nextIsRaw = false }
                tokeniser.beginEmission(end: segment.end, flushing: !nextIsRaw)
                let previousTokenCount = sourceEvents?.tokens.count ?? 0
                try drainEmission()
                if !nextIsRaw, let checkpoint = tokeniser.sourceHibernationEnd, checkpoint < segment.end {
                    let pending = sourceEvents?.tokens.last.flatMap { $0.id > previousTokenCount && $0.kind == "Char" ? $0.id : nil }
                    sourceEvents?.event("raw-hibernation-end", token: pending, note: "\(segment.end):\(checkpoint)")
                }
                if nextIsRaw { tokeniser.continueAfterEmission() } else { tokeniser.resetAtEmissionBoundary() }
            case .generatedMarkup:
                try processGeneratedMarkup(end: segment.end)
            case let .characters(value, id):
                tokeniser.prepareForGeneratedText()
                let generated = Token.Char().data(value)
                generated.sourceCharacterInjection = true
                generated.sourceEventPieces = [SourceEventPiece(bytes: value, range: nil, kind: "hast-generated-text", emissions: [id])]
                try receive(generated, synthetic: true, generatedCharacters: true)
            }
        }
        tokeniser.endEmissions()
    }

    /// Tokenizes up to the current emission boundary; pending characters are returned as a token before the boundary.
    private func drainEmission() throws {
        while true {
            let token: Token = try tokeniser.read()
            if tokeniser.reachedEmissionBoundary { return }
            try receive(token, synthetic: false)
            if token.type == .EOF { return }
        }
    }

    /// hast-util-raw `startTag`/`endTag`: generated markup never passes through the current tokenizer state. The chunk is
    /// tokenized in the data state and each token is handed to the tree builder with the real tokenizer state in place,
    /// so `<textarea>`/`<title>` switch to RCDATA as usual, and a generated end tag that names the last start tag leaves
    /// RCDATA/RAWTEXT/script data. PLAINTEXT swallows generated markup like hast-util-raw does.
    private func processGeneratedMarkup(end: Int) throws {
        var current = tokeniser.getState()
        if current == .PLAINTEXT {
            reader.pos = end
            return
        }
        tokeniser.transition(.Data)
        tokeniser.parsesGeneratedMarkup = true
        defer { tokeniser.parsesGeneratedMarkup = false }
        tokeniser.beginEmission(end: end)
        while true {
            let token: Token = try tokeniser.read()
            if tokeniser.reachedEmissionBoundary { break }
            tokeniser.transition(current)
            switch token.type {
            case .EndTag:
                let endTag = token.asEndTag()
                if endTag.normalName().map({ Tag.isKnownVoid($0) }) == true {
                    // hast-util-raw ignores end tags of void elements outside foreign content.
                    sourceEvents?.token(token)
                    sourceEvents?.event("void-end-tag-ignored", token: token.sourceEventID)
                } else {
                    try receive(token, synthetic: true)
                    if tokeniser.isInTextContentState, tokeniser.isLastStartTag(endTag) { tokeniser.transition(.Data) }
                }
            case .Char:
                // Text inside a generated markup chunk is generated text (a CHARACTER token), never author whitespace.
                token.asCharacter().sourceCharacterInjection = true
                try receive(token, synthetic: true)
            default:
                try receive(token, synthetic: true)
            }
            current = tokeniser.getState()
            tokeniser.transition(.Data)
        }
        tokeniser.continueAfterEmission()
        tokeniser.transition(current)
    }

    /// Hands one token to tree construction. `synthetic` marks tokens that hast-util-raw builds from hast nodes (they
    /// bypass parse5's `onStartTag`); the HTML tree builder uses it for the leading-newline rule. `generatedCharacters`
    /// records the token as an injected generated text token.
    func receive(_ token: Token, synthetic: Bool, generatedCharacters: Bool = false) throws {
        sourceEvents?.token(token, generated: generatedCharacters)
        let before = stack
        try process(token)
        sourceEvents?.stackChanged(before: before, after: stack)
    }

    @discardableResult
    @inline(__always)
    public func process(_ token: Token)throws->Bool {preconditionFailure("This method must be overridden")}
    
    @discardableResult
    @inline(__always)
    public func processStartTag(_ name: [UInt8]) throws -> Bool {
        if (currentToken === start) { // don't recycle an in-use token
            return try process(Token.StartTag().name(name))
        }
        return try process(start.reset().name(name))
    }
    
    @discardableResult
    @inline(__always)
    public func processStartTag(_ name: String) throws -> Bool {
        return try processStartTag(name.utf8Array)
    }
    
    @discardableResult
    @inline(__always)
    public func processStartTag(_ name: [UInt8], _ attrs: Attributes) throws -> Bool {
        if (currentToken === start) { // don't recycle an in-use token
            return try process(Token.StartTag().nameAttr(name, attrs))
        }
        start.reset()
        start.nameAttr(name, attrs)
        return try process(start)
    }
    
    @discardableResult
    @inline(__always)
    public func processStartTag(_ name: String, _ attrs: Attributes) throws -> Bool {
        return try processStartTag(name.utf8Array, attrs)
    }
    
    @discardableResult
    @inline(__always)
    public func processEndTag(_ name: [UInt8]) throws -> Bool {
        if (currentToken === end) { // don't recycle an in-use token
            return try process(Token.EndTag().name(name))
        }
        
        return try process(end.reset().name(name))
    }

    
    @discardableResult
    @inline(__always)
    public func processEndTag(_ name: String) throws -> Bool {
        return try processEndTag(name.utf8Array)
    }
    
    @inline(__always)
    public func currentElement() -> Element? {
        return stack.last
    }
}
