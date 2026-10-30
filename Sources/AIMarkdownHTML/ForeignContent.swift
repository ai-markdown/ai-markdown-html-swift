import Foundation

/// HTML tree-construction namespaces. DOM APIs retain qualified attribute keys; parser metadata is internal.
@usableFromInline
internal enum HTMLNamespace: String {
    case html = "http://www.w3.org/1999/xhtml"
    case svg = "http://www.w3.org/2000/svg"
    case mathml = "http://www.w3.org/1998/Math/MathML"
}

/// A compact discriminator avoids allocating namespace/prefix storage on ordinary HTML attributes.
internal enum ForeignAttributeNamespace {
    case none, xlink, xml, xmlns, defaultXMLNS

    var uri: String? {
        switch self {
        case .none: return nil
        case .xlink: return "http://www.w3.org/1999/xlink"
        case .xml: return "http://www.w3.org/XML/1998/namespace"
        case .xmlns, .defaultXMLNS: return "http://www.w3.org/2000/xmlns/"
        }
    }
    var prefix: String? {
        switch self {
        case .none: return nil
        case .xlink: return "xlink"
        case .xml: return "xml"
        case .xmlns: return "xmlns"
        case .defaultXMLNS: return ""
        }
    }
}

/// Foreign-content rules from parse5 7.3.0 (`common/foreign-content.js` and `parser/index.js`), MIT.
/// See AIMarkdown/foreign-content-provenance.json for the pinned source and license.
internal enum ForeignContent {
    static let mathText: Set<String> = ["mi", "mo", "mn", "ms", "mtext"]
    static let svgIntegration: Set<String> = ["foreignObject", "desc", "title"]
    static let exits: Set<String> = ["b", "big", "blockquote", "body", "br", "center", "code", "dd", "div", "dl", "dt", "em", "embed", "h1", "h2", "h3", "h4", "h5", "h6", "head", "hr", "i", "img", "li", "listing", "menu", "meta", "nobr", "ol", "p", "pre", "ruby", "s", "small", "span", "strong", "strike", "sub", "sup", "table", "tt", "u", "ul", "var"]
    static let svgTags: [String: String] = Dictionary(uniqueKeysWithValues: ["altGlyph", "altGlyphDef", "altGlyphItem", "animateColor", "animateMotion", "animateTransform", "clipPath", "feBlend", "feColorMatrix", "feComponentTransfer", "feComposite", "feConvolveMatrix", "feDiffuseLighting", "feDisplacementMap", "feDistantLight", "feFlood", "feFuncA", "feFuncB", "feFuncG", "feFuncR", "feGaussianBlur", "feImage", "feMerge", "feMergeNode", "feMorphology", "feOffset", "fePointLight", "feSpecularLighting", "feSpotLight", "feTile", "feTurbulence", "foreignObject", "glyphRef", "linearGradient", "radialGradient", "textPath"].map { ($0.lowercased(), $0) })
    static let svgAttributes: [String: String] = Dictionary(uniqueKeysWithValues: ["attributeName", "attributeType", "baseFrequency", "baseProfile", "calcMode", "clipPathUnits", "diffuseConstant", "edgeMode", "filterUnits", "glyphRef", "gradientTransform", "gradientUnits", "kernelMatrix", "kernelUnitLength", "keyPoints", "keySplines", "keyTimes", "lengthAdjust", "limitingConeAngle", "markerHeight", "markerUnits", "markerWidth", "maskContentUnits", "maskUnits", "numOctaves", "pathLength", "patternContentUnits", "patternTransform", "patternUnits", "pointsAtX", "pointsAtY", "pointsAtZ", "preserveAlpha", "preserveAspectRatio", "primitiveUnits", "refX", "refY", "repeatCount", "repeatDur", "requiredExtensions", "requiredFeatures", "specularConstant", "specularExponent", "spreadMethod", "startOffset", "stdDeviation", "stitchTiles", "surfaceScale", "systemLanguage", "tableValues", "targetX", "targetY", "textLength", "viewBox", "viewTarget", "xChannelSelector", "yChannelSelector", "zoomAndPan"].map { ($0.lowercased(), $0) })
    static let xmlAttributes: [String: ForeignAttributeNamespace] = {
        var result: [String: ForeignAttributeNamespace] = [:]
        for name in ["actuate", "arcrole", "href", "role", "show", "title", "type"] { result["xlink:" + name] = .xlink }
        for name in ["lang", "space"] { result["xml:" + name] = .xml }
        result["xmlns"] = .defaultXMLNS
        result["xmlns:xlink"] = .xmlns
        return result
    }()

