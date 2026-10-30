# Foreign-content parsing

The HTML parser implements SVG and MathML tree construction against the Web baseline `e9ec1799fdc380d99ce0a6313023515895bbd7bf`: parse5 7.3.0 and `@ai-markdown/hast-util-raw` 9.1.3. This is a parser change on the existing SwiftSoup 2.14.3 fork, not an upstream upgrade or a new renderer. The ordinary semantic model and public source-event structures retain their existing shapes.

## Construction and tokenizer behavior

Elements carry an internal HTML/SVG/MathML namespace. The adjusted current element determines whether tokens follow HTML insertion modes or foreign rules. SVG `foreignObject`, `desc` and `title`, MathML text integration points, and `annotation-xml` with HTML/XHTML encoding enter HTML processing where required; `mglyph`/`malignmark` and SVG inside MathML `annotation-xml` retain their special rules. Scope checks and formatting clones preserve namespace distinctions.

Foreign starts adjust every fixed SVG tag and attribute spelling, MathML `definitionURL`, and XML/XLink namespace metadata. Raw attribute names fold ASCII only; non-ASCII names and all values stay intact. Synthetic hast attribute keys retain their supplied spelling. Namespace metadata uses a compact discriminator instead of two optional String slots on every ordinary HTML attribute. Public attribute keys remain qualified (`xlink:href`, `xml:lang`, `xmlns:xlink`); internal prefix/namespace metadata survives DOM copying. Foreign self-closing elements stay off the open-element stack, without HTML void-element or form-control traits. HTML breakout tags, conditional `font`, and `</p>`/`</br>` pop foreign nodes and reprocess the original token through the current HTML insertion mode.

CDATA is recognized only in a foreign tokenizer context (XML parsing retains its existing behavior). HTML and integration-point CDATA declarations become bogus comments, ending at the first `>`. Foreign CDATA handles NUL replacement and pending `]`/`]]` across consecutive raw emissions. Generated hast tokens continue through the real tree-builder namespace dispatch. Raw NUL tokens in foreign content become U+FFFD, while a generated CHARACTER token keeps its actual bytes. Replacement pieces retain the original NUL-byte range but do not claim a reversible character mapping. SVG adjusted end names still associate with the real lowercase tokenizer end token and its source range.

Two previously exposed generic tokenizer edges are covered by the same oracle. A tag name continuing in another raw node must derive its cached tag ID from the entire pending name rather than its latest suffix. A partial CDATA declaration lookahead at a raw boundary follows the actual hast-util-raw preprocessor reset: the partial prefix is not restored into the next raw node. No fixture is reconstructed from Swift output.

## Explicit HTML5 recovery mode

`HTMLSourceParser` and `Parser.parseTemplateFragment` ignore a self-closing slash on a non-void HTML element, as parse5 does. This matters when foreign breakout has returned to HTML: `<svg><font color=x>text</font><g/>tail</svg>` puts `tail` inside the HTML `g`. The ordinary `parseBodyFragment` API keeps its established unknown-tag self-closing behavior, and XML parsing keeps XML self-closing behavior. A regression test asserts all three contracts. The mode is an explicit parser setting, never inferred from the presence of SVG text.

## Evidence

`Tests/AIMarkdownHTMLTests/Fixtures/foreign-content.json` preserves 348 complete template-fragment and HTML5 body trees, with namespace and qualified attribute metadata, plus 196 complete actual hast-util-raw inputs/outputs and captured parser trees. The generated/raw sequences cover every character boundary of representative foreign sources and mixed raw/generated start, end and character tokens, including CDATA interrupted by generated nodes. Every captured hast output is compared with a second run without the passive observer. Fragment and generated/raw results are checked with source tracking on and off; both source-parser fragment contexts are exercised.

`scripts/foreign-content-oracle/upstream/` holds immutable source/license evidence, not runtime build inputs or a second implementation source. [foreign-content-provenance.json](foreign-content-provenance.json) pins all reference-file and fixture digests. Reproduce the evidence using the fixed local Web checkout:

```sh
node scripts/foreign-content-oracle/export.mjs /path/to/web > /tmp/foreign-content.json
python3 scripts/foreign-content-oracle/verify.py --web /path/to/web
swift test --filter HTMLForeignContentTests
```

The existing 2,216-case template-context oracle now has no enumerated differences. Its expected trees/digests are unchanged. The original source-event oracle's `foreign` case now matches its unchanged Web tree and leaves the explicit difference list. Token records retain lowercase source names; tests require the precise SVG adjustment when a DOM name differs, rather than overwriting token evidence.

The new tests also check explicit closing ranges, NUL replacement pieces, cloning, no-tracing identities and weak DOM release while a value snapshot remains alive. These tests do not establish full browser conformance, renderer equivalence, UI interaction acceptance, or a performance result. The five main-package KaTeX final-tree differences are independent of foreign-content parsing and remain outside this fork change.

## Local validation (2026-10-30)

The initial feature commit `20f7b94` passed `swift test` and `swift test -c release`: each ran 1,562 upstream XCTest cases with 18 existing skips and zero failures, plus 32 Swift Testing tests with zero failures. The initial six foreign-content tests also passed with AddressSanitizer (`swift test --scratch-path .build/foreign-asan --sanitize address --filter HTMLForeignContentTests`). The immutable oracle verifier passed both offline and with a fresh byte-identical Web re-export. `scripts/verify-source.py` verifies all 64 runtime Swift files and the unchanged package/license. Full logs are kept in local build output, outside the source manifest.

These are macOS parser tests. Main-package compatibility, source-position/admission matrices and the iPhone 18 Pro integration tests must be rerun by the parent repository after pinning this fork commit. No speedup or formal performance acceptance is claimed by this parser feature.

## Unicode foreign end tags

The pinned parse5 foreign end-tag loop lowercases the DOM tag name using JavaScript `String.toLowerCase` and compares it with the unchanged tokenizer name. This is deliberately single-sided: `<svg><xÉ>one</xÉ><g>two</g></svg>` leaves `g` inside `xÉ`, while `</xé>` closes it. Greek final sigma and dotted I can also change whether a close is explicit. The foreign matcher uses scalar lowercase mappings plus the JavaScript Final_Sigma context rule, and source-event explicit-close association uses that same matcher without rewriting lexical tokens.

Twenty additional complete oracle inputs cover both SVG and MathML, uppercase/lowercase counterparts, Σ/σ/ς, following cased characters, combining accents and İ/i with combining dot. A seventh regression test checks the actual explicit end-token count and original UTF-8 closing ranges. The original 328 fragment inputs and 196 generated/raw sequences remain present. Focused regression commands are `swift test --filter 'HTMLForeignContentTests|HTMLSourceEventsTests|HTMLTemplateContextTests|HtmlParserTest'` and the same command with `-c release`; exact final-pin Git-URL consumer validation runs through `scripts/verify-consumer.py`.
