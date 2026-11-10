#!/usr/bin/env python3
"""Validate the pinned core's private Unix controller without TUN, DNS or proxies.

Runs only as the current user with an empty direct-only configuration. No WARP
credentials, rule providers, root service, TCP listeners or system changes.
"""
import argparse
import hashlib
import http.client
import json
import os
from pathlib import Path
import platform
import shutil
import socket
import stat
import subprocess
import time
import uuid

ROOT = Path(__file__).resolve().parents[2]


class UnixHTTP(http.client.HTTPConnection):
    def __init__(self, path):
        super().__init__("localhost", timeout=3)
        self.path = path

    def connect(self):
        self.sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.sock.settimeout(self.timeout)
        self.sock.connect(str(self.path))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--core", type=Path, required=True)
    parser.add_argument("--native-client", type=Path, help="Debug freev6-probe; exercise production Swift controller operations")
    args = parser.parse_args()
    if os.geteuid() == 0:
        parser.error("Never run this probe as root")
    arch = {"arm64": "arm64", "x86_64": "amd64"}.get(platform.machine())
    catalog = json.loads((ROOT / "internal/mihomo/runtime-assets.json").read_text())
    asset = next(a for a in catalog["assets"] if a["os"] == "darwin" and a["arch"] == arch)
    core = args.core.resolve(strict=True)
    if core.stat().st_size > 150 << 20 or hashlib.sha256(core.read_bytes()).hexdigest() != asset["binarySha256"]:
        raise RuntimeError("Only the pinned native binary may run")
    work = ROOT / "build/controller-probes" / str(uuid.uuid4())
    work.mkdir(parents=True, mode=0o700)
    socket_dir = ROOT / "build" / ("c-" + uuid.uuid4().hex[:12])
    # Match the 100-byte production session pathname, below Darwin's 104-byte limit.
    remaining = 100 - len(os.fsencode(socket_dir / "c.sock"))
    if remaining < 0:
        raise RuntimeError("Checkout path too long for the 100-byte Unix socket probe")
    socket_dir = socket_dir.with_name(socket_dir.name + "x" * remaining)
    socket_dir.mkdir(mode=0o700)
    endpoint = socket_dir / "c.sock"
    config = {
        "mode": "direct", "mixed-port": 0, "port": 0, "socks-port": 0,
        "allow-lan": False, "log-level": "error", "external-controller": "",
        "external-controller-tls": "", "external-controller-unix": str(endpoint),
        "secret": "probe-only-ignored-by-upstream-unix-listener",
        "tun": {"enable": False}, "dns": {"enable": False}, "sniffer": {"enable": False},
        "ntp": {"enable": False}, "geo-auto-update": False,
        "profile": {"store-selected": False, "store-fake-ip": False},
        "proxies": [], "proxy-groups": [
            {"name": name, "type": "select", "proxies": ["DIRECT", "REJECT"]}
            for name in ["选择 / 50%", "literal%2F?&"]
        ] if args.native_client else [], "rules": ["MATCH,DIRECT"],
    }
    path = work / "config.json"
    path.write_text(json.dumps(config))
    child = None
    report = {}
    try:
        with (work / "core.log").open("w") as log:
            child = subprocess.Popen([core, "-d", work, "-f", path], cwd=work, env={"PATH": "/usr/bin:/bin"},
                                     stdin=subprocess.DEVNULL, stdout=log, stderr=subprocess.STDOUT)
            deadline = time.monotonic() + 12
            while not endpoint.exists():
                if child.poll() is not None:
                    raise RuntimeError("Core exited before Unix listener became available")
                if time.monotonic() >= deadline:
                    raise RuntimeError("Unix controller did not become ready")
                time.sleep(0.1)
            if not stat.S_ISSOCK(endpoint.stat().st_mode) or socket_dir.stat().st_mode & 0o777 != 0o700:
                raise RuntimeError("Controller is not inside a private directory")
            client = UnixHTTP(endpoint)
            try:
                client.request("GET", "/version")  # Unix listener intentionally ignores secret.
                response = client.getresponse()
                payload = response.read(65537)
                if response.status != 200 or len(payload) > 65536 or json.loads(payload).get("version") != catalog["version"]:
                    raise RuntimeError("Unexpected Unix controller response")
            finally:
                client.close()
            if args.native_client:
                result = subprocess.run([args.native_client.resolve(strict=True), "core-controller", socket_dir, str(child.pid)],
                                        capture_output=True, text=True, timeout=45)
                (work / "native-client.log").write_text(result.stdout + result.stderr)
                if result.returncode:
                    raise RuntimeError("Native controller probe failed; see native-client.log")
                report["nativeController"] = json.loads(result.stdout)
            listeners = subprocess.run(["/usr/sbin/lsof", "-nP", "-a", "-p", str(child.pid), "-i"],
                                       capture_output=True, text=True, timeout=5)
            if listeners.returncode != 1 or listeners.stdout.strip() or listeners.stderr.strip():
                raise RuntimeError("Expected no IPv4/IPv6 sockets in the controller-only probe")
            report.update({"scope": "ordinary-user Unix controller only; no root/TUN/DNS or cross-user access validation",
                      "coreVersion": catalog["version"], "socketPathBytes": len(os.fsencode(endpoint)),
                      "parentMode": "0700", "socketMode": oct(endpoint.stat().st_mode & 0o777),
                      "versionWithoutBearer": True, "noInternetSockets": True, "pid": child.pid})
    finally:
        if child is not None:
            if child.poll() is None:
                child.terminate()
                try:
                    child.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    child.kill()
                    child.wait(timeout=5)
                    raise RuntimeError("Core required forced termination")
            report["exitCode"] = child.returncode
            report["reaped"] = True
        shutil.rmtree(socket_dir)
    (work / "result.json").write_text(json.dumps(report, indent=2) + "\n")
    print("PASS: pinned core Unix controller; private parent, 100-byte path, no IP sockets, process reaped")
    print("Evidence:", work / "result.json")


if __name__ == "__main__":
    main()
