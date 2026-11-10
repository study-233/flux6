#!/bin/bash
# Compile a separate audit mirror. QA instruments and test accounts never enter the candidate.
set -euo pipefail
root="$(cd "$(dirname "$0")/../.." && pwd)"
work="$root/build/p5-visual/mirror/macos"
project="$work/flutter_ui"
sdk="${FREEV6_FLUTTER_SDK:-$root/build/flutter-toolchain/flutter}"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
export PUB_CACHE="${PUB_CACHE:-$root/build/flutter-toolchain/pub-cache}"
export XDG_CONFIG_HOME="$root/build/flutter-toolchain/config" CI=true FLUTTER_SUPPRESS_ANALYTICS=true DART_SUPPRESS_ANALYTICS=true
if [ "$(uname -m)" = arm64 ]; then export FLUTTER_MACOS_ARM64_ONLY=true; fi
if [ "${1:-}" = build ]; then
  mkdir -p "$project"
  rsync -a "$root/apps/macos/Package.swift" "$root/apps/macos/Sources" "$root/apps/macos/Tests" "$work/"
  rsync -a --exclude .dart_tool --exclude build --exclude ephemeral --exclude Pods --exclude xcuserdata "$root/apps/macos/flutter_ui/" "$project/"
  python3 - "$root" "$work" <<'PY'
from pathlib import Path
import sys
root,work=map(Path,sys.argv[1:])
path=work/'flutter_ui/macos/Runner/HostWindowChannel.swift'
s=path.read_text()
key='            case "windowRole":'
assert s.count(key)==1
s=s.replace(key,'            case "visualAXEnable": reply(FlutterVisualAX.enable(in: window))\n            case "visualAX": reply(FlutterVisualAX.snapshot(window: window))\n            case "visualKey": FlutterVisualAX.sendKey(args["key"] as? String ?? "", to: window); reply(true)\n'+key)
path.write_text(s+(root / 'apps/macos/Probes/FlutterVisualAX.swift').read_text())
p=work/'Sources/FreeV6Host/IsolatedHostSession.swift'
old='static let nodes = ["东区", "西区", "北区"]'
s=p.read_text();assert old in s
p.write_text(s.replace(old,'static let nodes = ProcessInfo.processInfo.environment["FREEV6_VISUAL_LONG"] == "1" ? (1...28).map { "校园接入节点 " + String($0) + " · 长中文节点名称与位置说明" } : ["东区", "西区", "北区"]'))
PY
  cd "$project"
  mkdir -p .dart_tool/freev6-probes
  cp "$root/apps/macos/Probes/FlutterVisualAudit.dart" .dart_tool/freev6-probes/visual.dart
  "$sdk/bin/flutter" pub get --offline --enforce-lockfile
  "$sdk/bin/flutter" build macos --release --no-pub --target .dart_tool/freev6-probes/visual.dart
  qa="$(bash "$root/scripts/macos/build-flutter-host.sh" --qa-clone)"
  built="$project/build/macos/Build/Products/Release/Flux6 Flutter Preview.app"
  mv "$qa/Contents/Frameworks/App.framework" "$(dirname "$qa")/consumer-framework"
  ditto "$built/Contents/Frameworks/App.framework" "$qa/Contents/Frameworks/App.framework"
  cp "$built/Contents/MacOS/Flux6 Flutter Preview" "$qa/Contents/MacOS/Flux6 Flutter Integration"
  codesign --force --sign - --entitlements "$project/macos/Runner/Integration.entitlements" "$qa"
  codesign --verify --deep --strict "$qa"
  printf '%s\n' "$qa" > "$root/build/p5-visual/app-path"
elif [ "${1:-}" = run ]; then
  python3 - "$root" <<'PY'
import os,uuid,sys,subprocess,shutil
from pathlib import Path
r=Path(sys.argv[1]);target=r/'build/p5-visual'
exe=Path((target/'app-path').read_text().strip())/'Contents/MacOS/Flux6 Flutter Integration'
dest=r/'docs/compose/audits/2026-11-07-p5-p6/visual'
dest.mkdir(parents=True,exist_ok=True)
for mode in ('default','long'):
    run=uuid.uuid4().hex
    process=subprocess.run([exe],env={**os.environ,'FREEV6_VISUAL_RUN':run,'FREEV6_VISUAL_LONG':str(int(mode=='long'))},
                           stdout=subprocess.PIPE,stderr=subprocess.STDOUT,timeout=125)
    log=process.stdout.decode(errors='replace');(target/f'{mode}.log').write_text(log)
    if process.returncode or 'VISUAL PASS' not in log: raise SystemExit(log[-5000:])
    folder=Path(next(x.split(' ',1)[1] for x in log.splitlines() if x.startswith('VISUAL_ARTIFACTS ')))
    if folder.name!='FreeV6Visual-'+run: raise RuntimeError('unexpected output directory')
    for f in folder.iterdir():
        if f.is_dir():
            shutil.copytree(f,target/f.name,dirs_exist_ok=True)
        else: shutil.copy2(f,dest/f.name)
timeline=__import__('json').loads((target/'motion/times.json').read_text())
lines=[]
for i,t in enumerate(timeline):
    lines.extend([f"file '{i:03d}.png'",'duration %.3f'%((timeline[i+1]-t)/1000 if i+1<len(timeline) else .4)])
lines.append(f"file '{len(timeline)-1:03d}.png'")
concat=target/'motion/frames.concat';concat.write_text('\n'.join(lines)+'\n')
subprocess.run(['ffmpeg','-hide_banner','-loglevel','error','-y','-f','concat','-safe','0','-i',str(concat),
                '-vf','fps=30','-c:v','libx264','-crf','18','-pix_fmt','yuv420p','-movflags','+faststart',str(dest/'disconnect.mp4')],check=True)

PY
else
  echo 'Usage: probe-flutter-visual.sh build|run' >&2; exit 2
fi
