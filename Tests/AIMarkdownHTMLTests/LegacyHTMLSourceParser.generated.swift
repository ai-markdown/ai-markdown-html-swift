// Historical source entry point from commit 801aa0cd6fbd145bd4743afa4377cf760edd020c, with renamed types, added imports, and translated comments and diagnostics only.
import Foundation
@testable import AIMarkdownHTML
enum LegacyHTMLSourceParser {
    public static func parseFragment(_ emissions: [SourceInputEmission], tracking: Bool = false) throws -> HTMLSourceParseResult {
        try parse(emissions, tracking: tracking)
    }

    // document/fast/copy are module-test helpers and do not expand the production fragment entry point.
    static func parse(_ emissions: [SourceInputEmission], tracking: Bool = false, document: Bool = false, trackRanges: Bool = true, copyControl: Bool = false) throws -> HTMLSourceParseResult {
        var offset = 0
        var ids = Set<String>()
        for emission in emissions {
            let validRole = emission.kind == "raw" ? ["author-raw", "hast-generated-tag", "serialized-generated-text"].contains(emission.role) : emission.role == "hast-generated-text"
            guard validRole, ids.insert(emission.id).inserted, ["raw", "characters"].contains(emission.kind), emission.rawUTF8Start == offset else {
                throw Exception.Error(type: .IllegalArgumentException, Message: "Invalid input emission records")
            }
            if emission.kind == "raw" { offset += emission.value.utf8.count }
            guard emission.rawUTF8End == offset else { throw Exception.Error(type: .IllegalArgumentException, Message: "Invalid input emission length") }
        }
        let raw = emissions.filter { $0.kind == "raw" }.map(\.value).joined()
        let recorder = tracking ? SourceEventRecorder(bytes: Array(raw.utf8), emissions: emissions) : nil
        let builder = HtmlTreeBuilder()
        builder.sourceEvents = recorder
        defer { builder.sourceEvents = nil }
        builder.sourceEventInjections = emissions.filter { $0.kind == "characters" }
        builder.coalescesSourceCharacters = !builder.sourceEventInjections.isEmpty
        let settings = ParseSettings(false, false, trackRanges)
        let roots: [Node]
        if document {
            let document = try builder.parse(Array(raw.utf8), [], ParseErrorList.noTracking(), settings)
            roots = document.getChildNodes()
        } else {
            let context = try Element(Tag.valueOf("body"), "")
            roots = try builder.parseFragment(Array(raw.utf8), context, [], ParseErrorList.noTracking(), settings)
        }
        if !builder.sourceEventInjections.isEmpty { throw Exception.Error(type: .IllegalArgumentException, Message: "Uncovered character injection boundary") }
        recorder?.activeToken = nil
        // Return independent fragment roots by explicitly detaching the temporary container, keeping events consistent with returned parent relationships.
        for root in roots { try root.remove() }
        if copyControl, let first = roots.first { _ = first.copy() }
        return HTMLSourceParseResult(roots: roots, trace: recorder?.result(roots))
    }
}
