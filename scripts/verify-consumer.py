#!/usr/bin/env python3
"""Install this fork and official SwiftSoup through local Git URLs, then build and run a coexistence probe without path dependencies."""
import argparse
import json
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parent.parent
OFFICIAL = 'e7f85f4d3dd91ca9a1e94d3328aa1ed5120a8c0f'
SOURCE = r'''import Foundation
import AIMarkdownHTML
import SwiftSoup

let inputs = ["<p>中🙂 &amp; 文</p>", "<table>a<tr><td>x</td></tr>b</table>", "<b><i>x</b>y</i>", "<!--x--><p>a\r\nb</p>", "<textarea>\nx</textarea>", "<svg><title>x</title></svg>", "<div data-x='a&amp;b'><br>z</div>"]
for input in inputs {
    let fork = try AIMarkdownHTML.parse(input)
    let official = try SwiftSoup.parse(input)
    let actual = try fork.outerHtml()
    let expected = try official.outerHtml()
    let agrees: Bool
    if input == "<table>a<tr><td>x</td></tr>b</table>" {
        // The existing foster-placement fix differs from official output; assert both complete results instead of skipping the difference.
        agrees = actual.utf8.elementsEqual("<html>\n <head></head>\n <body>\n  ab\n  <table>\n   <tbody>\n    <tr>\n     <td>x</td>\n    </tr>\n   </tbody>\n  </table>\n </body>\n</html>".utf8) && expected.utf8.elementsEqual("<html>\n <head></head>\n <body>\n  <table>\n   a\n   <tbody>\n    <tr>\n     <td>x</td>\n    </tr>b\n   </tbody>\n  </table>\n </body>\n</html>".utf8)
    } else {
        agrees = actual.utf8.elementsEqual(expected.utf8)
    }
    if !agrees {
        FileHandle.standardError.write(Data("DIFFERENT INPUT: \(input.debugDescription)\nFORK: \(actual.debugDescription)\nOFFICIAL: \(expected.debugDescription)\n".utf8))
        throw NSError(domain: "FullTreeMismatch", code: 1)
    }
}
let raw = "<p>中\r\n文</p>"
let emission = SourceInputEmission(id: "author", kind: "raw", role: "author-raw", value: raw, rawUTF8Start: 0, rawUTF8End: raw.utf8.count)
let traced = try HTMLSourceParser.parseFragment([emission], tracking: true)
if traced.trace == nil || traced.trace!.inputNormalizations.count != 1 {
    FileHandle.standardError.write(Data("TRACE NORMALIZATIONS: \(String(describing: traced.trace?.inputNormalizations))\n".utf8))
    throw NSError(domain: "TraceMismatch", code: 1)
}
precondition(!traced.roots.isEmpty)
print("PASS: 7 full ordinary HTML trees (6 equal, 1 explicitly checked existing foster difference) and public source-event API; both modules linked")
'''

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--official-checkout', type=Path, default=ROOT, help='Git repository containing the pinned upstream object; defaults to the upstream history retained in this fork')
    parser.add_argument('--revision', default='HEAD', help='Committed revision of this fork to validate')
    parser.add_argument('--configuration', choices=['debug', 'release'], default='release')
    args = parser.parse_args()
    revision = subprocess.check_output(['git', 'rev-parse', args.revision], cwd=ROOT, text=True).strip()
    official = args.official_checkout.resolve()
    subprocess.run(['git', '-C', str(official), 'cat-file', '-e', OFFICIAL + '^{commit}'], check=True)
    with tempfile.TemporaryDirectory(prefix='aimarkdown-html-consumer-') as directory:
        target = Path(directory)
        # Separate bare mirrors give the URLs distinct package identities, keeping input directory names from affecting the test.
        fork_mirror = target / 'ai-markdown-html-swift.git'
        official_mirror = target / 'SwiftSoup.git'
        subprocess.run(['git', 'clone', '--bare', str(ROOT), str(fork_mirror)], check=True)
        subprocess.run(['git', 'clone', '--bare', str(official), str(official_mirror)], check=True)
        consumer = target / 'consumer'; (consumer / 'Sources/Probe').mkdir(parents=True)
        manifest = f'''// swift-tools-version:6.2
import PackageDescription
let package = Package(name: "HTMLCoexistence", platforms: [.macOS(.v26)], dependencies: [
    .package(url: {json.dumps(fork_mirror.as_uri())}, revision: "{revision}"),
    .package(url: {json.dumps(official_mirror.as_uri())}, revision: "{OFFICIAL}")
], targets: [.executableTarget(name: "Probe", dependencies: [
    .product(name: "AIMarkdownHTML", package: "ai-markdown-html-swift"),
    .product(name: "SwiftSoup", package: "SwiftSoup")
])])
'''
        (consumer / 'Package.swift').write_text(manifest)
        (consumer / 'Sources/Probe/main.swift').write_text(SOURCE)
        subprocess.run(['swift', 'run', '-c', args.configuration, 'Probe'], cwd=consumer, check=True)
        binary = consumer / '.build' / args.configuration / 'Probe'
        symbols = subprocess.check_output(['nm', '-g', str(binary)], text=True)
        assert '14AIMarkdownHTML' in symbols or '14AIMarkdownHTML' in subprocess.check_output(['swift', 'demangle'], input=symbols, text=True)
        assert '9SwiftSoup' in symbols
        print(json.dumps({'forkRevision': revision, 'officialRevision': OFFICIAL, 'configuration': args.configuration, 'fullTreeCases': 7, 'equalCases': 6, 'explicitExistingFosterDifference': 1, 'bothModulesLinked': True, 'dependencyKind': 'file Git URLs, not path dependencies'}, ensure_ascii=False))

if __name__ == '__main__':
    main()
