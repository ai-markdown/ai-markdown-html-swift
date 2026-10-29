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

## Maintenance

Maintain custom changes on `ai-markdown`. Evaluate upstream upgrades separately from maintenance work, reviewing semantic differences, source tracking, lifecycle behavior, and coexistence with official SwiftSoup. Do not remove assertions or treat skipped benchmark cases as performance acceptance.

Run `swift test` and `swift test -c release` for the upstream and custom test suites. Preserve meaningful multilingual test data when editing documentation or comments. Keep full logs and one-time migration records in local build output or CI artifacts rather than the source tree.

## Reproducible checks

`python3 scripts/verify-source.py` checks the current runtime file set, Package manifest, and license against `scripts/source-manifest.json`. After reviewing and testing an intentional change, use `--record-current` to update the hashes; updating hashes does not itself prove compatibility.

`python3 scripts/verify-consumer.py` installs this fork and the pinned official SwiftSoup revision through distinct local Git URLs, then builds and runs a coexistence probe. It checks seven complete output trees (six equal and one separately asserted existing foster-placement difference), the public source-event API, and linked module symbols. This local probe does not establish remote release availability.
