#!/usr/bin/env python3
"""Verify pinned Windows visual sources and documented local patches."""
import hashlib
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
UI = ROOT / 'apps/windows/flutter_ui'

def check():
    inventory = json.loads((UI / 'vendor/MACOS-SOURCE.json').read_text())['files']
    patches = json.loads((UI / 'vendor/WINDOWS-PATCHES.json').read_text())
    if set(patches) - set(inventory):
        raise ValueError('Patch refers to a file outside the copied source inventory')
    for name, source in inventory.items():
        expected = patches.get(name, source)['sha256']
        if hashlib.sha256((UI / name).read_bytes()).hexdigest() != expected:
            raise ValueError(f'Unrecorded Windows visual source change: {name}')
    print(f'Verified {len(inventory)} Windows visual sources and {len(patches)} local patches.')

if __name__ == '__main__':
    check()
