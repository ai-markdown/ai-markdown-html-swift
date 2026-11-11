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

    private func stackExitEvents(_ html: String, context: String, wholeStack: Bool) throws -> Data {
        let recorder = SourceEventRecorder(bytes: Array(html.utf8), emissions: [])
        let builder = HtmlTreeBuilder()
        builder.sourceEvents = recorder
        builder.comparesWholeStackForExits = wholeStack
        defer { builder.sourceEvents = nil }
        let roots = try builder.parseFragment(Array(html.utf8), try Element(Tag.valueOf(context), ""), [], ParseErrorList.noTracking(), ParseSettings(false, false, true))
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let snapshot = recorder.result(roots)
        return try encoder.encode([encoder.encode(snapshot.events), encoder.encode(snapshot.nodes)])
    }

    /// Stack exits are recorded from the mutation sites instead of a whole-stack snapshot per token (which copied the
    /// stack on every push and made deep nesting quadratic); the events must match the snapshot comparison.
    static let stackExitCorpus: [String] = [
        "<b><i></b></i>x", "<a><p><a>x</a></p></a>", "<p><b><i><u>x</p>y", "<table><tr><td>a<b>b</td></tr>c</table>d",
        "<table>foo<tr><td>x</table>", "<b>1<p>2</b>3</p>", "<a href=x>1<div>2<a>3</a></div>4</a>",
        "<select><option>a<option>b</select>", "<template><td>x</td></template>", "<svg><g><foreignObject><p>x</svg>y",
        "<ul><li>a<li>b<ul><li>c</ul></ul>", "<dl><dt>a<dd>b<dt>c</dl>", "<h1>a<h2>b</h1>c", "<form><form>x</form>",
        "<nobr>a<nobr>b</nobr>", "<table><caption>x<table></caption></table>", "<button><button>x", "<li><p>x<li>y",
        "<table><tbody><tr><th>x<td>y</tbody><tfoot><tr><td>z</table>", "<marquee><p>x</marquee>y", "<rb>x<rt>y<rp>z",
        "<p>a\n\nb<pre>\nx</pre><textarea>\ny</textarea>",
        "<div>" + String(repeating: "<span>", count: 40) + "x" + String(repeating: "</span>", count: 20) + "</div>",
        String(repeating: "<b><i>", count: 15) + "x" + String(repeating: "</b>", count: 15),
    ]

    @Test(arguments: stackExitCorpus)
    func incrementalStackExitsMatchWholeStackComparison(_ html: String) throws {
        for context in ["body", "template", "table", "select"] {
            #expect(try stackExitEvents(html, context: context, wholeStack: false) == stackExitEvents(html, context: context, wholeStack: true), "\(context)")
        }
    }
}
