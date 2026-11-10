#!/usr/bin/env python3
"""Read-only, bounded subscription to FreeV6's root-owned core log socket.

Run by the offline collector after local sudo authorization. Never reads a
session config, credential, or Keychain item; only fixed GET API routes.
"""
import argparse
import datetime
import http.client
import json
import os
from pathlib import Path
import re
import signal
import socket
import stat
import sys
import threading
import time

SESSIONS = Path('/Library/Application Support/dev.freev6.desktop/sessions')
STOP = threading.Event()
LOCK = threading.Lock()
COUNT = 0


def safe_text(value):
    value = str(value)[:4096]
    if re.search(r'(?i)private.?key|password|authorization|bearer|secret|token', value):
        return '[message containing credential-related fields omitted]'
    value = re.sub(r'https?://[^\s\]"<>]+', '[URL omitted]', value)
    return value.replace('\x00', '')


def emit(kind, **values):
    global COUNT
    with LOCK:
        if COUNT >= 512:
            STOP.set()
            return
        COUNT += 1
        print(json.dumps(dict(time=datetime.datetime.now(datetime.timezone.utc).isoformat(),
                              kind=kind, **values), ensure_ascii=False), flush=True)


class UnixHTTP(http.client.HTTPConnection):
    def __init__(self, path):
        super().__init__('localhost', timeout=2)
        self.path = str(path)

    def connect(self):
        self.sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.sock.settimeout(self.timeout)
        self.sock.connect(self.path)


def read_summary(path):
    for route in ('/configs', '/proxies'):
        client = UnixHTTP(path)
        try:
            client.request('GET', route)
            response = client.getresponse()
            raw = response.read(262145)
            if response.status != 200 or len(raw) > 262144:
                continue
            value = json.loads(raw)
            if route == '/configs':
                emit('core_mode', mode=safe_text(value.get('mode', 'unknown')))
            else:
                groups = {}
                for name in ('GLOBAL', '🚀 节点选择', '♻️ 自动选择', '☑️ 手动切换', '🔗 链式代理'):
                    proxy = value.get('proxies', {}).get(name)
                    if proxy:
                        selected = proxy.get('now')
                        target = value.get('proxies', {}).get(selected, {})
                        groups[name] = dict(selected=safe_text(selected), type=safe_text(proxy.get('type')),
                                            selected_type=safe_text(target.get('type')))
                emit('core_selection', groups=groups)
        except (OSError, ValueError, http.client.HTTPException):
            pass
        finally:
            client.close()


def subscribe(path):
    client = UnixHTTP(path)
    try:
        client.request('GET', '/logs?level=debug')
        emit('core_subscription_requested', session=path.parent.name)
        # Log delivery is independent of the console log threshold. No PATCH
        # /configs or other mutation is necessary to observe warning events.
        summary = threading.Thread(target=read_summary, args=(path,), daemon=True)
        summary.start()
        response = client.getresponse()
        if response.status != 200:
            emit('core_subscription_rejected', status=response.status)
            return
        while not STOP.is_set():
            line = response.readline(16385)
            if not line:
                break
            if len(line) > 16384:
                emit('core_line_omitted', reason='size limit')
                break
            event = json.loads(line)
            level, payload = event.get('type'), str(event.get('payload', ''))
            # Keep failure messages and fixed test-target/connection records;
            # omit unrelated debug events and URLs with query credentials.
            if level in ('warning', 'error') or 'www.gstatic.com' in payload:
                emit('core_network_event', level=safe_text(level), message=safe_text(payload))
        summary.join(timeout=1)
    except (OSError, ValueError, http.client.HTTPException) as error:
        emit('core_subscription_ended', reason=type(error).__name__)
    finally:
        client.close()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--duration', type=int, default=900)
    parser.add_argument('--fixture-socket', type=Path)
    args = parser.parse_args()
    if not 1 <= args.duration <= 1800:
        parser.error('duration must be 1..1800')
    if args.fixture_socket:
        if os.geteuid() == 0:
            parser.error('fixture paths are available only to ordinary-user tests')
        subscribe(args.fixture_socket)
        return
    if os.geteuid() != 0:
        parser.error('root access is required to traverse the private service session directory')
    for sig in (signal.SIGINT, signal.SIGTERM):
        signal.signal(sig, lambda *_: STOP.set())

    def parent_closed():
        while sys.stdin.buffer.read(1):
            pass
        STOP.set()
    threading.Thread(target=parent_closed, daemon=True).start()
    emit('core_observer_ready', behavior='fixed GET log and status routes only; no configuration or credentials read')
    threads, seen = [], set()
    deadline = time.monotonic() + args.duration
    while not STOP.is_set() and time.monotonic() < deadline:
        try:
            for directory in SESSIONS.iterdir():
                if not re.fullmatch(r'[0-9A-Fa-f]{8}(?:-[0-9A-Fa-f]{4}){3}-[0-9A-Fa-f]{12}', directory.name):
                    continue
                info = directory.lstat()
                if not stat.S_ISDIR(info.st_mode) or info.st_uid != 0:
                    continue
                path = directory / 'c.sock'
                info = path.lstat()
                if not stat.S_ISSOCK(info.st_mode) or info.st_uid != 0 or str(path) in seen:
                    continue
                seen.add(str(path))
                thread = threading.Thread(target=subscribe, args=(path,), daemon=True)
                thread.start()
                threads.append(thread)
        except (FileNotFoundError, PermissionError):
            pass
        STOP.wait(.01)
    STOP.set()
    for thread in threads:
        thread.join(timeout=3)
    emit('core_observer_finished', sessions=len(seen))


if __name__ == '__main__':
    main()
