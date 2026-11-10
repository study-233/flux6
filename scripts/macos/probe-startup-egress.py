#!/usr/bin/env python3
"""Reproduce early mihomo TCP resets, then pass the production Swift startup gate.

Ordinary-user loopback fixture only: no TUN, system proxy, DNS or credentials.
The local TLS CA is passed only to the DEBUG probe, never installed on the host.
"""
import argparse
import http.client
import http.server
import json
from pathlib import Path
import select
import socket
import ssl
import struct
import subprocess
import tempfile
import threading

ROOT = Path(__file__).resolve().parents[2]


def unused_port():
    with socket.socket() as sock:
        sock.bind(("127.0.0.1", 0))
        return sock.getsockname()[1]


class UnixHTTP(http.client.HTTPConnection):
    def __init__(self, path):
        super().__init__("localhost", timeout=2)
        self.path = str(path)

    def connect(self):
        self.sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.sock.settimeout(2)
        self.sock.connect(self.path)


def exercise(probe, core_binary):
    release, requested = threading.Event(), threading.Event()

    class Provider(http.server.BaseHTTPRequestHandler):
        def do_GET(self):
            requested.set()
            release.wait(30)
            data = b"DOMAIN,example.test\n"
            self.send_response(200)
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)

        def log_message(self, *args):
            pass

    class Target(http.server.BaseHTTPRequestHandler):
        def do_GET(self):
            self.send_response(204)
            self.end_headers()

        def log_message(self, *args):
            pass

    with tempfile.TemporaryDirectory(prefix="fv6-startup-") as folder:
        path = Path(folder).resolve()
        mixed, dns = unused_port(), unused_port()
        (path / "tls.cnf").write_text(
            "[req]\nprompt=no\ndistinguished_name=dn\nx509_extensions=ext\n[dn]\nCN=localhost\n"
            "[ext]\nsubjectAltName=DNS:localhost\nbasicConstraints=critical,CA:TRUE\n"
            "keyUsage=critical,digitalSignature,keyEncipherment,keyCertSign\nextendedKeyUsage=serverAuth\n")
        subprocess.run(["/usr/bin/openssl", "req", "-x509", "-nodes", "-newkey", "rsa:2048", "-keyout",
                        str(path / "key.pem"), "-out", str(path / "cert.pem"), "-days", "1", "-config",
                        str(path / "tls.cnf")], check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        provider = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Provider)
        target = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Target)
        tls = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        tls.load_cert_chain(path / "cert.pem", path / "key.pem")
        target.socket = tls.wrap_socket(target.socket, server_side=True)
        for server in (provider, target):
            threading.Thread(target=server.serve_forever, daemon=True).start()
        config = {
            "mode": "rule", "mixed-port": mixed, "bind-address": "127.0.0.1", "allow-lan": False,
            "log-level": "debug", "external-controller": "", "external-controller-unix": str(path / "c.sock"),
            "tun": {"enable": False}, "dns": {"enable": True, "listen": f"127.0.0.1:{dns}",
                "use-hosts": True, "nameserver": ["127.0.0.1:9"]}, "hosts": {"ready.test": "127.0.0.9"},
            "sniffer": {"enable": False}, "ntp": {"enable": False}, "geo-auto-update": False,
            "profile": {"store-selected": False, "store-fake-ip": False}, "proxies": [], "proxy-groups": [],
            "rule-providers": {"slow": {"type": "http", "behavior": "classical", "format": "text",
                "url": f"http://127.0.0.1:{provider.server_port}/rules", "path": "./rules.list", "interval": 86400}},
            "rules": ["RULE-SET,slow,DIRECT", "MATCH,DIRECT"],
        }
        (path / "config.json").write_text(json.dumps(config))
        checker = None
        with (path / "core.log").open("w") as log:
            core = subprocess.Popen([str(core_binary), "-d", str(path), "-f", str(path / "config.json")],
                                    stdout=log, stderr=log)
            try:
                assert requested.wait(5), "provider was not requested"
                client = UnixHTTP(path / "c.sock")
                client.request("GET", "/version")
                response = client.getresponse()
                version = json.loads(response.read())
                assert response.status == 200
                client.close()
                query = struct.pack("!HHHHHH", 12, 0x100, 1, 0, 0, 0) + b"\x05ready\x04test\0" + struct.pack("!HH", 1, 1)
                with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as sock:
                    sock.settimeout(2)
                    sock.sendto(query, ("127.0.0.1", dns))
                    assert sock.recv(512).endswith(socket.inet_aton("127.0.0.9"))
                one_shot = subprocess.run([
                    "/usr/bin/curl", "--disable", "--silent", "--noproxy", "", "--proxy", f"http://127.0.0.1:{mixed}",
                    "--cacert", str(path / "cert.pem"), "--max-time", "3", "--output", "/dev/null", "--write-out",
                    "%{http_code}", f"https://localhost:{target.server_port}/generate_204"], capture_output=True, text=True)
                assert one_shot.returncode in (35, 56) and one_shot.stdout == "000", one_shot
                checker = subprocess.Popen([str(probe), "startup-egress", str(path), str(core.pid), str(mixed),
                                            str(target.server_port)], stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                           text=True, bufsize=1)
                # Release the provider only after the real Swift gate has
                # observed two rejected requests. No timing-dependent sleep.
                early = []
                for _ in range(2):
                    assert select.select([checker.stdout], [], [], 5)[0], "no Swift attempt received"
                    line = checker.stdout.readline()
                    assert line, checker.stderr.read()
                    event = json.loads(line)
                    assert event["attemptExit"] in (35, 56), event
                    early.append(event["attemptExit"])
                release.set()
                output, error = checker.communicate(timeout=15)
                assert checker.returncode == 0, error
                result = json.loads(output.strip().splitlines()[-1])
                assert result["exits"][:2] == early and result["exits"][-1] == 0 and result["peerVerified"], result
                assert core.poll() is None
                return {"passed": True, "core": version, "controllerAndDNSReadyBeforeProviders": True,
                        "oldOneShot": {"exit": one_shot.returncode, "http": one_shot.stdout}, "startupGate": result}
            finally:
                release.set()
                if checker and checker.poll() is None:
                    checker.kill()
                    checker.communicate(timeout=5)
                core.terminate()
                try:
                    core.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    core.kill()
                    core.wait(timeout=5)
                for server in (provider, target):
                    server.shutdown()
                    server.server_close()


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--probe", type=Path, required=True)
    parser.add_argument("--core", type=Path, default=ROOT / "build/macos-probes/mihomo-darwin-arm64")
    parser.add_argument("--output", type=Path, default=ROOT / "build/http-diagnosis/startup-egress-verification.json")
    args = parser.parse_args()
    result = exercise(args.probe.resolve(), args.core.resolve())
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(result, ensure_ascii=False, indent=2) + "\n")
    print(json.dumps(result, ensure_ascii=False, indent=2))
