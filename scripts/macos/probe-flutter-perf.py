#!/usr/bin/env python3
"""Run isolated releases sequentially and preserve each real callback and engine timing."""
import argparse
import hashlib
import itertools
import json
import os
from pathlib import Path
import platform
import queue
import signal
import subprocess
import threading
import time

ROOT = Path(__file__).resolve().parents[2]
DEFAULT_OUT = ROOT / 'docs/compose/audits/2026-11-07-p5-p6/performance'

def read(cmd):
    return subprocess.check_output(cmd, text=True, stderr=subprocess.DEVNULL).strip()

def bundle_hashes(app):
    contents = app / 'Contents'
    paths = [
        'MacOS/FreeV6 Flutter Integration', 'Frameworks/App.framework/Versions/A/App',
        'Helpers/freev6-worker', 'Helpers/freev6-session-fixture',
    ]
    return {name: hashlib.sha256((contents / name).read_bytes()).hexdigest() for name in paths}


def sample_process(process, started):
    try:
        cpu, rss = read(['ps', '-p', str(process.pid), '-o', '%cpu=,rss=']).split()
    except (ValueError, subprocess.CalledProcessError):
        return None
    return [round(1000 * (time.monotonic() - started)), float(cpu), int(rss)]


def run_one(app, width, nodes, online, round_number, directory, steady, pointer, manual):
    env = dict(os.environ, FREEV6_PERF_WIDTH=str(width), FREEV6_PERF_NODES=str(nodes), FREEV6_PERF_ONLINE=str(online),
               FREEV6_PERF_STEADY=str(steady), FREEV6_PERF_POINTER=str(int(pointer)),
               FREEV6_PERF_MANUAL=str(int(manual)))
    exe = app / 'Contents/MacOS/FreeV6 Flutter Integration'
    rows = []
    stages = {}
    started = time.monotonic()
    p = subprocess.Popen([str(exe)], stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                         env=env, start_new_session=True, text=True, errors='replace')
    buf = queue.Queue()
    def reader():
        for line in p.stdout:
            buf.put((time.monotonic() - started, line.rstrip()))
        buf.put(None)
    threading.Thread(target=reader, daemon=True).start()
    ready = None
    pointer_result = None
    manual_result = None
    steady_times = []
    passed = False
    resources = []
    name = f'r{round_number}-{width}-{nodes}-{"on" if online else "off"}'
    try:
        sample_at = started + .5
        while time.monotonic() - started < 40 + steady + (50 if manual else 0):
            try:
                line = buf.get(timeout=.2)
            except queue.Empty:
                line = ()
            if line is None:
                break
            if line:
                elapsed, value = line
                rows.append(value)
                marker, _, data = value.partition(' ')
                if marker == 'PERFREADY':
                    ready = dict(json.loads(data), launchToReadyMs=elapsed * 1000)
                elif marker == 'PERFPOINTER':
                    pointer_result = json.loads(data)
                elif marker == 'PERFDRAGREADY':
                    print(f'Waiting for real drag of QA PID {p.pid} window {data}', flush=True)
                elif marker == 'PERFMANUAL':
                    manual_result = json.loads(data)
                elif marker == 'PERFSTEADY':
                    steady_times.append(round(1000 * elapsed))
                elif marker == 'PERFSTAGE':
                    stage = json.loads(data)
                    stages[stage['name']] = stage
                elif marker == 'PERFPASS':
                    passed = True
            if time.monotonic() >= sample_at:
                sample_at += .5
                sample = sample_process(p, started)
                if sample is not None:
                    resources.append(sample)
        if p.poll() is None:
            try:
                p.wait(timeout=1)
            except subprocess.TimeoutExpired:
                os.killpg(p.pid, signal.SIGKILL)
                p.wait()
    finally:
        if p.poll() is None:
            os.killpg(p.pid, signal.SIGKILL)
            p.wait()
    expected = {'nav32', 'first4', 'resize', 'move', 'actions'}
    if pointer:
        expected.add('pointer')
    if manual:
        expected.add('manualDrag')
    if not passed or p.returncode or not ready or set(stages) != expected:
        raise RuntimeError('\n'.join(x[:500] for x in rows if not x.startswith('PERFSTAGE')) + f'\n{name}: code={p.returncode}, stages={list(stages)}')
    if any(not s['cvUs'] or not s['mainUs'] for s in stages.values()) or not stages['nav32']['frameUs']:
        raise RuntimeError(f'{name}: one of the instruments returned no measurements')
    doc = dict(round=round_number, width=width, nodes=nodes, online=bool(online), ready=ready,
               stages=stages, processSamples=resources, steadyMs=steady_times, pointer=pointer_result, manual=manual_result)
    (directory / f'{name}.json').write_text(json.dumps(doc, ensure_ascii=False, separators=(',', ':')) + '\n')
    counts = '/'.join(str(len(stages['nav32'][key])) for key in ('mainUs', 'cvUs', 'frameUs'))
    print(f'{name} launch={ready["launchToReadyMs"]:.0f}ms nav samples (main/CV/Flutter) {counts}', flush=True)


