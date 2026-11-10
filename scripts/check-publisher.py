"""Check that shipped links and update channels belong to this distribution."""
import json
from pathlib import Path
import re

root = Path(__file__).resolve().parents[1]
source = (root / "internal/publisher/publisher.go").read_text()
repository = re.search(r'Repository\s*=\s*"([^"]+)"', source).group(1)
expected = {
    "web/app.js": f"const UPDATE_OWNER_REPO = '{repository}';",
    "web/index.html": f"@{repository}",
    "scripts/macos/github_channel.py": f'REPOSITORY = "{repository}"',
    "src-tauri/nsis-hooks.nsh": f"https://github.com/{repository}/blob/main/docs/agreement.md",
}
errors = []
for path, text in expected.items():
    # Windows-only checkouts may not yet contain the Mac release tools.
    if path.startswith("scripts/macos/") and not (root / path).exists():
        continue
    if text not in (root / path).read_text():
        errors.append(f"{path}: publisher does not match {repository}")

for directory, suffixes in {
    "internal": {".go"}, "cmd": {".go"}, "web": {".js", ".html"},
    "src-tauri": {".rs", ".nsh"}, "macos/Sources": {".swift"},
}.items():
    for path in (root / directory).rglob("*"):
        if (path.suffix not in suffixes or path.name.endswith("_test.go")
                or "vendor" in path.parts or "target" in path.parts):
            continue
        text = path.read_text()
        if re.search(r"evansrrr/free-v6|(?:freev6|ich)\.cc\.cd", text):
            errors.append(f"{path.relative_to(root)}: previous publisher endpoint")

notice = json.loads((root / "notice.json").read_text())
if not isinstance(notice.get("cloudProfile"), bool):
    errors.append("notice.json: cloudProfile must be an explicit boolean")
if errors:
    raise SystemExit("\n".join(errors))
print(f"Publisher links verified: {repository}")
