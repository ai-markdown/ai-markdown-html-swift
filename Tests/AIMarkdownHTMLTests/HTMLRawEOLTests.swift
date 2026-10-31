import Foundation
import Testing
@testable import AIMarkdownHTML

struct HTMLRawEOLTests {
    private struct Oracle: Decodable { let cases: [Item] }
    private struct Item: Decodable { let id: String; let segments: [SourceInputEmission]; let semantic: SourceDOMNode; let rawSource: String }
    private func encoded<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(value)
    }
    private func canonical(_ value: Any) throws -> Data { try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .fragmentsAllowed]) }
    private func rows() throws -> [Item] {
        let url = try #require(Bundle.module.url(forResource: "html-eol", withExtension: "json", subdirectory: "Fixtures"))
        return try JSONDecoder().decode(Oracle.self, from: Data(contentsOf: url)).cases
    }
    private func validate(_ trace: HTMLSourceSnapshot, roots: [Node], item: Item) throws {
        let bytes = Array(item.rawSource.utf8), validator = SourceEventRecorder(bytes: Array(item.rawSource.utf8), emissions: [])
        let emissions = Dictionary(uniqueKeysWithValues: item.segments.map { ($0.id, $0) })
        func piece(_ piece: SourceEventPiece) throws {
            if let range = piece.range {
                #expect(validator.checked(range) == range)
                let original = Array(bytes[range[0] ..< range[1]])
                if piece.kind == "copy" { #expect(piece.bytes == original) }
                if piece.kind == "normalized-line-ending" {
                    #expect(piece.bytes == [10] && (original == [13] || original == [13, 10]))
                    #expect(piece.emissions.count == 1)
                    let emission = try #require(emissions[piece.emissions[0]])
                    #expect(emission.kind == "raw" && emission.role != "hast-generated-tag")
                    #expect(range[0] >= emission.rawUTF8Start && range[1] <= emission.rawUTF8End)
                }
            }
            if piece.kind == "hast-generated-text" {
                #expect(piece.range == nil && !piece.emissions.isEmpty)
                #expect(piece.emissions.allSatisfy { emissions[$0]?.kind == "characters" })
            }
            #expect(piece.emissions.allSatisfy { emissions[$0] != nil })
        }
        for token in trace.tokens {
            if let range = token.range { #expect(validator.checked(range) == range) }
            try token.pieces.forEach(piece)
        }
        for node in trace.nodes {
            if let range = node.legacyRange { #expect(validator.checked(range) == range) }
            try node.pieces.forEach(piece)
            if let path = node.finalPath, ["#text", "#data"].contains(node.name) {
                var semantic = trace.semantic
                for index in path { semantic = try #require(semantic.children?[index]) }
                #expect(node.pieces.flatMap(\.bytes) == Array((semantic.value ?? "").utf8))
            }
        }
        try trace.inputNormalizations.forEach(piece)
        let expected = item.segments.filter { $0.kind == "raw" && $0.role != "hast-generated-tag" }.reduce(0) { $0 + $1.value.utf8.filter { $0 == 13 }.count }
        #expect(trace.inputNormalizations.count == expected)
        var stack = Array(roots.reversed())
        while let node = stack.popLast() {
            if let range = node.sourceRange {
                #expect(validator.checked([range.start, range.end]) == [range.start, range.end])
                #expect(node.sourceSliceUTF8().map(Array.init) == Array(bytes[range.start ..< range.end]))
            }
            if !trace.inputNormalizations.isEmpty { #expect(node.sourceBuffer?.bytes == bytes) }
            stack.append(contentsOf: node.getChildNodes().reversed())
        }
    }
    /// Every Web-recorded raw/characters/generated-tag sequence parses through the hast-util-raw emission loop (no
    /// character injection is rejected any more) and builds the recorded tree; differences are listed by id.
    @MainActor @Test func completeWebRawEOLMatrixKeepsOriginalSourceAndExplicitAdmissionGaps() throws {
        let cases = try rows()
        var differences: [String] = [], traces: [[String: Any]] = []
        for item in cases {
            // The Web matrix was recorded through hast-util-raw, whose fragment context is <template>.
            let on = try HTMLSourceParser.parseFragment(item.segments, tracking: true, context: .template)
            let trace = try #require(on.trace), off = try HTMLSourceParser.parseFragment(item.segments, context: .template)
            #expect(try encoded(trace.semantic) == encoded(SourceEventRecorder(bytes: [], emissions: []).result(off.roots).semantic))
            try validate(trace, roots: on.roots, item: item)
            if try encoded(trace.semantic) != encoded(item.semantic) {
                differences.append(item.id)
                print("html-eol difference \(item.id)\n  web:   \(String(decoding: try encoded(item.semantic), as: UTF8.self))\n  swift: \(String(decoding: try encoded(trace.semantic), as: UTF8.self))")
            }
            var object = try #require(JSONSerialization.jsonObject(with: encoded(trace)) as? [String: Any])
            object.removeValue(forKey: "scope")
            // This immutable historical diagnostic predates additive hibernation checkpoints. Keep every old
            // token/node/event field exact; the new events have their own full 347-case real-Web matrix.
            if let events = object["events"] as? [[String: Any]] {
                object["events"] = events.filter { $0["kind"] as? String != "raw-hibernation-end" }.enumerated().map { index, event in
                    var legacy = event
                    legacy["sequence"] = index + 1
                    return legacy
                }
            }
            traces.append(["id": item.id, "trace": object])
        }
        #expect(cases.count == 259)
        #expect(differences == Self.expectedDifferences, "\(differences)")
        let diagnostics: [String: Any] = ["cases": cases.count, "differences": differences, "traces": traces]
        if let path = ProcessInfo.processInfo.environment["HTML_EOL_PROBE_OUTPUT"] { try canonical(diagnostics).write(to: URL(fileURLWithPath: path)) }
        else {
            let url = try #require(Bundle.module.url(forResource: "html-eol-native", withExtension: "json", subdirectory: "Fixtures"))
            #expect(try canonical(diagnostics) == canonical(JSONSerialization.jsonObject(with: Data(contentsOf: url))))
        }
    }
    /// Remaining differences from the Web matrix, by id (empty means full parity).
    static let expectedDifferences: [String] = []

    @MainActor @Test func trackingDocumentAndFastModesUseTheSameRawNormalization() throws {
        for item in try rows() {
            for trackRanges in [true, false] {
                if !trackRanges, item.segments.contains(where: { $0.kind == "characters" }) { continue }
                let on = try HTMLSourceParser.parse(item.segments, tracking: true, document: true, trackRanges: trackRanges)
                let off = try HTMLSourceParser.parse(item.segments, document: true, trackRanges: trackRanges)
                let trace = try #require(on.trace)
                #expect(try encoded(trace.semantic) == encoded(SourceEventRecorder(bytes: [], emissions: []).result(off.roots).semantic))
                try validate(trace, roots: on.roots, item: item)
            }
        }
    }
    @Test func originalByteBoundariesStayAuthoritativeAndLegacyStringAPIIsUnchanged() throws {
        let source = "<p>😀éx\r\nx\rx\r\nx&#13;y</p>"
        let input = [SourceInputEmission(id: "raw", kind: "raw", role: "author-raw", value: source, rawUTF8Start: 0, rawUTF8End: source.utf8.count)]
        let result = try HTMLSourceParser.parseFragment(input, tracking: true), trace = try #require(result.trace)
        #expect(trace.inputNormalizations.compactMap(\.range) == [[11, 13], [14, 15], [16, 18]])
        #expect(trace.inputNormalizations.allSatisfy { $0.kind == "normalized-line-ending" && $0.bytes == [10] })
        let original = try AIMarkdownHTML.parseBodyFragment("<p>A\r\nB</p>")
        let p = try #require(original.body()?.getChildNodes().first as? Element)
        #expect((p.getChildNodes().first as? TextNode)?.getWholeText().utf16.elementsEqual("A\r\nB".utf16) == true)
        let invalid = input + [SourceInputEmission(id: "middle", kind: "characters", role: "hast-generated-text", value: "x", rawUTF8Start: 12, rawUTF8End: 12)]
        #expect(throws: (any Error).self) { try HTMLSourceParser.parseFragment(invalid) }
        // Historical snapshots remain decodable; old exporters need not fabricate inputNormalizations fields.
        var json = try #require(JSONSerialization.jsonObject(with: encoded(trace)) as? [String: Any])
        json.removeValue(forKey: "inputNormalizations")
        #expect(try JSONDecoder().decode(HTMLSourceSnapshot.self, from: canonical(json)).inputNormalizations.isEmpty)
    }
}
