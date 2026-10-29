# AI Markdown HTML

This fork maintains and distributes the custom HTML parser used by AI Markdown. It builds on SwiftSoup 2.14.3 at `e7f85f4d3dd91ca9a1e94d3328aa1ed5120a8c0f` and preserves upstream history, copyright notices, and the root MIT `LICENSE`.

## Responsibilities

Maintain HTML parsing, DOM behavior, source-event tracking, node lifetimes, character emission handling, and fostered-text placement directly in `Sources/AIMarkdownHTML/`. The source-event API retains original UTF-8 ranges across input normalization and is explicitly enabled by callers. Existing ordinary parsing behavior and intentional compatibility differences remain covered by tests; source tracking does not imply exact inverse character mappings or complete Web equivalence.

This repository is both the implementation source and the Swift Package distribution repository. It has no separate generated source snapshot or parser submodules. Application document models, Engine/Core coordination, UI, and layout belong to the main AI Markdown library.

`AIMarkdownHTML` is isolated from official `SwiftSoup`. The profile executable and upstream test target also use distinct names so consumers can depend on both packages. The supported entry point is `Package.swift`; retained upstream framework projects and CocoaPods/Carthage metadata are historical reference material, not additional supported distribution products.

## Layout

- `Sources/AIMarkdownHTML/`: library implementation using SwiftPM's default target path.
- `Tests/SwiftSoupTests/`: upstream behavior tests, compiled as `AIMarkdownHTMLUpstreamTests`.
- `Tests/AIMarkdownHTMLTests/`: source-event, ownership, character-coalescing, foster-placement, and line-ending regression tests with their original multilingual fixtures.
- `Tools/SwiftSoupProfile/`: the `AIMarkdownHTMLProfile` development executable.
- `AIMarkdown/provenance.json`: original implementation source paths and digests, referring to the pinned source repository rather than local files.

## Template fragment context (parse5 / hast-util-raw parity)

hast-util-raw 9.1.3 parses with parse5 7.3 `Parser.getFragmentParser(undefined)`, whose context element is a detached `<template>`: tree construction starts in the "in template" insertion mode and the template insertion mode stack decides the mode after the first decisive start tag (`caption`/`colgroup`/`tbody`/`tfoot`/`thead` → in table, `col` → in column group, `tr` → in table body, `td`/`th` → in row, anything else → in body; in-head elements, characters, comments and end tags do not switch). `Parser.parseTemplateFragment` / `parseTemplateFragment(_:_:)` and `HTMLSourceParser.parseFragment(_:tracking:context: .template)` reproduce this; `parseBodyFragment` and caller-supplied contexts keep their behavior.

The tree builder now implements the `<template>` element and template insertion modes as parse5 does (in-head insertion, `</template>` with thorough implied end tags, template-aware scope, table context clearing, foster parenting location, form pointer and `<html>`/`<body>` attribute rules, EOF handling, `_resetInsertionMode` including the select-in-table case). Template children stand in for parse5's template content fragment; consumers that mirror hast must treat them as `content`, not `children`.

`scripts/template-context-oracle/export.mjs` records parse5's trees for `targeted.json` (hand-written table-part-first and template edge cases) and `engine-corpus.json` (serialized HTML exported from the AI Markdown Swift main repository's compatibility, footnote and incremental-boundary fuzz corpora by `scripts/html-template-context-probe/export-corpus.py`) into `Tests/AIMarkdownHTMLTests/Fixtures/template-context.json`; `HTMLTemplateContextTests` replays it offline. Adjacent text nodes are merged before comparison (one node per character token here, one per run in parse5), and CR/CRLF is normalized for the plain string entry (parse5's preprocessor does it; `HTMLSourceParser` normalizes author raw). Remaining differences are enumerated in the test: parse5's `skipNextNewLine` after `<pre>`/`<listing>`/`<textarea>` (tracked by `HTMLRawEOLTests` as `leading-pre-LF`), the jsoup RCDATA early breakout when no matching end tag follows, and U+0000 character data.

Parity fixes that came with the oracle also apply to the body context: `<hr>` and `<plaintext>` close an open `<p>`, `<select>` inside table modes enters "in select in table", and `<frameset>` without a properly nested `<body>` is ignored.

## Maintenance

Maintain custom changes on `ai-markdown`. Evaluate upstream upgrades separately from maintenance work, reviewing semantic differences, source tracking, lifecycle behavior, and coexistence with official SwiftSoup. Do not remove assertions or treat skipped benchmark cases as performance acceptance.

Run `swift test` and `swift test -c release` for the upstream and custom test suites. Preserve meaningful multilingual test data when editing documentation or comments. Keep full logs and one-time migration records in local build output or CI artifacts rather than the source tree.

## Reproducible checks

`python3 scripts/verify-source.py` checks the current runtime file set, Package manifest, and license against `scripts/source-manifest.json`. After reviewing and testing an intentional change, use `--record-current` to update the hashes; updating hashes does not itself prove compatibility.

`python3 scripts/verify-consumer.py` installs this fork and the pinned official SwiftSoup revision through distinct local Git URLs, then builds and runs a coexistence probe. It checks seven complete output trees (six equal and one separately asserted existing foster-placement difference), the public source-event API, and linked module symbols. This local probe does not establish remote release availability.

Use [BENCHMARKS.md](BENCHMARKS.md) for the original upstream performance methodology. Historical executable/product names in that protocol must be adapted to the current SwiftPM targets.
