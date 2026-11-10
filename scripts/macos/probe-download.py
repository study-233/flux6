#!/usr/bin/env python3
"""Exercise the production Swift download path with a pinned, non-TUN core.

All traffic stays on loopback. Two synthetic HTTP nodes make routing observable.
No system service, DNS setting, login Keychain or real account is used.
"""
import argparse
import hashlib
import http.server
import json
import os
from pathlib import Path
import secrets
import select
import socket
import socketserver
import ssl
import subprocess
import threading
import time
import uuid

ROOT = Path(__file__).resolve().parents[2]


class DataServer(http.server.BaseHTTPRequestHandler):
    def log_message(self, *_):
        pass

    def do_GET(self):
        self.send_response(503 if self.path == '/httpError' else 200)
        size = (33 if self.path == '/oversized' else 32 if self.path in ['/partial', '/cancel'] else 2) * 1024 * 1024
        self.send_header('Content-Length', str(size))
        self.end_headers()
        if self.path in ['/httpError', '/oversized']:
            return
        try:
            for _ in range(size // 16384):
                self.wfile.write(b'x' * 16384)
                self.wfile.flush()
                time.sleep(0.05 if self.path in ['/partial', '/cancel'] else 0.001)
        except (BrokenPipeError, ConnectionResetError, ssl.SSLError):
            pass


class Relay(socketserver.StreamRequestHandler):
    def handle(self):
        line = self.rfile.readline(8192).decode('ascii').split()
        if len(line) != 3 or line[0] != 'CONNECT' or line[1] not in [f'localhost:{self.server.destination}', f'127.0.0.1:{self.server.destination}']:
            self.wfile.write(b'HTTP/1.1 403 Forbidden\r\nContent-Length: 0\r\n\r\n')
            return
        while self.rfile.readline(8192) not in (b'\r\n', b''):
            pass
        self.server.hits += 1
        with socket.create_connection(('127.0.0.1', self.server.destination), timeout=3) as upstream:
            self.wfile.write(b'HTTP/1.1 200 Connection established\r\n\r\n')
            self.wfile.flush()
            peers = [upstream, self.connection]
            try:
                while True:
                    readable, _, _ = select.select(peers, [], [], 13)
                    if not readable:
                        return
                    for source in readable:
                        data = source.recv(65536)
                        if not data:
                            return
                        (self.connection if source is upstream else upstream).sendall(data)
            except (ConnectionError, TimeoutError, OSError):
                pass


def start(server):
    server.daemon_threads = True
    threading.Thread(target=server.serve_forever, daemon=True).start()
    return server


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--core', type=Path, required=True)
    parser.add_argument('--client', type=Path, required=True)
    args = parser.parse_args()
    if os.geteuid() == 0:
        parser.error('Run as the ordinary user')
    core, client = args.core.resolve(strict=True), args.client.resolve(strict=True)
    catalog = json.loads((ROOT / 'internal/mihomo/runtime-assets.json').read_text())
    if hashlib.sha256(core.read_bytes()).hexdigest() not in {a['binarySha256'] for a in catalog['assets'] if a['os'] == 'darwin'}:
        raise RuntimeError('Requires pinned Darwin core')
    work = ROOT / 'build' / ('dl-' + uuid.uuid4().hex[:10])
    work.mkdir(mode=0o700)
    subprocess.run(['openssl', 'req', '-x509', '-newkey', 'rsa:2048', '-nodes', '-days', '1', '-subj', '/CN=localhost',
                    '-addext', 'subjectAltName=DNS:localhost', '-keyout', str(work / 'key.pem'), '-out', str(work / 'cert.pem')],
                   check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    tls = http.server.ThreadingHTTPServer(('127.0.0.1', 0), DataServer)
    context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    context.load_cert_chain(work / 'cert.pem', work / 'key.pem')
    tls.socket = context.wrap_socket(tls.socket, server_side=True)
    start(tls)
    nodes = [socketserver.ThreadingTCPServer(('127.0.0.1', 0), Relay) for _ in range(2)]
    for node in nodes:
        node.destination = tls.server_port
        node.hits = 0
        start(node)
    with socket.socket() as reservation:
        reservation.bind(('127.0.0.1', 0))
        proxy_port = reservation.getsockname()[1]
    group = '__FreeV6_Download_Test__'
    config = {'mode': 'direct', 'external-controller-unix': str(work / 'c.sock'), 'log-level': 'debug',
              'tun': {'enable': False}, 'dns': {'enable': False}, 'sniffer': {'enable': False},
              'profile': {'store-selected': False},
              'proxies': [{'name': f'test-{letter}', 'type': 'http', 'server': '127.0.0.1', 'port': node.server_address[1]}
                          for letter, node in zip('AB', nodes)],
              'proxy-groups': [{'name': '♻️ 自动选择', 'type': 'select', 'proxies': ['test-A', 'test-B']},
                               {'name': group, 'type': 'select', 'hidden': True, 'proxies': ['REJECT', 'test-A', 'test-B']}],
              'listeners': [{'name': '__FreeV6_Download_In__', 'type': 'http', 'listen': '127.0.0.1', 'port': proxy_port,
                             'proxy': group, 'users': [{'username': 'freev6-test', 'password': secrets.token_hex(32)}]}],
              'rules': ['MATCH,REJECT']}
    (work / 'config.json').write_text(json.dumps(config))
    (work / 'config.json').chmod(0o600)
    report = []
    with (work / 'core.log').open('w') as log:
        child = subprocess.Popen([core, '-d', work, '-f', work / 'config.json'], stdout=log, stderr=log,
                                 env={'PATH': '/usr/bin:/bin'})
        try:
            deadline = time.monotonic() + 12
            while not (work / 'c.sock').exists():
                if child.poll() is not None or time.monotonic() > deadline:
                    raise RuntimeError('Core did not start')
                time.sleep(0.05)
            time.sleep(0.2)
            # Loopback access must not bypass this listener's password.
            denied = subprocess.run(['/usr/bin/curl', '--disable', '--silent', '--noproxy', '', '--proxy', f'http://127.0.0.1:{proxy_port}',
                                     '--max-time', '2', '--output', '/dev/null', '--write-out', '%{http_connect}',
                                     f'https://localhost:{tls.server_port}/normal'], capture_output=True, text=True, timeout=4)
            if denied.stdout != '407':
                raise RuntimeError('Unauthenticated listener did not reject request')
            for scenario in ['normal', 'cancel', 'oversized', 'httpError', 'partial', 'badNode']:
                result = subprocess.run([client, 'download-probe', work, str(child.pid), str(tls.server_port), scenario],
                                        capture_output=True, text=True, timeout=18)
                if result.returncode:
                    raise RuntimeError(f'{scenario}: {result.stderr} {result.stdout}')
                report.append(json.loads(result.stdout))
            if nodes[0].hits != 0 or nodes[1].hits != 5:
                raise RuntimeError(f'Wrong node received download requests: {[n.hits for n in nodes]}')
            evidence = {'scope': 'loopback only, pinned core, ordinary user, no TUN/DNS changes', 'unauthenticatedRejected': True,
                        'nodeARequests': nodes[0].hits, 'nodeBRequests': nodes[1].hits, 'cases': report}
            (work / 'report.json').write_text(json.dumps(evidence, indent=2))
            print(json.dumps(evidence, indent=2))
            print('Evidence:', work / 'report.json')
        finally:
            child.terminate()
            try:
                child.wait(timeout=5)
            except subprocess.TimeoutExpired:
                child.kill(); child.wait()
            for server in [tls] + nodes:
                server.shutdown(); server.server_close()
            (work / 'key.pem').unlink(missing_ok=True)


if __name__ == '__main__':
    main()
