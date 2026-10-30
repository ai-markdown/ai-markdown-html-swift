import CryptoKit
import Foundation
import Testing
@testable import AIMarkdownHTML

/// Differential oracle for the `<template>` fragment context: `Fixtures/template-context.json` is produced by
/// `scripts/template-context-oracle/export.mjs` with parse5 7.3.0 (`parseFragment` without a context element, the
/// configuration hast-util-raw 9.1.3 uses). Every corpus entry records two trees: `tree`/`digest` from `parseFragment`
/// (EOF included), which the string entry point must reproduce, and `rawTree`/`rawDigest` from the hast-util-raw
/// driving sequence for one raw node (no EOF: an unfinished token at the end is dropped and pending table characters
/// are never inserted), which `HTMLSourceParser` must reproduce.
struct HTMLTemplateContextTests {
    private struct Oracle: Decodable { let parse5: String; let cases: [Item] }
    private struct Item: Decodable { let id: String; let html: String; let tree: [TreeNode]?; let digest: String; let rawTree: [TreeNode]?; let rawDigest: String }
    private indirect enum TreeNode: Decodable, Equatable, CustomStringConvertible {
        case text(String)
        case comment(String)
        case doctype
        case element(name: String, attributes: [String: String], children: [TreeNode])

        private enum CodingKeys: String, CodingKey { case type, value, name, attributes, children }
        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            switch try container.decode(String.self, forKey: .type) {
            case "text": self = .text(try container.decode(String.self, forKey: .value))
            case "comment": self = .comment(try container.decode(String.self, forKey: .value))
            case "doctype": self = .doctype
            default:
                self = .element(name: try container.decode(String.self, forKey: .name),
                                attributes: try container.decode([String: String].self, forKey: .attributes),
                                children: try container.decode([TreeNode].self, forKey: .children))
            }
        }

        /// Compact serialization shared with `scripts/template-context-oracle/export.mjs` (`serialize`).
        var serialized: String {
            switch self {
            case let .text(value): return "t\(value.utf8.count):\(value)"
            case let .comment(value): return "c\(value.utf8.count):\(value)"
            case .doctype: return "d"
            case let .element(name, attributes, children):
                let names = attributes.keys.sorted { Array($0.utf8).lexicographicallyPrecedes(Array($1.utf8)) }
                let attrs = names.map { "a\($0.utf8.count):\($0)=\(attributes[$0]!.utf8.count):\(attributes[$0]!)" }.joined()
                return "e\(name)(\(attrs))[" + children.map(\.serialized).joined() + "]"
            }
        }

