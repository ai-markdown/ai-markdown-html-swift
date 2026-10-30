#!/usr/bin/env python3
"""Verify pinned foreign-content evidence; optionally reproduce it with the installed fixed Web packages."""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess

ROOT = Path(__file__).resolve().parents[2]


def sha(data):
    return hashlib.sha256(data).hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--web', type=Path, help='Re-export through the pinned local Web installation and compare every byte')
    args = parser.parse_args()
    provenance = json.loads((ROOT / 'AIMarkdown/foreign-content-provenance.json').read_text())
    for path, source in provenance['referenceFiles'].items():
        assert sha((ROOT / path).read_bytes()) == source['sha256'], path
    oracle = provenance['oracle']
    fixture = (ROOT / oracle['path']).read_bytes()
    assert sha(fixture) == oracle['sha256']
    assert sha((ROOT / oracle['producer']).read_bytes()) == oracle['producerSHA256']
    data = json.loads(fixture)
    assert data['parse5'] == provenance['parse5Version'] == '7.3.0'
    assert data['hastUtilRaw'] == provenance['hastUtilRawVersion'] == '9.1.3'
    assert data['webRevision'] == provenance['webRevision']
    assert len(data['cases']) == oracle['fragmentCases']
    assert len(data['sequences']) == oracle['hastSequences']
    for key in ['cases', 'sequences']:
        ids = [item['id'] for item in data[key]]
        assert len(ids) == len(set(ids))
        assert all('tree' in item for item in data[key])
    if args.web:
        actual = subprocess.check_output(['node', str(ROOT / oracle['producer']), str(args.web.resolve())])
        assert actual == fixture, 'Fresh Web export differs from the full pinned fixture'
    print(f"Foreign-content evidence verified: {len(data['cases'])} full fragment trees and {len(data['sequences'])} actual hast-util-raw sequences")


if __name__ == '__main__':
    main()
