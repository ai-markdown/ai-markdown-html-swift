import Foundation
import Testing
@testable import AIMarkdownHTML

struct SourceCharacterCoalescingTests {
    private func parts(_ values: [(String, String)]) -> [SourceInputEmission] {
        var offset = 0
        return values.enumerated().map { index, part in
            let start = offset
            if part.0 == "raw" { offset += part.1.utf8.count }
            return SourceInputEmission(id: "part-\(index)", kind: part.0, role: part.0 == "raw" ? "author-raw" : "hast-generated-text", value: part.1, rawUTF8Start: start, rawUTF8End: offset)
        }
    }

    @Test func repeatedRawAndGeneratedTextKeepEveryPieceAndClearLegacyRange() throws {
        let input = parts([
            ("raw", "<p>same"), ("characters", ""), ("characters", "same"),
            ("raw", "</p><p>"), ("characters", "same"), ("raw", "same</p>"),
        ])
        let on = try HTMLSourceParser.parseFragment(input, tracking: true)
        let off = try HTMLSourceParser.parseFragment(input)
        let trace = try #require(on.trace)
        let texts = try on.roots.map { try #require($0.getChildNodes().only as? TextNode) }
        #expect(texts.map { $0.getWholeText() } == ["samesame", "samesame"])
        #expect(try on.roots.map { try $0.outerHtml() } == ["<p>samesame</p>", "<p>samesame</p>"])
        #expect(try off.roots.map { try $0.outerHtml() } == on.roots.map { try $0.outerHtml() })
        let records = try texts.map { text in try #require(trace.nodes.first { $0.id == text.htmlSourceIdentity?.ordinal }) }
        #expect(records[0].id != records[1].id)
        #expect(records[0].pieces.flatMap(\.emissions) == ["part-0", "part-1", "part-2"])
        #expect(records[1].pieces.flatMap(\.emissions) == ["part-4", "part-5"])
        #expect(records[0].pieces.map(\.bytes) == [Array("same".utf8), [], Array("same".utf8)])
        for (text, record) in zip(texts, records) {
            #expect(text.sourceRange == nil && !text.sourceRangeIsComplete)
            #expect(record.legacyRange == nil)
            #expect(record.gaps.contains("merged-character-node-has-no-single-raw-range"))
        }
        #expect(trace.events.filter { $0.kind == "text-merge" }.count == 3)
        #expect(trace.events.filter { $0.kind == "legacy-range-clear" }.count == 3)
    }

    @Test func commentAndElementAreRealBoundaries() throws {
        let input = parts([
            ("raw", "<p>"), ("characters", "same"), ("raw", "<!--c-->"),
            ("characters", "same"), ("raw", "<b></b>"), ("characters", "same"), ("raw", "</p>"),
        ])
        let parsed = try HTMLSourceParser.parseFragment(input, tracking: true)
        let children = try #require(parsed.roots.first).getChildNodes()
        #expect(children.map { $0.nodeName() } == ["#text", "#comment", "#text", "b", "#text"])
        #expect(parsed.trace?.events.contains { $0.kind == "text-merge" } == false)
    }

    @Test func scriptDataUsesSameActualMergeAndKeepsEmptyEmission() throws {
        let input = parts([("raw", "<script>"), ("characters", "A&"), ("characters", ""), ("raw", "B</script>")])
        let parsed = try HTMLSourceParser.parseFragment(input, tracking: true)
        let child = try #require(parsed.roots.first?.getChildNodes().only as? DataNode)
        #expect(child.getWholeData() == "A&B")
        #expect(child.sourceRange == nil)
        let trace = try #require(parsed.trace)
        let record = try #require(trace.nodes.first { $0.id == child.htmlSourceIdentity?.ordinal })
        #expect(record.pieces.flatMap(\.emissions) == ["part-1", "part-2", "part-3"])
        #expect(record.pieces.flatMap(\.bytes) == Array("A&B".utf8))
    }

    @Test func deepSnapshotsAndPathsWorkOnOrdinaryBackgroundExecutor() async throws {
        let checked = try await Task.detached {
            precondition(!Thread.isMainThread)
            var count = 0
            for depth in [256, 257] {
                for injecting in [false, true] {
                    let open = String(repeating: "<div>", count: depth)
                    let close = String(repeating: "</div>", count: depth)
                    let emissions: [SourceInputEmission]
                    if injecting {
                        emissions = [
                            .init(id: "open", kind: "raw", role: "author-raw", value: open, rawUTF8Start: 0, rawUTF8End: open.utf8.count),
                            .init(id: "text", kind: "characters", role: "hast-generated-text", value: "deep", rawUTF8Start: open.utf8.count, rawUTF8End: open.utf8.count),
                            .init(id: "close", kind: "raw", role: "author-raw", value: close, rawUTF8Start: open.utf8.count, rawUTF8End: open.utf8.count + close.utf8.count),
                        ]
                    } else {
                        let raw = open + "deep" + close
                        emissions = [.init(id: "raw", kind: "raw", role: "author-raw", value: raw, rawUTF8Start: 0, rawUTF8End: raw.utf8.count)]
                    }
                    let parsed = try HTMLSourceParser.parseFragment(emissions, tracking: true)
                    let trace = try #require(parsed.trace)
                    var values = [(trace.semantic, 0)]
                    var elements = 0
                    while let (value, level) = values.popLast() {
                        if value.type == "element" { elements += 1 }
                        if value.type == "text" { #expect(value.value == "deep" && level == depth + 1) }
                        values.append(contentsOf: (value.children ?? []).map { ($0, level + 1) })
                    }
                    #expect(elements == depth)
                    #expect(trace.nodes.filter { $0.finalPath != nil }.count == depth + 1)
                    #expect(trace.nodes.first { $0.name == "#text" }?.finalPath?.count == depth + 1)
                    count += 1
                }
            }
            return count
        }.value
        #expect(checked == 4)
    }

    @Test func emptyOnlyCharacterRemainsActualTextAndRawModeStaysUnchanged() throws {
        let empty = try HTMLSourceParser.parseFragment(parts([("raw", "<code>"), ("characters", ""), ("raw", "</code>")]), tracking: true)
        let text = try #require(empty.roots.first?.getChildNodes().only as? TextNode)
        #expect(text.getWholeText().isEmpty)
        #expect(empty.trace?.nodes.contains { $0.pieces.contains { $0.kind == "hast-generated-text" && $0.bytes.isEmpty } } == true)
        let raw = "<p>A</ignored>B</p>"
        let parsed = try HTMLSourceParser.parseFragment(parts([("raw", raw)]), tracking: true)
        let original = try AIMarkdownHTML.parseBodyFragment(raw)
        #expect(parsed.roots.first?.getChildNodes().count == 2)
        #expect(try parsed.roots.first?.outerHtml() == original.body()?.getChildNodes().first?.outerHtml())
        #expect(parsed.trace?.events.contains { $0.kind == "legacy-range-clear" } == false)
    }
}

private extension Array {
    var only: Element? { count == 1 ? first : nil }
}
