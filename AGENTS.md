# Contributor Guidelines

See [AIMarkdown/README.md](AIMarkdown/README.md) for this fork's purpose, package layout, and maintenance boundaries.

## Repository constraints

- Preserve upstream licenses, copyright notices, and meaningful source data.
- Maintain custom HTML parser behavior directly in `Sources/AIMarkdownHTML/` on the `ai-markdown` branch. This fork owns both implementation and Swift Package distribution; do not introduce a second manually maintained source snapshot.
- Preserve opt-in source tracking, original source ranges, metadata ownership, node lifetimes, and existing default behavior. Keep maintenance changes separate from upstream upgrades.
- Preserve `AIMarkdownHTML` module isolation and distinct development/test target names, and validate coexistence with official SwiftSoup after relevant changes.
- Keep both upstream and AI Markdown regression suites, including their multilingual fixtures. Ordinary builds must not require the workspace or external generators.
- Record third-party implementation provenance in `AIMarkdown/provenance.json` and preserve the upstream MIT license. Follow the retained [upstream benchmark protocol](AIMarkdown/BENCHMARKS.md) for performance work; adapt historical product names to the current SwiftPM targets.
- Run checks appropriate to each change. Keep full logs and one-time migration archives outside the source tree, and do not present historical results or skipped benchmarks as new validation.

## Commit messages

- Follow [Conventional Commits 1.0.0](https://www.conventionalcommits.org/en/v1.0.0/) using `<type>[optional scope][!]: <description>`.
- Use `feat` for new functionality, `fix` for bug fixes, and other types such as `docs`, `test`, or `refactor` as appropriate.
- Describe what the commit changes. Add a body when needed to explain the behavior or reasoning, separated from the subject by a blank line.
- Mark breaking changes with `!` after the type or scope, or with a `BREAKING CHANGE: <description>` footer.
