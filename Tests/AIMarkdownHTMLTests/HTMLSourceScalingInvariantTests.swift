import Foundation
import Testing
@testable import AIMarkdownHTML

/// The indexed emission lookup and the batched root detach must match the linear scan and per-node removal they replace.
struct HTMLSourceScalingInvariantTests {
    private func linearIDs(_ emissions: [SourceInputEmission], _ range: [Int]) -> [String] {
        emissions.filter { $0.kind == "raw" && $0.rawUTF8Start < $0.rawUTF8End && $0.rawUTF8Start < range[1] && $0.rawUTF8End > range[0] }.map(\.id)
    }

    private func checkAllRanges(_ emissions: [SourceInputEmission], bytes: [UInt8]) {
        let recorder = SourceEventRecorder(bytes: bytes, emissions: emissions)
        for start in 0...bytes.count {
            for end in start...bytes.count {
                #expect(recorder.emissionIDs([start, end]) == linearIDs(emissions, [start, end]), "range \(start)..<\(end)")
            }
        }
    }

    @Test func emissionLookupMatchesLinearScan() {
        var emissions: [SourceInputEmission] = []
        var offset = 0
        let parts: [(String, String, String)] = [
            ("raw", "author-raw", "<p>"), ("characters", "hast-generated-text", "x"), ("raw", "author-raw", ""),
            ("raw", "hast-generated-tag", "<a href=\""), ("raw", "serialized-generated-text", "u&amp;v"),
            ("raw", "hast-generated-tag", "\">"), ("raw", "author-raw", "a\r\nb"), ("characters", "hast-generated-text", "y"),
            ("raw", "author-raw", "</p>"),
        ]
        for (index, (kind, role, value)) in parts.enumerated() {
            let length = kind == "raw" ? value.utf8.count : 0
            emissions.append(SourceInputEmission(id: "e\(index)", kind: kind, role: role, value: value, rawUTF8Start: offset, rawUTF8End: offset + length))
            offset += length
        }
        checkAllRanges(emissions, bytes: Array(repeating: 0x61, count: offset))
        // Overlapping or unordered records are only reachable through the public initializer and keep the linear scan.
        let unordered = [
            SourceInputEmission(id: "b", kind: "raw", role: "author-raw", value: "bbbb", rawUTF8Start: 4, rawUTF8End: 8),
            SourceInputEmission(id: "a", kind: "raw", role: "author-raw", value: "aaaaaa", rawUTF8Start: 0, rawUTF8End: 6),
            SourceInputEmission(id: "c", kind: "raw", role: "author-raw", value: "cc", rawUTF8Start: 2, rawUTF8End: 4),
        ]
        checkAllRanges(unordered, bytes: Array(repeating: 0x61, count: 8))
    }

    private struct DetachState: Equatable {
        let events: Data
        let siblingIndexes: [Int]
        let parents: [Bool]
        let remaining: [Int]
        let containerVersion: Int
        let containerDirty: Bool
    }

    private func detachState(_ html: String, select: ([Node]) -> [Node], batched: Bool) throws -> DetachState {
        let recorder = SourceEventRecorder(bytes: Array(html.utf8), emissions: [])
        let builder = HtmlTreeBuilder()
        builder.sourceEvents = recorder
        defer { builder.sourceEvents = nil }
        let context = try Element(Tag.valueOf("body"), "")
        let roots = try builder.parseFragment(Array(html.utf8), context, [], ParseErrorList.noTracking(), ParseSettings(false, false, true))
        let container = try #require(roots.first?.parentNode)
        let nodes = select(roots)
        if batched { try Node.detachInOrder(nodes) } else { for node in nodes { try node.remove() } }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let snapshot = recorder.result(roots)
        return try DetachState(
            events: encoder.encode([encoder.encode(snapshot.events), encoder.encode(snapshot.nodes), encoder.encode(snapshot.semantic)]),
            siblingIndexes: roots.map(\.siblingIndex),
            parents: roots.map { $0.parentNode != nil },
            remaining: container.childNodes.map(\.siblingIndex),
            containerVersion: container.textMutationRoot().textMutationVersion,
            containerDirty: container.sourceRangeDirty
        )
    }

    @Test func batchedDetachMatchesSequentialRemoval() throws {
        let html = "<p>a</p>text<!--c--><div><span>b</span></div><ul><li>x</li></ul>tail"
        let selections: [([Node]) -> [Node]] = [
            { $0 },
            { Array($0.prefix(2)) },
            { Array($0.dropFirst()) },
            { [$0[1], $0[0]] },
            { _ in [] },
        ]
        for select in selections {
            #expect(try detachState(html, select: select, batched: true) == detachState(html, select: select, batched: false))
        }
    }
}
