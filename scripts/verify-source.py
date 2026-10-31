#!/usr/bin/env python3
"""Verify the current source, package, and license manifest without Git history."""
import argparse
import hashlib
import json
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SOURCE = ROOT / 'Sources/AIMarkdownHTML'
MANIFEST = ROOT / 'scripts/source-manifest.json'

def sha(data):
    return hashlib.sha256(data).hexdigest()

def current():
    return {'schemaVersion': 2, 'module': 'AIMarkdownHTML',
            'sourceRoot': 'Sources/AIMarkdownHTML',
            'runtimeFiles': {str(p.relative_to(SOURCE)): sha(p.read_bytes()) for p in sorted(SOURCE.rglob('*.swift'))},
            'packageSHA256': sha((ROOT / 'Package.swift').read_bytes()),
            'licenseSHA256': sha((ROOT / 'LICENSE').read_bytes())}

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--record-current', action='store_true', help='Record reviewed and tested source hashes; this does not replace behavioral tests')
    args = parser.parse_args()
    actual = current()
    if args.record_current:
        MANIFEST.write_text(json.dumps(actual, indent=2) + '\n')
    expected = json.loads(MANIFEST.read_text())
    assert actual == expected, 'Source, Package.swift, or license differs from the manifest; review and test changes before explicitly updating it'
    subprocess.run([sys.executable, str(ROOT / 'scripts/hibernation-checkpoint-oracle/verify.py')], check=True)
    print(f"Source manifest verified: {len(actual['runtimeFiles'])} Swift files in the standalone AIMarkdownHTML package")

if __name__ == '__main__':
    main()
