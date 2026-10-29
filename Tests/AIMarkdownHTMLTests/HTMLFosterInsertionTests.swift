import Foundation
import Testing
@testable import AIMarkdownHTML

struct HTMLFosterInsertionTests {
    private struct Oracle: Decodable { let cases: [Item] }
    private struct Item: Decodable { let id: String; let segments: [SourceInputEmission]; let semantic: SourceDOMNode }
    private func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(value)
    }

    @MainActor @Test func actualRawAndInjectedDestinationsMatchCompleteWebTrees() throws {
        let url = try #require(Bundle.module.url(forResource: "html-foster", withExtension: "json", subdirectory: "Fixtures"))
        let cases = try JSONDecoder().decode(Oracle.self, from: Data(contentsOf: url)).cases
        #expect(cases.count == 20)
        for item in cases {
            let on = try HTMLSourceParser.parseFragment(item.segments, tracking: true)
            let off = try HTMLSourceParser.parseFragment(item.segments)
            let trace = try #require(on.trace)
            #expect(try encode(trace.semantic) == encode(SourceEventRecorder(bytes: [], emissions: []).result(off.roots).semantic), "\(item.id)")
            #expect(try encode(trace.semantic) == encode(item.semantic), "\(item.id)")
            #expect(!trace.gaps.contains("foster-text-bypasses-insertNode"), "\(item.id)")
            for event in trace.events where event.kind == "foster-text" {
                let record = try #require(trace.nodes.first { $0.id == event.node })
                #expect(!record.pieces.isEmpty)
                #expect(event.token != nil)
                #expect(event.parent != nil)
                if event.note == "merge-at-destination" { #expect(record.legacyRange == nil) }
            }
        }
    }


    @Test func actualBeforeTableCommentBoundaryAndDiscontinuousPiecesArePreserved() throws {
        let raw = "L<!--outside--><table>x<tr><td>A</td></tr>y</table>"
        let input = [SourceInputEmission(id: "raw", kind: "raw", role: "author-raw", value: raw, rawUTF8Start: 0, rawUTF8End: raw.utf8.count)]
        let parsed = try HTMLSourceParser.parseFragment(input, tracking: true)
        #expect(parsed.roots.map { $0.nodeName() } == ["#text", "#comment", "#text", "table"])
        let text = try #require(parsed.roots[2] as? TextNode)
        #expect(text.getWholeText() == "xy")
        #expect(text.sourceRange == nil && !text.sourceRangeIsComplete)
        let trace = try #require(parsed.trace)
        let record = try #require(trace.nodes.first { $0.id == text.htmlSourceIdentity?.ordinal })
        #expect(record.pieces.map { String(decoding: $0.bytes, as: UTF8.self) } == ["x", "y"])
        #expect(record.pieces.compactMap(\.range).count == 2)
        #expect(record.pieces[0].range?.last != record.pieces[1].range?.first)
        #expect(trace.events.filter { $0.kind == "foster-text" }.count == 2)
        let table = try #require(parsed.roots.last)
        #expect(table.sourceRange == nil && !table.sourceRangeIsComplete)
        #expect(trace.nodes.first { $0.id == table.htmlSourceIdentity?.ordinal }?.legacyRange == nil)
    }
}