    /// parse5 lowercases only the DOM name when matching a foreign end tag. Swift's context-free lowercase
    /// needs the JavaScript Final_Sigma rule: ignore case-ignorable scalars when finding the surrounding cased ones.
    static func matchesEndTag(_ element: Element, name: [UInt8]) -> Bool {
        let bytes = element.tagNameUTF8()
        if !bytes.contains(where: { $0 >= 128 }) { return element.tagNameNormalUTF8() == name }
        let scalars = Array(element.tagName().unicodeScalars)
        var finalCandidates = Array(repeating: false, count: scalars.count)
        var following = false
        for index in scalars.indices.reversed() {
            let scalar = scalars[index]
            finalCandidates[index] = scalar.value == 0x3A3 && !following
            if !scalar.properties.isCaseIgnorable { following = scalar.properties.isCased }
        }
        var result = ""
        var preceding = false
        for index in scalars.indices {
            let scalar = scalars[index]
            if finalCandidates[index], preceding { result.unicodeScalars.append("\u{3C2}") }
            else { result += scalar.properties.lowercaseMapping }
            if !scalar.properties.isCaseIgnorable { preceding = scalar.properties.isCased }
        }
        return result.utf8.elementsEqual(name)
    }

    static func isHTMLIntegrationPoint(_ element: Element) -> Bool {
        if element.htmlNamespace == .svg { return svgIntegration.contains(element.tagName()) }
        if element.htmlNamespace == .mathml, element.tagNameNormal() == "annotation-xml" {
            let encoding = (try? element.attr("encoding")) ?? ""
            return encoding.lowercased() == "text/html" || encoding.lowercased() == "application/xhtml+xml"
        }
        return false
    }
    static func isMathTextIntegrationPoint(_ element: Element) -> Bool {
        element.htmlNamespace == .mathml && mathText.contains(element.tagName())
    }
    static func isIntegrationPoint(_ element: Element) -> Bool {
        isMathTextIntegrationPoint(element) || isHTMLIntegrationPoint(element)
    }
    static func isScopeBoundary(_ element: Element) -> Bool {
        (element.htmlNamespace == .mathml && (mathText.contains(element.tagName()) || element.tagName() == "annotation-xml")) ||
            (element.htmlNamespace == .svg && svgIntegration.contains(element.tagName()))
    }
}

extension HtmlTreeBuilder {
    func adjustedCurrentElement() -> Element? {
        fragmentParsing && stack.count == 1 ? contextElement : currentElement()
    }

    func updateForeignTokenizerContext() {
        guard let current = adjustedCurrentElement(), current.htmlNamespace != .html else {
            tokeniser.inForeignNode = false
            return
        }
        tokeniser.inForeignNode = !ForeignContent.isIntegrationPoint(current)
    }

    func shouldProcessInForeignContent(_ token: Token, current: Element) -> Bool {
        switch token.type {
        case .EOF: return false
        case .StartTag:
            let name = String(decoding: token.asStartTag().normalName() ?? [], as: UTF8.self)
            if name == "svg", current.htmlNamespace == .mathml, current.tagName() == "annotation-xml" { return false }
            if ForeignContent.isHTMLIntegrationPoint(current) { return false }
            return !ForeignContent.isMathTextIntegrationPoint(current) || name == "mglyph" || name == "malignmark"
        case .Char: return !ForeignContent.isIntegrationPoint(current)
        default: return true
        }
    }

