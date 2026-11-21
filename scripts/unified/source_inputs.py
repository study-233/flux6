"""Source inventory shared by the unified builder and corresponding-source archives."""
import json
import subprocess
from pathlib import Path, PurePosixPath

ROOT = Path(__file__).resolve().parents[2]
MANIFEST = 'unified-source-files.json'
TREES = ('apps/android', 'apps/flux6/client', 'apps/flux6/LICENSE', 'apps/flux6/README.md', 'apps/macos/flutter_ui', 'scripts/unified',
         'scripts/android', 'mobileapi', 'internal', 'shared')


def files(*roots):
    if (ROOT / '.git').exists():
        output = subprocess.check_output(['git', 'ls-files', '-z', '--', *roots], cwd=ROOT)
        return [name for name in output.decode().split('\0') if name]
    manifest = ROOT / MANIFEST
    if not manifest.is_file():
        manifest = ROOT / 'macOS-source-sha256.json'
    if not manifest.is_file():
        manifest = ROOT / 'windows-source-sha256.json'
    selected = []
    for name in json.loads(manifest.read_text(encoding='utf-8')):
        path = PurePosixPath(name)
        if path.is_absolute() or '..' in path.parts or '\\' in name or ':' in name:
            raise ValueError(f'Invalid archive source path: {name}')
        if any(path == PurePosixPath(root) or PurePosixPath(root) in path.parents for root in roots):
            selected.append(name)
    return sorted(selected)
