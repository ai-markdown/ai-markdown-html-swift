import Foundation
import Testing
@testable import AIMarkdownHTML

struct HTMLSourceEventsTests {
    private struct Oracle: Decodable {
        let cases: [Item]
        struct Item: Decodable {
            let id: String
            let rawSource: String
            let segments: [SourceInputEmission]
            let semantic: SourceDOMNode
        }
    }
    private struct Observations: Decodable { let webDifferent: [String] }

    private func fixtures() throws -> (Oracle, Observations) {
        let root = try #require(Bundle.module.url(forResource: "Fixtures", withExtension: nil))
        return try (
            JSONDecoder().decode(Oracle.self, from: Data(contentsOf: root.appendingPathComponent("html-source-oracle.json"))),
            JSONDecoder().decode(Observations.self, from: Data(contentsOf: root.appendingPathComponent("html-source-observations.json")))
        )
    }

    private func encoded<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(value)
    }

    private func emission(_ value: String) -> [SourceInputEmission] {
        [SourceInputEmission(id: "raw", kind: "raw", role: "author-raw", value: value, rawUTF8Start: 0, rawUTF8End: value.utf8.count)]
    }

    @Test func defaultParsingHasNoTracingIdentity() throws {
        let document = try AIMarkdownHTML.parseBodyFragment("<p>A&amp;B</p>")
        func check(_ node: Node) {
            #expect(node.htmlSourceIdentity == nil)
            for child in node.getChildNodes() { check(child) }
        }
        check(document)
        let result = try HTMLSourceParser.parseFragment(emission("<p>x</p>"))
        #expect(result.trace == nil)
        #expect(result.roots.allSatisfy { $0.parent() == nil })
        for root in result.roots { check(root) }
    }

    // The upstream state machine has large ASan stack frames; run the full matrix on the main thread with its normal stack budget.
    @MainActor @Test func fullOracleAndTrackingModesPreserveExistingSemantics() throws {
        let (oracle, observations) = try fixtures()
        var differences: [String] = []
        var copies = Set<String>()
        var mergeCount = 0
        for item in oracle.cases {
            let off = try HTMLSourceParser.parseFragment(item.segments)
            let on = try HTMLSourceParser.parseFragment(item.segments, tracking: true)
            let trace = try #require(on.trace)
            #expect(try encoded(trace.semantic) == encoded(SourceEventRecorder(bytes: [], emissions: []).result(off.roots).semantic))
            if try encoded(trace.semantic) != encoded(item.semantic) { differences.append(item.id) }
            #expect(on.roots.allSatisfy { $0.htmlSourceIdentity?.scope == trace.scope })
            copies.formUnion(trace.events.filter { $0.kind == "clone" }.compactMap(\.note))
            try validate(trace, input: item.rawSource)
            for trackRanges in [true, false] {
                if !trackRanges, item.segments.contains(where: { $0.kind == "characters" }) { continue }
                let documentOff = try HTMLSourceParser.parse(item.segments, document: true, trackRanges: trackRanges)
                let documentOn = try HTMLSourceParser.parse(item.segments, tracking: true, document: true, trackRanges: trackRanges)
                let documentTrace = try #require(documentOn.trace)
                #expect(try encoded(documentTrace.semantic) == encoded(SourceEventRecorder(bytes: [], emissions: []).result(documentOff.roots).semantic))
                if !trackRanges { mergeCount += documentTrace.events.filter { $0.kind == "text-merge" }.count }
                try validate(documentTrace, input: item.rawSource)
            }
        }
        #expect(oracle.cases.count == 95)
        #expect(differences == observations.webDifferent)
        #expect(Set(["formatting-reconstruct", "adoption-replacement", "adoption-adopter"]).isSubset(of: copies))
        #expect(mergeCount == 11)
    }

    private func validate(_ trace: HTMLSourceSnapshot, input: String) throws {
        let bytes = Array(input.utf8)
        let verifier = SourceEventRecorder(bytes: bytes, emissions: [])
        let tokens = Dictionary(uniqueKeysWithValues: trace.tokens.map { ($0.id, $0) })
        for token in trace.tokens {
            if let range = token.range { #expect(verifier.checked(range) == range) }
        }
        for node in trace.nodes {
            for piece in node.pieces {
                if let range = piece.range {
                    #expect(verifier.checked(range) == range)
                    if piece.kind == "copy" { #expect(piece.bytes == Array(bytes[range[0] ..< range[1]])) }
                }
                if piece.kind == "hast-generated-text" { #expect(piece.range == nil) }
            }
            if node.kind == "clone" {
                #expect(node.startTokens.isEmpty)
                #expect(!node.derivedFrom.isEmpty)
            }
            if ["parser-generated-start-tag", "fragment-root", "parser-document"].contains(node.kind) {
                #expect(node.startTokens.isEmpty)
            }
            for token in node.endTokens { #expect(tokens[token]?.name == node.name) }
            if let path = node.finalPath, ["#text", "#data"].contains(node.name) {
                var semantic = trace.semantic
                for index in path { semantic = try #require(semantic.children?[index]) }
                #expect(String(decoding: node.pieces.flatMap(\.bytes), as: UTF8.self) == semantic.value)
            }
        }
    }

    @Test func collectorDoesNotRetainNodesOrReuseRecycledAddresses() throws {
        let recorder = SourceEventRecorder(bytes: [], emissions: [])
        weak var released: Node?
        for index in 1 ... 10_000 {
            let node = TextNode("x", "")
            released = node
            #expect(recorder.id(node) == index)
            #expect(recorder.id(node) == index)
        }
        #expect(released == nil)
        #expect(recorder.result([]).nodes.count == 10_000)
    }

    @Test func scopesAreIndependentAndCopiesReceiveNewIdentity() throws {
        let first = SourceEventRecorder(bytes: [], emissions: [])
        let second = SourceEventRecorder(bytes: [], emissions: [])
        let original = TextNode("text", "")
        #expect(first.id(original) == 1)
        let identity = original.htmlSourceIdentity
        #expect(second.id(original) == 1)
        #expect(original.htmlSourceIdentity != identity)
        #expect(first.id(original) == 2)
        let copied = try #require(original.copy() as? Node)
        #expect(copied.htmlSourceIdentity?.scope == first.scope)
        #expect(copied.htmlSourceIdentity != original.htmlSourceIdentity)
        let copiedRecord = try #require(first.result([]).nodes.first { $0.id == copied.htmlSourceIdentity?.ordinal })
        #expect(copiedRecord.startTokens.isEmpty && copiedRecord.derivedFrom == [2])
        let reused = TextNode("previous", "")
        _ = second.id(reused)
        _ = original.copy(clone: reused, parent: nil)
        #expect(reused.htmlSourceIdentity?.scope == first.scope)
        #expect(reused.htmlSourceIdentity != original.htmlSourceIdentity)
        #expect(second.result([]).events.contains { $0.kind == "identity-end" && $0.note == "copy-target-reset" })
    }

    @Test func snapshotAndNodeIdentityDoNotExtendParserLifetime() throws {
        weak var root: Node?
        var snapshot: HTMLSourceSnapshot?
        var owned: Node?
        do {
            let parsed = try HTMLSourceParser.parseFragment(emission("<p>x</p>"), tracking: true)
            snapshot = parsed.trace
            root = parsed.roots.first
            owned = root
        }
        let node = try #require(owned)
        #expect(node.htmlSourceIdentity?.scope == snapshot?.scope)
        #expect(node.sourceEventRecorder == nil)
        // The collector has finished; copying neither inherits its expired scope nor invents a new source.
        let copied = try #require(node.copy() as? Node)
        #expect(copied.htmlSourceIdentity == nil)
        owned = nil
        #expect(root != nil) // The local node retains normal DOM ownership.
        #expect(snapshot?.nodes.isEmpty == false)
    }

    @Test func snapshotAloneCannotKeepDiscardedDOMAlive() throws {
        weak var root: Node?
        var snapshot: HTMLSourceSnapshot?
        do {
            let parsed = try HTMLSourceParser.parseFragment(emission("<p>x</p>"), tracking: true)
            root = parsed.roots.first
            snapshot = parsed.trace
        }
        #expect(root == nil)
        #expect(snapshot?.nodes.isEmpty == false)
    }

    @Test func generatedTextScheduleDoesNotDependOnTracking() throws {
        let parts = [
            SourceInputEmission(id: "tag", kind: "raw", role: "hast-generated-tag", value: "<p>", rawUTF8Start: 0, rawUTF8End: 3),
            SourceInputEmission(id: "generated", kind: "characters", role: "hast-generated-text", value: "G&", rawUTF8Start: 3, rawUTF8End: 3),
            SourceInputEmission(id: "author", kind: "raw", role: "author-raw", value: "A&amp;B</p>", rawUTF8Start: 3, rawUTF8End: 14),
        ]
        let off = try HTMLSourceParser.parseFragment(parts)
        let on = try HTMLSourceParser.parseFragment(parts, tracking: true)
        #expect(try encoded(SourceEventRecorder(bytes: [], emissions: []).result(off.roots).semantic) == encoded(on.trace?.semantic))
    }

    @Test func authorAttributesCannotSelectInternalIdentity() throws {
        let result = try HTMLSourceParser.parseFragment(emission("<p data-source-event-id=\"1\" data-generated=\"true\">x</p>"), tracking: true)
        let trace = try #require(result.trace)
        let node = try #require(result.roots.first)
        let record = try #require(trace.nodes.first { $0.id == node.htmlSourceIdentity?.ordinal })
        #expect(record.kind == "token-created")
        #expect(record.startTokens.count == 1)
        #expect(node.htmlSourceIdentity?.ordinal != 1)
        #expect(throws: (any Error).self) {
            try HTMLSourceParser.parseFragment([SourceInputEmission(id: "raw", kind: "raw", role: "hast-generated-text", value: "x", rawUTF8Start: 0, rawUTF8End: 1)], tracking: true)
        }
    }

    @Test func invalidBoundariesAndDirectoriesAreRejected() throws {
        let recorder = SourceEventRecorder(bytes: Array("中😀".utf8), emissions: [])
        #expect(recorder.checked([0, 3]) == [0, 3])
        #expect(recorder.checked([3, 7]) == [3, 7])
        #expect(recorder.checked([1, 3]) == nil)
        #expect(recorder.checked([0, 4]) == nil)
        #expect(recorder.checked([-1, 3]) == nil)
        #expect(throws: (any Error).self) {
            try HTMLSourceParser.parseFragment([SourceInputEmission(id: "bad", kind: "raw", role: "author-raw", value: "中", rawUTF8Start: 0, rawUTF8End: 1)], tracking: true)
        }
        #expect(throws: (any Error).self) {
            try HTMLSourceParser.parseFragment([
                SourceInputEmission(id: "a", kind: "raw", role: "author-raw", value: "<p>A", rawUTF8Start: 0, rawUTF8End: 4),
                SourceInputEmission(id: "b", kind: "characters", role: "hast-generated-text", value: "x", rawUTF8Start: 4, rawUTF8End: 4),
                SourceInputEmission(id: "c", kind: "raw", role: "author-raw", value: "B</p>", rawUTF8Start: 4, rawUTF8End: 9),
            ], tracking: true)
        }
    }
}