    @discardableResult
    func insertForeign(_ token: Token.StartTag, namespace: HTMLNamespace) throws -> Element {
        let normalName = String(decoding: token.normalName() ?? [], as: UTF8.self)
        let name = namespace == .svg ? ForeignContent.svgTags[normalName] ?? normalName : normalName
        token.ensureAttributes()
        let attributes = Attributes()
        for attribute in token._attributes?.asList() ?? [] {
            // Raw HTML uses ASCII folding; synthetic HAST attributes are already supplied keys (Unicode intact).
            let key = tokeniser.parsesGeneratedMarkup ? attribute.getKey() : String(decoding: attribute.getKeyUTF8().lowercased(), as: UTF8.self)
            let adjusted = namespace == .svg ? ForeignContent.svgAttributes[key] ?? key : (key == "definitionurl" ? "definitionURL" : key)
            if attributes.hasKey(key: adjusted) { continue }
            let value = try Attribute(key: adjusted, value: attribute.getValue())
            if let xml = ForeignContent.xmlAttributes[key] { value.foreignAttributeNamespace = xml }
            attributes.put(attribute: value)
        }
        // Keep formatting traits without reusing HTML void/form semantics; namespace controls raw-text handling.
        let element = Element(try Tag.foreign(name), baseUri, attributes, skipChildReserve: true)
        element.htmlNamespace = namespace
        sourceEvents?.created(element, token: token, generated: token.sourceEventID == nil ? "parser-generated-start-tag" : nil)
        if let range = token.sourceRange { element.setSourceRange(range, complete: token.isSelfClosing()) }
        try insertNode(element)
        if token.isSelfClosing() { tokeniser.acknowledgeSelfClosingFlag() }
        else { push(element) }
        return element
    }

    func popUntilHTMLOrIntegrationPoint() {
        while let current = currentElement(), current.htmlNamespace != .html, !ForeignContent.isIntegrationPoint(current) { pop() }
    }

    @discardableResult
    func processForeignContent(_ token: Token, current: Element) throws -> Bool {
        switch token.type {
        case .Char:
            let character = token.asCharacter()
            // parse5 replaces NULL_CHARACTER tokens only; a generated CHARACTER token keeps its actual value.
            if !character.sourceCharacterInjection, character.getData() == [0] {
                // The old one-byte source range cannot represent the three-byte replacement value.
                character.sourceRange = nil
                character.data(Array("\u{FFFD}".utf8))
                character.sourceEventPieces = character.sourceEventPieces.map {
                    SourceEventPiece(bytes: Array("\u{FFFD}".utf8), range: $0.range, kind: "replacement-character", emissions: $0.emissions)
                }
            }
            try insert(character)
            if !HtmlTreeBuilderState.isWhitespace(character) { framesetOk(false) }
            return true
        case .Comment: try insert(token.asComment()); return true
        case .Doctype: error(.ForeignContent); return false
        case .StartTag:
            let start = token.asStartTag()
            let name = String(decoding: start.normalName() ?? [], as: UTF8.self)
            start.ensureAttributes()
            let fontExit = name == "font" && ["color", "size", "face"].contains { start._attributes?.hasKey(key: $0) == true }
            if ForeignContent.exits.contains(name) || fontExit {
                popUntilHTMLOrIntegrationPoint()
                return try process(token, state())
            }
            try insertForeign(start, namespace: current.htmlNamespace)
            return true
        case .EndTag:
            let end = token.asEndTag()
            let name = end.normalName() ?? []
            if name == Array("p".utf8) || name == Array("br".utf8) {
                popUntilHTMLOrIntegrationPoint()
                return try process(token, state())
            }
            // The fragment context is not on the open-element stack, so it must never be popped.
            var index = stack.count - 1
            while index > 0 {
                let element = stack[index]
                if element.htmlNamespace == .html { return try process(token, state()) }
                if ForeignContent.matchesEndTag(element, name: name) {
                    // Keep source closing ranges compatible with adjusted camelCase SVG names.
                    if let range = token.sourceRange { element.setSourceRangeEnd(range.end) }
                    while stack.count > index { pop() }
                    break
                }
                index -= 1
            }
            return true
        case .EOF: return try process(token, state())
        }
    }
}
