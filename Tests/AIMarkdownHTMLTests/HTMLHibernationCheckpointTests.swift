import Foundation
import Testing
@testable import AIMarkdownHTML

struct HTMLHibernationCheckpointTests {
    private struct Fixture: Decodable { let cases: [Row] }
    private struct Row: Decodable {
        struct Checkpoint: Decodable { let emissionID: String; let end: Int; let state: Int; let pendingCharacter: Bool }
        struct WebError: Decodable { let name: String; let message: String }
        let id: String
        let segments: [SourceInputEmission]
        let semantic: SourceDOMNode?
        let webError: WebError?
        let checkpoints: [Checkpoint]
        let passiveObserversVerified: Bool
    }
    private func encoded(_ node: SourceDOMNode) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(node)
    }
    private func canonical(_ node: SourceDOMNode) -> SourceDOMNode {
        var children: [SourceDOMNode] = []
        for child in node.children ?? [] {
            let next = canonical(child)
            if next.type == "text", let previous = children.last, previous.type == "text" {
                children[children.count - 1] = SourceDOMNode(type: "text", name: nil, value: (previous.value ?? "") + (next.value ?? ""), attributes: nil, children: nil)
            } else { children.append(next) }
        }
        return SourceDOMNode(type: node.type, name: node.name, value: node.value, attributes: node.attributes,
                             children: node.children == nil ? nil : children)
    }

    @MainActor @Test func actualConsumedCheckpointsAndCompleteTreesMatchTheFixedWebMatrix() throws {
        let url = try #require(Bundle.module.url(forResource: "hibernation-checkpoints", withExtension: "json", subdirectory: "Fixtures"))
        let rows = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: url)).cases
        #expect(rows.count == 347)
        var webTrees = 0, webErrors = 0, points = 0
        for row in rows {
            let on = try HTMLSourceParser.parseFragment(row.segments, tracking: true, context: .template)
            let off = try HTMLSourceParser.parseFragment(row.segments, tracking: false, context: .template)
            let trace = try #require(on.trace)
            let offTree = SourceEventRecorder(bytes: [], emissions: []).result(off.roots).semantic
            #expect(try encoded(canonical(trace.semantic)) == encoded(canonical(offTree)), "\(row.id): tracking must not change parsing")
            #expect(row.passiveObserversVerified)
            if let expected = row.semantic {
                let actualBytes = try encoded(canonical(trace.semantic)), expectedBytes = try encoded(canonical(expected))
                if actualBytes != expectedBytes {
                    print("checkpoint tree \(row.id): native=\(String(decoding: actualBytes, as: UTF8.self)) web=\(String(decoding: expectedBytes, as: UTF8.self))")
                }
                #expect(actualBytes == expectedBytes, "\(row.id): complete actual Web tree")
                webTrees += 1
            } else {
                let error = try #require(row.webError)
                #expect(error.name == "TypeError" && !error.message.isEmpty, "Retain the actual Web exception; do not call it parity")
                webErrors += 1
            }
            let expected = try row.checkpoints.map { point -> String in
                let segment = try #require(row.segments.first { $0.id == point.emissionID })
                #expect(point.state == 41, "Actual parse5 MARKUP_DECLARATION_OPEN state")
                points += 1
                return "\(segment.rawUTF8End):\(point.end)"
            }
            let actual = trace.events.filter { $0.kind == "raw-hibernation-end" }
            #expect(actual.compactMap(\.note) == expected, "\(row.id): original UTF-8 raw-end/checkpoint, including CRLF and Unicode")
            for (event, expected) in zip(actual, row.checkpoints) {
                if expected.pendingCharacter {
                    let token = try #require(trace.tokens.first { $0.id == event.token })
                    #expect(token.kind == "Char", "Checkpoint belongs to an actual pending character token")
                } else { #expect(event.token == nil, "A checkpoint without pending Web characters must not borrow another token") }
            }
        }
        #expect(webTrees == 315 && webErrors == 32 && points == 225)
    }
}
