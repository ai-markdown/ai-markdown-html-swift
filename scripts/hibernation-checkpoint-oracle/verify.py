#!/usr/bin/env python3
"""Verify frozen checkpoint evidence without requiring a Web checkout or executing Swift."""
import hashlib
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
HERE = Path(__file__).resolve().parent
sha = lambda value: hashlib.sha256(value).hexdigest()
provenance = json.loads((ROOT / 'AIMarkdown/hibernation-checkpoint-provenance.json').read_text())
for name, digest in provenance['referenceSHA256'].items():
    assert sha((ROOT / name).read_bytes()) == digest, name
manifest = json.loads((HERE / 'manifest.json').read_text())
assert manifest['webCommit'] == provenance['webRevision']
assert sha((HERE / 'oracle.mjs').read_bytes()) == manifest['bundleSHA256']
for name, digest in manifest['controls'].items():
    assert sha((ROOT / name).read_bytes()) == digest, name
for item in manifest['packages'].values():
    assert sha((HERE / item['saved']).read_bytes()) == item['licenseSHA256'], item['saved']
fixture = ROOT / 'Tests/AIMarkdownHTMLTests/Fixtures/hibernation-checkpoints.json'
assert sha(fixture.read_bytes()) == manifest['fixtureSHA256']
cases = json.loads(fixture.read_text())['cases']
assert len(cases) == manifest['caseCount'] == 347
assert sum(item['webError'] is not None for item in cases) == 32
assert sum(len(item['checkpoints']) for item in cases) == 225
assert sum(point['pendingCharacter'] for item in cases for point in item['checkpoints']) == 167
assert all(item['passiveObserversVerified'] for item in cases)
print('Checkpoint evidence verified: 347 controls, 315 actual Web trees, 32 retained Web errors, 225 actual checkpoints')