def main():
    cli = argparse.ArgumentParser(description=__doc__)
    cli.add_argument('--rounds', type=int, default=3)
    cli.add_argument('--widths', type=int, nargs='+', default=[720, 920, 1280])
    cli.add_argument('--counts', type=int, nargs='+', choices=[3, 28], default=[3, 28])
    cli.add_argument('--states', type=int, nargs='+', choices=[0, 1], default=[0, 1])
    cli.add_argument('--out', type=Path, default=DEFAULT_OUT)
    cli.add_argument('--steady-seconds', type=int, default=0)
    cli.add_argument('--local-pointer', action='store_true')
    cli.add_argument('--manual-pointer', action='store_true', help='Allow 45s for the tester to drag the QA title strip')
    args = cli.parse_args()
    app = Path((ROOT / 'build/flutter-perf/bundle.txt').read_text().strip())
    if app.name != 'FreeV6 Flutter QA.app':
        raise SystemExit('Expected dedicated QA app')
    raw = args.out / 'raw'
    raw.mkdir(parents=True, exist_ok=True)
    flutter = ROOT / 'build/flutter-toolchain/flutter/bin/cache/flutter.version.json'
    metadata = {
        'os': read(['sw_vers', '-productVersion']), 'build': read(['sw_vers', '-buildVersion']),
        'model': read(['sysctl', '-n', 'hw.model']), 'chip': read(['sysctl', '-n', 'machdep.cpu.brand_string']),
        'ram': int(read(['sysctl', '-n', 'hw.memsize'])), 'architecture': platform.machine(),
        'xcode': read(['/Applications/Xcode.app/Contents/Developer/usr/bin/xcodebuild', '-version']),
        'flutter': json.loads(flutter.read_text()), 'qaPayloadSHA256': bundle_hashes(app),
        'loadBefore': os.getloadavg(), 'timeStarted': time.strftime('%Y-%m-%dT%H:%M:%S%z'),
    }
    machine = args.out / 'machine.json'
    machine.write_text(json.dumps(metadata, ensure_ascii=False, indent=2) + '\n')
    cases = list(itertools.product(args.widths, args.counts, args.states))
    for round_number in range(1, args.rounds + 1):
        # Vary ordering deterministically so a cell is not always first or last.
        offset = (round_number - 1) * 5 % len(cases)
        for width, count, online in cases[offset:] + cases[:offset]:
            run_one(app, width, count, online, round_number, raw, args.steady_seconds, args.local_pointer, args.manual_pointer)
    metadata.update(loadAfter=os.getloadavg(), timeFinished=time.strftime('%Y-%m-%dT%H:%M:%S%z'))
    machine.write_text(json.dumps(metadata, ensure_ascii=False, indent=2) + '\n')


if __name__ == '__main__':
    main()
