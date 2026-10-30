import Foundation
import Testing
@testable import AIMarkdownHTML

/// Full trees from the pinned Web packages, including namespace and qualified XML attributes.
struct HTMLForeignContentTests {
    private struct Oracle: Decodable {
        let parse5: String
        let cases: [Item]
        let sequences: [Sequence]
    }
    private struct Item: Decodable { let id: String; let html: String; let tree: [Tree]; let bodyTree: [Tree]; let rawTree: [Tree] }
    private struct Sequence: Decodable { let id: String; let input: HAST; let tree: [Tree] }
    private struct HAST: Decodable { let type: String; let value: String?; let tagName: String?; let properties: [String: String]?; let children: [HAST]? }
    private struct Attr: Codable, Equatable { let name: String; let value: String; let namespace: String?; let prefix: String? }
    private struct Tree: Codable, Equatable {
        let type: String
        var value: String?
        var name: String?
        var namespace: String?
        var attributes: [Attr]?
        var children: [Tree]?
    }

    private func oracle() throws -> Oracle {
        let fixtures = try #require(Bundle.module.url(forResource: "Fixtures", withExtension: nil))
        return try JSONDecoder().decode(Oracle.self, from: Data(contentsOf: fixtures.appendingPathComponent("foreign-content.json")))
    }

    private func canonical(_ nodes: [Node]) -> [Tree] {
        var result: [Tree] = []
        for node in nodes {
            let tree: Tree
            if let text = node as? TextNode { tree = Tree(type: "text", value: text.getWholeText()) }
            else if let data = node as? DataNode { tree = Tree(type: "text", value: data.getWholeData()) }
            else if let comment = node as? AIMarkdownHTML.Comment { tree = Tree(type: "comment", value: comment.getData()) }
            else if node is DocumentType { tree = Tree(type: "doctype") }
            else if let element = node as? Element {
                let attributes = (element.getAttributes()?.asList() ?? []).map {
                    Attr(name: $0.getKey(), value: $0.getValue(), namespace: $0.foreignNamespace, prefix: $0.foreignPrefix)
                }.sorted { $0.name < $1.name }
                tree = Tree(type: "element", name: element.tagName(), namespace: element.htmlNamespace.rawValue,
                            attributes: attributes, children: canonical(element.getChildNodes()))
            } else { continue }
            if tree.type == "text", result.last?.type == "text" { result[result.count - 1].value! += tree.value! }
            else { result.append(tree) }
        }
        return result
    }

    private func sorted(_ trees: [Tree]) -> [Tree] {
        trees.map { value in
            var tree = value
            tree.attributes = tree.attributes?.sorted { $0.name < $1.name }
            tree.children = tree.children.map(sorted)
            return tree
        }
    }

    private func compare(_ actual: [Tree], _ expected: [Tree], id: String) {
        let expected = sorted(expected)
        if actual != expected {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            print("foreign mismatch \(id)\nactual: \(String(decoding: (try? encoder.encode(actual)) ?? Data(), as: UTF8.self))\nexpected: \(String(decoding: (try? encoder.encode(expected)) ?? Data(), as: UTF8.self))")
        }
        #expect(actual == expected, Comment(rawValue: id))
    }

    @MainActor @Test func completeFragmentTreesAndNamespacesMatchParse5() throws {
        let oracle = try oracle()
        #expect(oracle.parse5 == "7.3.0")
        #expect(oracle.cases.count > 250)
        for item in oracle.cases {
            compare(canonical(try Parser.parseTemplateFragment(item.html)), item.tree, id: item.id + ":template")
            let builder = HtmlTreeBuilder()
            builder.sourceParserHTML5Mode = true
            let body = try Element(Tag.valueOf("body"), "")
            let roots = try builder.parseFragment(Array(item.html.utf8), body, [], ParseErrorList.noTracking(), ParseSettings.htmlDefault)
            compare(canonical(roots), item.bodyTree, id: item.id + ":html5-body")
            let input = [SourceInputEmission(id: "raw", kind: "raw", role: "author-raw", value: item.html, rawUTF8Start: 0, rawUTF8End: item.html.utf8.count)]
            for tracking in [false, true] {
                let raw = try HTMLSourceParser.parseFragment(input, tracking: tracking, context: .template)
                compare(canonical(raw.roots), item.rawTree, id: item.id + ":raw-tracking=\(tracking)")
            }
        }
    }

