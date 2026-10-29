import CryptoKit
import Foundation
import Testing
@testable import AIMarkdownHTML

/// Differential oracle for the `<template>` fragment context: `Fixtures/template-context.json` is produced by
/// `scripts/template-context-oracle/export.mjs` with parse5 7.3.0 (`parseFragment` without a context element, the
/// configuration hast-util-raw 9.1.3 uses). Every corpus entry must build the same tree here.
struct HTMLTemplateContextTests {
    private struct Oracle: Decodable { let parse5: String; let cases: [Item] }
    private struct Item: Decodable { let id: String; let html: String; let tree: [TreeNode]?; let digest: String; let leadingLFDigest: String }
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

    /// Pre-existing tree-builder differences that are not part of the template fragment context and stay enumerated
    /// by id: each listed case must still differ, so a fix here is noticed and the list shrinks.
    static let enumeratedDifferences: [String: String] = [
        "rcdata-unclosed": rcdataBreakout,
        "null-char": "U+0000 inside character data is kept; parse5 drops NULL character tokens in body",
        // Boundary-oracle frames with an unclosed <title> or <textarea> (same RCDATA breakout).
        "boundary/fuzz-hazard-11#7": rcdataBreakout, "boundary/fuzz-hazard-11#8": rcdataBreakout, "boundary/fuzz-hazard-11#21": rcdataBreakout,
        "boundary/fuzz-hazard-48#15": rcdataBreakout, "boundary/fuzz-hazard-48#16": rcdataBreakout, "boundary/fuzz-hazard-48#17": rcdataBreakout,
        "boundary/fuzz-hazard-48#18": rcdataBreakout, "boundary/fuzz-hazard-48#19": rcdataBreakout, "boundary/fuzz-hazard-48#20": rcdataBreakout,
        "boundary/fuzz-hazard-51#7": rcdataBreakout, "boundary/fuzz-hazard-51#8": rcdataBreakout, "boundary/fuzz-hazard-51#15": rcdataBreakout,
    ]
    static let rcdataBreakout = "jsoup/SwiftSoup leave RCDATA early when no matching end tag follows (<title>x<p>y); parse5 reads to EOF"

    /// The second enumerated class is parse5's `skipNextNewLine` (one LF dropped after <pre>, <listing> and <textarea>
    /// start tags), which this tree builder does not implement yet (see HTMLRawEOLTests `leading-pre-LF`). A corpus entry
    /// whose trees become equal once that single LF is dropped on both sides belongs to this class only.
    private static func droppingLeadingLF(_ nodes: [TreeNode]) -> [TreeNode] {
        nodes.map { node in
            guard case let .element(name, attributes, original) = node else { return node }
            var children = droppingLeadingLF(original)
            if ["pre", "listing", "textarea"].contains(name), case let .text(value)? = children.first, value.hasPrefix("\n") {
                let rest = String(value.dropFirst())
                if rest.isEmpty { children.removeFirst() } else { children[0] = .text(rest) }
            }
            return .element(name: name, attributes: attributes, children: children)
        }
    }

    private struct Difference { let id: String; let leadingLFOnly: Bool; let report: String }

    /// Lists the corpus entries whose Swift tree differs from parse5; empty means full parity. Digest-only entries
    /// (boundary frames) are re-parsed through parse5's recorded digest, so `leadingLFOnly` is decided by re-digesting
    /// the LF-normalized Swift tree against the LF-normalized parse5 tree when the latter is stored, and otherwise by
    /// the entry's `leadingLFDigest`.
    private static func differences(_ oracle: Oracle, parse: (String) throws -> [Node]) rethrows -> [Difference] {
        var failures: [Difference] = []
        for item in oracle.cases {
            let actual = canonical(try parse(item.html))
            if let tree = item.tree {
                guard actual != tree else { continue }
                failures.append(Difference(id: item.id, leadingLFOnly: droppingLeadingLF(actual) == droppingLeadingLF(tree),
                                           report: "\(item.id)\n  html:   \(item.html.debugDescription)\n  parse5: \(tree.map(\.description).joined())\n  swift:  \(actual.map(\.description).joined())"))
            } else if digest(actual) != item.digest {
                failures.append(Difference(id: item.id, leadingLFOnly: digest(droppingLeadingLF(actual)) == item.leadingLFDigest,
                                           report: "\(item.id)\n  html:   \(item.html.debugDescription)\n  swift:  \(actual.map(\.description).joined())"))
            }
        }
        return failures
    }

    private static func check(_ failures: [Difference], _ label: String) -> (leadingLF: Int, enumerated: Int) {
        let unexpected = failures.filter { !$0.leadingLFOnly && enumeratedDifferences[$0.id] == nil }
        #expect(unexpected.isEmpty, Comment(rawValue: "\(label): \(unexpected.count) unexpected difference(s):\n" + unexpected.map(\.report).sorted().joined(separator: "\n")))
        for (id, reason) in enumeratedDifferences {
            #expect(failures.contains { $0.id == id }, "\(label): \(id) no longer differs (\(reason)); remove it from enumeratedDifferences")
        }
        return (failures.filter(\.leadingLFOnly).count, failures.filter { !$0.leadingLFOnly }.count)
    }

    @Test func templateFragmentContextMatchesParse5OnTheWholeCorpus() throws {
        let oracle = try Self.fixture()
        #expect(oracle.parse5 == "7.3.0")
        #expect(oracle.cases.count > 2000)
        #expect(oracle.cases.allSatisfy { $0.tree == nil || Self.digest($0.tree!) == $0.digest }, "digest serialization must match export.mjs")
        let counts = Self.check(try Self.differences(oracle) { try Parser.parseTemplateFragment(Self.normalizedLineEndings($0)) }, "parseTemplateFragment")
        // Pinned so the enumerated classes cannot grow silently; lower them when the leading-LF rule lands.
        #expect(counts.leadingLF == Self.expectedLeadingLFOnly && counts.enumerated == Self.enumeratedDifferences.count, "\(counts)")
    }

    /// Corpus entries that differ only by parse5's leading-LF rule (see `droppingLeadingLF`).
    static let expectedLeadingLFOnly = 35

    @Test func sourceParserTemplateContextBuildsTheSameTreesWithAndWithoutTracking() throws {
        let oracle = try Self.fixture()
        for mode in [false, true] {
            let counts = Self.check(try Self.differences(oracle) { html in
                let emission = SourceInputEmission(id: "raw", kind: "raw", role: "author-raw", value: html, rawUTF8Start: 0, rawUTF8End: html.utf8.count)
                return try HTMLSourceParser.parseFragment([emission], tracking: mode, context: .template).roots
            }, "HTMLSourceParser tracking=\(mode)")
            #expect(counts.leadingLF == Self.expectedLeadingLFOnly && counts.enumerated == Self.enumeratedDifferences.count, "\(counts)")
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
