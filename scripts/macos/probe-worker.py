#!/usr/bin/env python3
"""Exercise the real bundled worker over private pipes; no system changes."""
import argparse
import array
import fcntl
import hashlib
import json
import os
from pathlib import Path
import select
import struct
import subprocess
import termios
import time
import uuid


ROOT = Path(__file__).resolve().parents[2]
parser = argparse.ArgumentParser()
parser.add_argument("--binary", type=Path, default=ROOT / "dist/macos/FreeV6.app/Contents/Helpers/freev6-worker")
parser.add_argument("--download-runtime", action="store_true", help="download the pinned native core via production mirror selection")
args = parser.parse_args()
binary = args.binary.resolve(strict=True)
directory = ROOT / "build/worker-probes" / str(uuid.uuid4())
resources = directory / "resources"
resources.mkdir(parents=True)
children = []
checks = []


def launch(suffix="main"):
    child = subprocess.Popen([str(binary), "--data-dir", str(directory / (suffix + "-data")),
                              "--resource-dir", str(resources), "--cache-dir", str(directory / (suffix + "-cache")),
                              "--log-dir", str(directory / (suffix + "-logs"))],
                             stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    children.append(child)
    return child


def read_exact(child, count, timeout=5):
    result = bytearray()
    deadline = time.monotonic() + timeout
    while len(result) < count:
        remaining = deadline - time.monotonic()
        if remaining <= 0 or not select.select([child.stdout], [], [], remaining)[0]:
            raise RuntimeError("worker response timed out")
        data = os.read(child.stdout.fileno(), count - len(result))
        if not data:
            raise RuntimeError("worker closed output before completing response")
        result.extend(data)
    return bytes(result)


def call(child, method, params=None, fragmented=False, timeout=5, progress=None):
    identity = str(uuid.uuid4())
    body = json.dumps({"jsonrpc": "2.0", "id": identity, "method": method, "params": params or {}}).encode()
    frame = struct.pack(">I", len(body)) + body
    if fragmented:
        for byte in frame:
            child.stdin.write(bytes([byte]))
            child.stdin.flush()
    else:
        child.stdin.write(frame)
        child.stdin.flush()
    deadline = time.monotonic() + timeout
    while True:
        size = struct.unpack(">I", read_exact(child, 4, deadline-time.monotonic()))[0]
        assert 0 < size <= 1048576
        response = json.loads(read_exact(child, size, deadline-time.monotonic()))
        if response.get("method") != "$/progress":
            break
        assert response["params"]["requestId"] == identity
        if progress is not None:
            progress.append(response["params"])
    assert response["jsonrpc"] == "2.0" and response["id"] == identity
    assert ("result" in response) != ("error" in response)
    return response


def initialize(child):
    result = call(child, "initialize", {"protocolVersion": 1}, fragmented=True)["result"]
    assert result["protocolVersion"] == 1 and result["platform"] == "darwin"
    assert result["capabilities"] == ["settings.get", "settings.patch", "runtime.status", "runtime.download"]
    return result


def close_parent_pipe(child):
    child.stdin.close()
    assert child.wait(timeout=5) == 0


try:
    child = launch()
    assert call(child, "settings.get")["error"]["code"] == -32001
    handshake = initialize(child)
    resource = call(child, "runtime.status")["result"]
    assert not resource["available"] and resource["architecture"] == handshake["architecture"]
    assert call(child, "runtime.download", {"url": "https://example.com/arbitrary"})["error"]["code"] == -32602
    runtime_progress = []
    if args.download_runtime:
        resource_reply = call(child, "runtime.download", timeout=190, progress=runtime_progress)
        assert "result" in resource_reply, resource_reply
        resource = resource_reply["result"]
        assert resource["available"] and any(p["phase"] == "downloading" for p in runtime_progress)
        assert call(child, "runtime.status", timeout=35)["result"] == resource
        checks.append("production runtime download, pinned archive/binary hashes, architecture and progress")
    defaults = call(child, "settings.get")["result"]
    assert defaults["revision"] == 0 and defaults["settings"]["mode"] == "rule"
    saved = call(child, "settings.patch", {"expectedRevision": 0, "changes": {"mode": "global", "campusCidrs": [" EDU.CN "]}})["result"]
    assert saved["revision"] == 1 and saved["settings"]["campusCidrs"] == ["edu.cn"]
    assert call(child, "settings.patch", {"expectedRevision": 0, "changes": {"mode": "direct"}})["error"]["code"] == -32004
    assert call(child, "settings.patch", {"expectedRevision": 1, "changes": {"hotspotShare": True}})["error"]["code"] == -32602
    checks.append("fragmented handshake, real save, conflict and unsupported field rejection")

    competitor = launch()
    assert competitor.wait(timeout=5) != 0
    assert b"another worker" in competitor.stderr.read()
    assert call(child, "settings.get")["result"] == saved
    checks.append("second worker rejected; first worker remains healthy")
    close_parent_pipe(child)
    child = launch()
    initialize(child)
    assert call(child, "settings.get")["result"] == saved
    close_parent_pipe(child)
    checks.append("parent EOF exits; restart retains saved preferences")

    child = launch("signal")
    initialize(child)
    child.terminate()
    assert child.wait(timeout=5) == 0
    checks.append("SIGTERM cancels worker and releases process")

    child = launch("backpressure")
    initialize(child)
    assert "result" in call(child, "settings.patch", {"expectedRevision": 0,
        "changes": {"blacklist": ["a" * 50 + "%d.example.com" % index for index in range(1800)]}})
    # Stop consuming stdout, fill the worker's bounded output pipeline, then
    # cancel via SIGTERM. The small input burst fits the parent's pipe buffer.
    body = json.dumps({"jsonrpc": "2.0", "id": "first-blocked", "method": "settings.get"}).encode()
    child.stdin.write(struct.pack(">I", len(body)) + body)
    child.stdin.flush()
    response_size = struct.unpack(">I", read_exact(child, 4))[0]
    assert response_size > 65_536
    frames = []
    for index in range(32):
        body = json.dumps({"jsonrpc": "2.0", "id": "blocked-%d" % index, "method": "settings.get"}).encode()
        frames.append(struct.pack(">I", len(body)) + body)
    child.stdin.write(b"".join(frames))
    child.stdin.flush()
    queued = array.array("i", [0])
    previous, stable = -1, 0
    deadline = time.monotonic() + 5
    while stable < 5 and time.monotonic() < deadline:
        fcntl.ioctl(child.stdout.fileno(), termios.FIONREAD, queued, True)
        stable = stable + 1 if queued[0] == previous and previous > 0 else 0
        previous = queued[0]
        time.sleep(0.02)
    assert stable >= 5 and 0 < queued[0] < response_size, (stable, queued[0], response_size)
    backpressure = {"pendingFrameBytes": response_size, "queuedOutputBytes": queued[0]}
    child.terminate()
    assert child.wait(timeout=5) in (0, 1)
    checks.append("SIGTERM exits under output backpressure")

    for name, invalid in [("oversize", struct.pack(">I", 1048577)), ("truncated", b"\x00\x00\x00\x08{")]:
        child = launch(name)
        child.stdin.write(invalid)
        child.stdin.close()
        assert child.wait(timeout=5) != 0
    checks.append("oversized and truncated frames rejected")
    result = {"binary": str(binary), "sha256": hashlib.sha256(binary.read_bytes()).hexdigest(),
              "handshake": handshake, "checks": checks, "backpressure": backpressure,
              "runtime": resource, "runtimeProgress": runtime_progress,
              "allChildrenExited": all(p.poll() is not None for p in children)}
    assert result["allChildrenExited"]
    (directory / "result.json").write_text(json.dumps(result, indent=2) + "\n")
    print(directory / "result.json")
finally:
    for child in children:
        if child.poll() is None:
            child.terminate()
            try:
                child.wait(timeout=3)
            except subprocess.TimeoutExpired:
                child.kill()
                child.wait(timeout=3)
        for stream in (child.stdin, child.stdout, child.stderr):
            if not stream.closed:
                stream.close()
