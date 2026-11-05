"""Verify the generated rule/global chain with two loopback-only HTTP CONNECT hops."""
from contextlib import ExitStack, contextmanager
import http.server
import json
import os
import select
import socket
import socketserver
import struct
import subprocess
import threading
import time
import uuid


@contextmanager
def listening(server):
    with server:
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        try:
            yield server
        finally:
            server.shutdown()
            thread.join()


class LoopbackHop(http.server.BaseHTTPRequestHandler):
    def log_message(self, *_):
        pass

    def do_CONNECT(self):
        self.server.hits += 1
        if self.server.blocked or self.path != "127.0.0.1:" + str(self.server.allowed_port):
            self.send_error(502)
            return
        with socket.create_connection(("127.0.0.1", self.server.allowed_port), timeout=3) as remote:
            self.send_response_only(200)
            self.end_headers()
            peers = [self.connection, remote]
            while True:
                ready, _, _ = select.select(peers, [], [], 4)
                if not ready:
                    return
                for source in ready:
                    data = source.recv(65536)
                    if not data:
                        return
                    (remote if source is self.connection else self.connection).sendall(data)


class Destination(http.server.BaseHTTPRequestHandler):
    def log_message(self, *_):
        pass

    def do_GET(self):
        self.server.hits += 1
        self.send_response(200)
        self.end_headers()
        self.wfile.write(b"controlled destination")


class DatagramEcho(socketserver.BaseRequestHandler):
    def handle(self):
        payload, sock = self.request
        self.server.hits += 1
        sock.sendto(payload, self.client_address)


def udp_probe(port, destination):
    # Keep the SOCKS association open until the datagram is returned or times out.
    with socket.create_connection(("127.0.0.1", port), timeout=3) as control:
        with control.makefile("rb") as reply:
            control.sendall(b"\x05\x01\x00")
            if reply.read(2) != b"\x05\x00":
                raise RuntimeError("SOCKS5 handshake failed")
            control.sendall(b"\x05\x03\x00\x01" + bytes(6))
            prefix = reply.read(4)
            if prefix[:3] != b"\x05\x00\x00":
                raise RuntimeError("UDP association failed")
            address_size = {1: 4, 4: 16}.get(prefix[3])
            if not address_size or len(reply.read(address_size)) != address_size:
                raise RuntimeError("Invalid relay address")
            relay_port = struct.unpack(">H", reply.read(2))[0]
            packet = b"\x00\x00\x00\x01" + socket.inet_aton("127.0.0.1") + struct.pack(">H", destination)
            marker = uuid.uuid4().bytes
            with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as client:
                client.settimeout(1)
                client.sendto(packet + marker, ("127.0.0.1", relay_port))
                try:
                    return client.recv(1024).endswith(marker)
                except TimeoutError:
                    return False


def verify_chain_route(core, assembled, directory):
    if os.geteuid() == 0:
        raise RuntimeError("Refusing to run a network fixture as root")
    directory.mkdir(mode=0o700)
    address = ("127.0.0.1", 0)
    with ExitStack() as stack:
        web = stack.enter_context(listening(http.server.ThreadingHTTPServer(address, Destination)))
        udp = stack.enter_context(listening(socketserver.UDPServer(address, DatagramEcho)))
        egress = stack.enter_context(listening(http.server.ThreadingHTTPServer(address, LoopbackHop)))
        access = stack.enter_context(listening(http.server.ThreadingHTTPServer(address, LoopbackHop)))
        web.hits = udp.hits = egress.hits = access.hits = 0
        access.blocked = egress.blocked = False
        access.allowed_port, egress.allowed_port = egress.server_port, web.server_port

        groups = {g["name"]: g for g in assembled["proxy-groups"]}
        # Keep the rendered GLOBAL membership, outbound dialer and terminal rules.
        # Replace the physical WARP hop, remote TLS and LAN exemptions for this lab.
        imported = next(node for node in assembled["proxies"] if node["type"] == "http")
        outbound = {**imported, "server": "127.0.0.1", "port": egress.server_port, "tls": False}
        with socket.socket() as free:
            free.bind(address)
            port = free.getsockname()[1]
        config = {
            "mixed-port": port, "allow-lan": False, "bind-address": "127.0.0.1", "log-level": "error",
            "tun": {"enable": False}, "dns": {"enable": False}, "profile": {"store-selected": False},
            "proxies": [{"name": "Lab Access", "type": "http", "server": "127.0.0.1", "port": access.server_port}, outbound],
            "proxy-groups": [groups["GLOBAL"], {**groups["🚀 节点选择"], "proxies": ["Lab Access"]},
                             {**groups["🔗 链式代理"], "proxies": [outbound["name"]]}],
            "rules": assembled["rules"][-2:],
        }
        curl = ["/usr/bin/curl", "--silent", "--show-error", "--fail", "--max-time", "3", "--noproxy", "",
                "--proxy", f"socks5h://127.0.0.1:{port}", f"http://127.0.0.1:{web.server_port}/"]
        for mode in ["direct", "rule", "global"]:
            config["mode"] = mode
            path = directory / "config.json"
            # mihomo reads this through its YAML parser, which expects UTF-8 group names.
            path.write_text(json.dumps(config, ensure_ascii=False), encoding="utf-8")
            with (directory / (mode + ".log")).open("w") as log:
                child = subprocess.Popen([core, "-d", directory, "-f", path], cwd=directory, env={"PATH": "/usr/bin:/bin"},
                                         stdin=subprocess.DEVNULL, stdout=log, stderr=subprocess.STDOUT)
                try:
                    deadline = time.monotonic() + 6
                    while True:
                        if child.poll() is not None or time.monotonic() >= deadline:
                            raise RuntimeError("Fixture core did not start in " + mode)
                        try:
                            with socket.create_connection(("127.0.0.1", port), timeout=0.1):
                                break
                        except OSError:
                            time.sleep(0.05)
                    before = (access.hits, egress.hits, web.hits, udp.hits)
                    reply = subprocess.run(curl, capture_output=True, timeout=4)
                    hops = 0 if mode == "direct" else 1
                    if reply.stdout != b"controlled destination" or reply.returncode or (access.hits, egress.hits, web.hits) != (
                            before[0] + hops, before[1] + hops, before[2] + 1):
                        raise RuntimeError("Unexpected route through the two TCP hops in " + mode)
                    received = udp_probe(port, udp.server_address[1])
                    if received != (mode == "direct") or udp.hits != before[3] + int(mode == "direct"):
                        raise RuntimeError("Unexpected UDP delivery in " + mode)
                    if mode != "direct":
                        access.blocked = True
                        failed = subprocess.run(curl, capture_output=True, timeout=4)
                        if failed.returncode == 0 or web.hits != before[2] + 1 or egress.hits != before[1] + 1:
                            raise RuntimeError("Unavailable first hop did not block delivery in " + mode)
                        access.blocked = False
                finally:
                    child.terminate()
                    try:
                        child.wait(timeout=4)
                    except subprocess.TimeoutExpired:
                        child.kill()
                        child.wait(timeout=4)
                        raise RuntimeError("Core required forced termination")