        var description: String {
            switch self {
            case let .text(value): return "#text(\(value.debugDescription))"
            case let .comment(value): return "#comment(\(value.debugDescription))"
            case .doctype: return "#doctype"
            case let .element(name, attributes, children):
                let attrs = attributes.keys.sorted().map { " \($0)=\(attributes[$0]!.debugDescription)" }.joined()
                return "<\(name)\(attrs)>" + children.map(\.description).joined() + "</\(name)>"
            }
        }
    }

    /// Canonical form of a parsed tree; template children stand in for parse5's template content fragment. Adjacent
    /// text nodes are merged: parse5 appends adjacent character tokens to one text node, while this tree builder keeps
    /// one node per token so source tracking can attribute each of them (consumers merge, see the AI Markdown engine).
    private static func canonical(_ nodes: [Node]) -> [TreeNode] {
        var result: [TreeNode] = []
        for node in nodes {
            let value: TreeNode
            if let text = node as? TextNode { value = .text(text.getWholeText()) }
            else if let data = node as? DataNode { value = .text(data.getWholeData()) }
            else if let comment = node as? AIMarkdownHTML.Comment { value = .comment(comment.getData()) }
            else if node is DocumentType { value = .doctype }
            else if let element = node as? Element {
                var attributes: [String: String] = [:]
                for attribute in element.getAttributes()?.asList() ?? [] { attributes[attribute.getKey()] = attribute.getValue() }
                value = .element(name: element.tagName(), attributes: attributes, children: canonical(element.getChildNodes()))
            } else { continue }
            if case let .text(next) = value, case let .text(previous)? = result.last {
                result[result.count - 1] = .text(previous + next)
            } else {
                result.append(value)
            }
        }
        return result
    }

    /// parse5's preprocessor normalizes CR and CRLF to LF before tokenizing; the plain string entry point does not
    /// (`HTMLSourceParser` normalizes author raw input itself), so the plain comparison feeds pre-normalized input.
    private static func normalizedLineEndings(_ html: String) -> String {
        html.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
    }

    private static func fixture() throws -> Oracle {
        let url = try #require(Bundle.module.url(forResource: "template-context", withExtension: "json", subdirectory: "Fixtures"))
        return try JSONDecoder().decode(Oracle.self, from: Data(contentsOf: url))
    }

    private static func digest(_ tree: [TreeNode]) -> String {
        SHA256.hash(data: Data(tree.map(\.serialized).joined().utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// All formerly enumerated template-context differences now match the pinned parse5 oracle.
    static let enumeratedDifferences: [String: String] = [:]

    private struct Difference { let id: String; let report: String }

    /// Lists the corpus entries whose Swift tree differs from parse5; empty means full parity. `raw` selects the
    /// hast-util-raw trees (`rawTree`/`rawDigest`) instead of the `parseFragment` trees.
    private static func differences(_ oracle: Oracle, raw: Bool, parse: (String) throws -> [Node]) rethrows -> [Difference] {
        var failures: [Difference] = []
        for item in oracle.cases {
            let actual = canonical(try parse(item.html))
            let expectedTree = raw ? item.rawTree : item.tree, expectedDigest = raw ? item.rawDigest : item.digest
            if let tree = expectedTree {
                guard actual != tree else { continue }
                failures.append(Difference(id: item.id, report: "\(item.id)\n  html:   \(item.html.debugDescription)\n  parse5: \(tree.map(\.description).joined())\n  swift:  \(actual.map(\.description).joined())"))
            } else if digest(actual) != expectedDigest {
                failures.append(Difference(id: item.id, report: "\(item.id)\n  html:   \(item.html.debugDescription)\n  swift:  \(actual.map(\.description).joined())"))
            }
        }
        return failures
    }

    private static func check(_ failures: [Difference], _ label: String) {
        let unexpected = failures.filter { enumeratedDifferences[$0.id] == nil }
        if let path = ProcessInfo.processInfo.environment["HTML_TEMPLATE_CONTEXT_REPORT"], !unexpected.isEmpty {
            try? (unexpected.map(\.report).joined(separator: "\n\n") + "\n").write(to: URL(fileURLWithPath: path).appendingPathExtension(label.replacingOccurrences(of: "=", with: "-")), atomically: true, encoding: .utf8)
        }
        #expect(unexpected.isEmpty, Comment(rawValue: "\(label): \(unexpected.count) unexpected difference(s):\n" + unexpected.map(\.report).sorted().joined(separator: "\n")))
        for (id, reason) in enumeratedDifferences {
            #expect(failures.contains { $0.id == id }, "\(label): \(id) no longer differs (\(reason)); remove it from enumeratedDifferences")
        }
        // Pinned so the enumerated class cannot grow silently.
        #expect(failures.count == enumeratedDifferences.count, "\(label): \(failures.map(\.id))")
    }

    @Test func templateFragmentContextMatchesParse5OnTheWholeCorpus() throws {
        let oracle = try Self.fixture()
        #expect(oracle.parse5 == "7.3.0")
        #expect(oracle.cases.count > 2000)
        #expect(oracle.cases.allSatisfy { $0.tree == nil || Self.digest($0.tree!) == $0.digest }, "digest serialization must match export.mjs")
        #expect(oracle.cases.allSatisfy { $0.rawTree == nil || Self.digest($0.rawTree!) == $0.rawDigest }, "digest serialization must match export.mjs")
        Self.check(try Self.differences(oracle, raw: false) { try Parser.parseTemplateFragment(Self.normalizedLineEndings($0)) }, "parseTemplateFragment")
    }

    /// `HTMLSourceParser` follows hast-util-raw: no EOF reaches tree construction. The corpus entries whose
    /// `parseFragment` and hast-util-raw trees differ are exactly the ones ending in an unfinished token (dropped) or
    /// with pending table characters (never inserted); both entry points must match their own oracle.
    @Test func sourceParserTemplateContextBuildsTheSameTreesWithAndWithoutTracking() throws {
        let oracle = try Self.fixture()
        let eofSensitive = oracle.cases.filter { $0.digest != $0.rawDigest }.map(\.id)
        #expect(eofSensitive.count == 21, "\(eofSensitive)")
        #expect(Set(["unfinished-comment", "unfinished-pi", "entity-at-end", "tr-first", "boundary/fuzz-hazard-51#1"]).isSubset(of: eofSensitive))
        for mode in [false, true] {
            Self.check(try Self.differences(oracle, raw: true) { html in
                let emission = SourceInputEmission(id: "raw", kind: "raw", role: "author-raw", value: html, rawUTF8Start: 0, rawUTF8End: html.utf8.count)
                return try HTMLSourceParser.parseFragment([emission], tracking: mode, context: .template).roots
            }, "HTMLSourceParser tracking=\(mode)")
        }
    }

    @Test func bodyContextKeepsTheHistoricalBehavior() throws {
        // The default entry points still parse as <body> content: table parts without a table are dropped there.
        let body = try #require(parseBodyFragment("<td>orphan</td>a</s>b").body())
        #expect(Self.canonical(body.getChildNodes()) == [.text("orphanab")])
        #expect(Self.canonical(try parseTemplateFragment("<td>orphan</td>a</s>b")) == [
            .element(name: "td", attributes: [:], children: [.text("orphan")]), .text("ab"),
        ])
        #expect(Self.canonical(try parseTemplateFragment("<col>a</s>b")) == [.element(name: "col", attributes: [:], children: [])])
        #expect(Self.canonical(try parseTemplateFragment("<tr>a</s>b")) == [
            .element(name: "tr", attributes: [:], children: []), .text("ab"),
        ])
        #expect(Self.canonical(try parseTemplateFragment("<template><p>a</template>b")) == [
            .element(name: "template", attributes: [:], children: [.element(name: "p", attributes: [:], children: [.text("a")])]), .text("b"),
        ])
    }

    @Test func fosteredContentInsideTemplateStaysInTheTemplate() throws {
        let raw = "<template><table>x</table></template>"
        let input = [SourceInputEmission(id: "raw", kind: "raw", role: "author-raw", value: raw, rawUTF8Start: 0, rawUTF8End: raw.utf8.count)]
        let parsed = try HTMLSourceParser.parseFragment(input, tracking: true, context: .template)
        let trace = try #require(parsed.trace)
        #expect(!trace.gaps.contains("template-foster-location-not-supported"))
        #expect(Self.canonical(parsed.roots) == [.element(name: "template", attributes: [:], children: [
            .text("x"), .element(name: "table", attributes: [:], children: []),
        ])])
        #expect(trace.events.contains { $0.kind == "foster-text" })
    }
}