    private func emissions(_ hast: HAST) -> [SourceInputEmission] {
        var result: [SourceInputEmission] = []
        var offset = 0
        func emit(_ value: String, kind: String, role: String) {
            let end = offset + (kind == "characters" ? 0 : value.utf8.count)
            result.append(SourceInputEmission(id: "e\(result.count)", kind: kind, role: role, value: value, rawUTF8Start: offset, rawUTF8End: end))
            offset = end
        }
        func visit(_ node: HAST) {
            switch node.type {
            case "raw": emit(node.value ?? "", kind: "raw", role: "author-raw")
            case "text": emit(node.value ?? "", kind: "characters", role: "hast-generated-text")
            case "element":
                let attributes = (node.properties ?? [:]).keys.sorted().map { key in
                    let value = node.properties![key]!.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "\"", with: "&quot;")
                    return " \(key)=\"\(value)\""
                }.joined()
                emit("<\(node.tagName!)\(attributes)>", kind: "raw", role: "hast-generated-tag")
                for child in node.children ?? [] { visit(child) }
                emit("</\(node.tagName!)>", kind: "raw", role: "hast-generated-tag")
            default: for child in node.children ?? [] { visit(child) }
            }
        }
        visit(hast)
        return result
    }

    @MainActor @Test func actualHastRawSequencesPreserveTrackingAndNamespaceSemantics() throws {
        let oracle = try oracle()
        #expect(oracle.sequences.count == 196)
        for item in oracle.sequences {
            let input = emissions(item.input)
            for context in [HTMLFragmentContext.body, .template] {
                for tracking in [false, true] {
                    let parsed = try HTMLSourceParser.parseFragment(input, tracking: tracking, context: context)
                    compare(canonical(parsed.roots), item.tree, id: item.id + ":context=\(context.rawValue):tracking=\(tracking)")
                    if tracking {
                        let trace = try #require(parsed.trace)
                        #expect(!trace.gaps.contains("unobserved-create-site"), Comment(rawValue: item.id))
                        for record in trace.nodes where record.finalPath != nil && record.name == "#text" {
                            #expect(!record.pieces.isEmpty, Comment(rawValue: item.id))
                        }
                        #expect(parsed.roots.allSatisfy { $0.htmlSourceIdentity != nil })
                    } else {
                        #expect(parsed.trace == nil)
                        #expect(parsed.roots.allSatisfy { $0.htmlSourceIdentity == nil })
                    }
                }
            }
        }
    }

    @MainActor @Test func html5SelfClosingRecoveryDoesNotChangeTheLegacyBodyOrXMLAPIs() throws {
        let source = "<g/>tail"
        let legacy = try AIMarkdownHTML.parseBodyFragment(source).body()
        #expect(try #require(legacy).childNodeSize() == 2)
        #expect(try #require(legacy).child(0).text() == "")
        let html5 = try Parser.parseTemplateFragment(source)
        #expect(html5.count == 1)
        #expect(try #require(html5.first as? Element).text() == "tail")
        let xml = try Parser.xmlParser().parseInput("<g/><x><![CDATA[<literal>&amp;]]></x>", "")
        #expect(try xml.select("x").text() == "<literal>&amp;")
    }

    @MainActor @Test func foreignScriptTextSerializesAsTextAndNotHTMLRawtext() throws {
        let html = "<svg><script>a &lt; b &amp; c</script></svg>"
        let document = try AIMarkdownHTML.parseBodyFragment(html)
        document.outputSettings().prettyPrint(pretty: false)
        #expect(try document.body()?.html() == html)
        let script = try #require(document.select("script").first())
        #expect(script.htmlNamespace == .svg)
        #expect(script.getChildNodes().first is TextNode)
        #expect(!script.serializesAsRawText())
    }

    @MainActor @Test func adjustedSVGClosesAndReplacementCharactersKeepTheirRealSources() throws {
        let html = "<svg><foreignObject><p>x</p></foreignObject><g>\0<![CDATA[y\0z]]></g></svg>"
        let input = [SourceInputEmission(id: "raw", kind: "raw", role: "author-raw", value: html, rawUTF8Start: 0, rawUTF8End: html.utf8.count)]
        let parsed = try HTMLSourceParser.parseFragment(input, tracking: true)
        let trace = try #require(parsed.trace)
        let foreign = try #require(trace.nodes.first { $0.name == "foreignObject" })
        #expect(foreign.endTokens.count == 1, "camelCase SVG nodes must retain their explicit end token")
        let texts = trace.nodes.filter { $0.name == "#text" && $0.finalPath != nil }
        #expect(texts.flatMap(\.pieces).filter { $0.kind == "replacement-character" }.count == 2)
        for piece in texts.flatMap(\.pieces) where piece.kind == "replacement-character" {
            let range = try #require(piece.range)
            #expect(Array(html.utf8)[range[0]..<range[1]] == [0])
            #expect(piece.bytes == Array("\u{FFFD}".utf8))
        }
    }

    @MainActor @Test func clonedForeignTreesKeepMetadataAndSnapshotsDoNotRetainDOM() throws {
        weak var weakRoot: Node?
        var snapshot: HTMLSourceSnapshot?
        do {
            let html = "<svg><linearGradient viewBox='x'/><a xlink:href='url' xml:lang='en'/></svg>"
            let input = [SourceInputEmission(id: "raw", kind: "raw", role: "author-raw", value: html, rawUTF8Start: 0, rawUTF8End: html.utf8.count)]
            let parsed = try HTMLSourceParser.parseFragment(input, tracking: true)
            let root = try #require(parsed.roots.first)
            weakRoot = root
            let clone = try #require(root.copy() as? Node)
            #expect(canonical([root]) == canonical([clone]))
            snapshot = parsed.trace
        }
        #expect(weakRoot == nil)
        #expect(snapshot != nil)
    }
}
