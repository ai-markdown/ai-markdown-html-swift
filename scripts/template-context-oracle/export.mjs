#!/usr/bin/env node
// Differential oracle for the <template> fragment context: parse every corpus entry with parse5 7.3
// (`parseFragment` without a context element, i.e. `Parser.getFragmentParser(undefined)` as used by
// hast-util-raw 9.1.3) and record the canonical tree the Swift tree builder must reproduce.
//
// Two trees are recorded per entry: `tree`/`digest` from `parseFragment` (the whole string, EOF included; the Swift
// string entry point `parseTemplateFragment` must match it) and `rawTree`/`rawDigest` from the hast-util-raw driving
// sequence for one raw node (`tokenizer.write(html, false)`, flush of the pending character token, `getFragment()`
// without EOF; `HTMLSourceParser.parseFragment` must match it).
//
// Usage: node export.mjs <parse5-package-dir> <corpus.json>... > ../../Tests/AIMarkdownHTMLTests/Fixtures/template-context.json
//
// The corpus files hold `{ "cases": [{ "id": string, "html": string }] }`. The resulting fixture is read by
// `HTMLTemplateContextTests`; it is committed and the test does not need Node.
import {createRequire} from 'node:module';
import {readFileSync} from 'node:fs';
import {createHash} from 'node:crypto';
import {resolve} from 'node:path';

const [parse5Dir, ...corpusFiles] = process.argv.slice(2);
if (!parse5Dir || corpusFiles.length === 0) {
  console.error('usage: export.mjs <parse5-package-dir> <corpus.json>...');
  process.exit(2);
}
const require = createRequire(import.meta.url);
const parse5 = require(resolve(parse5Dir));
const version = require(resolve(parse5Dir, 'package.json')).version;

// hast-util-raw 9.1.3 `lib/index.js` for a root with a single `raw` child: `handleRaw` writes the value as a
// non-final chunk, `resetTokenizer` flushes the pending character token (it always has a location because
// hast-util-raw enables `sourceCodeLocationInfo`), and `raw` takes `getFragment()` without ever writing EOF.
function parseRaw(html) {
  const parser = parse5.Parser.getFragmentParser(undefined, {sourceCodeLocationInfo: true, scriptingEnabled: false});
  const tokenizer = parser.tokenizer;
  tokenizer.write(html, false);
  tokenizer._runParsingLoop();
  const token = tokenizer.currentCharacterToken;
  if (token && token.location) {
    parser.currentToken = token;
    parser._processToken(token);
  }
  tokenizer.paused = false;
  tokenizer.inLoop = false;
  tokenizer.active = false;
  tokenizer.currentCharacterToken = null;
  tokenizer.currentToken = null;
  return parser.getFragment();
}

function canonical(node) {
  switch (node.nodeName) {
    case '#text':
      return {type: 'text', value: node.value};
    case '#comment':
      return {type: 'comment', value: node.data};
    case '#documentType':
      return {type: 'doctype'};
    default: {
      const attributes = {};
      for (const attribute of node.attrs) attributes[attribute.name] = attribute.value;
      // The template content fragment stands in for the element's children on the Swift side.
      const children = node.nodeName === 'template' ? node.content.childNodes : node.childNodes;
      return {type: 'element', name: node.nodeName, namespace: node.namespaceURI, attributes, children: children.map(canonical)};
    }
  }
}

// Compact deterministic serialization shared with HTMLTemplateContextTests (UTF-8 byte lengths, attributes sorted by
// UTF-8 bytes); large corpora store only its SHA-256 so the fixture stays small.
function utf8(value) {
  return Buffer.from(value, 'utf8');
}
function serialize(node) {
  switch (node.type) {
    case 'text':
      return `t${utf8(node.value).length}:${node.value}`;
    case 'comment':
      return `c${utf8(node.value).length}:${node.value}`;
    case 'doctype':
      return 'd';
    default: {
      const names = Object.keys(node.attributes).sort((a, b) => Buffer.compare(utf8(a), utf8(b)));
      const attributes = names.map((name) => `a${utf8(name).length}:${name}=${utf8(node.attributes[name]).length}:${node.attributes[name]}`).join('');
      return `e${node.name}(${attributes})[${node.children.map(serialize).join('')}]`;
    }
  }
}
function depth(nodes) {
  return nodes.reduce((max, node) => Math.max(max, node.type === 'element' ? 1 + depth(node.children) : 1), 0);
}
function digest(tree) {
  return createHash('sha256').update(utf8(tree.map(serialize).join(''))).digest('hex');
}

const cases = [];
const seen = new Set();
for (const file of corpusFiles) {
  const corpus = JSON.parse(readFileSync(file, 'utf8'));
  for (const item of corpus.cases) {
    if (seen.has(item.id)) throw new Error(`duplicate case id ${item.id}`);
    seen.add(item.id);
    const fragment = parse5.parseFragment(item.html, {scriptingEnabled: false});
    const tree = fragment.childNodes.map(canonical);
    const rawTree = parseRaw(item.html).childNodes.map(canonical);
    // Boundary-oracle frames are numerous and some Web-oracle trees nest deeper than Foundation's JSON reader allows;
    // those keep only the digests, the hand-written and remaining Web-oracle cases keep the full trees.
    const compact = item.id.startsWith('boundary/') || depth(tree) > 64 || depth(rawTree) > 64;
    const entry = {id: item.id, html: item.html, digest: digest(tree), rawDigest: digest(rawTree)};
    cases.push(compact ? entry : {...entry, tree, rawTree});
  }
}
const corpusDigest = createHash('sha256').update(JSON.stringify(cases.map((c) => c.html))).digest('hex');
process.stdout.write(
  JSON.stringify({schemaVersion: 2, parse5: version, options: {scriptingEnabled: false, fragmentContext: 'template'}, corpusSHA256: corpusDigest, cases}) + '\n'
);
