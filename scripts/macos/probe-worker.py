#!/usr/bin/env python3
"""Exercise the real bundled worker over private pipes; no system changes."""
import argparse
import array
import fcntl
import hashlib
import json
import os
from pathlib import Path
import struct
import subprocess
import termios
import time
import uuid


from worker_probe import call, read_exact

ROOT = Path(__file__).resolve().parents[2]
parser = argparse.ArgumentParser()
parser.add_argument("--binary", type=Path, default=ROOT / "dist/macos/Flux6.app/Contents/Helpers/freev6-worker")
parser.add_argument("--download-runtime", action="store_true", help="download the pinned native core via production mirror selection")
parser.add_argument("--prepare-geodata", action="store_true", help="download the pinned geodata set via production preparation")
parser.add_argument("--refresh-notice", action="store_true", help="fetch the public maintainer bulletin using the packaged worker")
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


def initialize(child):
    result = call(child, "initialize", {"protocolVersion": 1}, fragmented=True)["result"]
    assert result["protocolVersion"] == 1 and result["platform"] == "darwin"
    assert result["capabilities"] == ["settings.get", "settings.patch", "runtime.status", "runtime.download", "warp.register", "geodata.status", "geodata.prepare", "configuration.prepare", "traffic.get", "traffic.observe",
                                      "chain.preview", "chain.commit", "chain.enable", "chain.clear", "notice.status", "notice.refresh",
                                      "cloud.preview", "cloud.commit", "cloud.portal", "cloud.enable", "cloud.clear"]
    return result


def close_parent_pipe(child):
    child.stdin.close()
    assert child.wait(timeout=5) == 0


try:
    child = launch()
    assert call(child, "settings.get")["error"]["code"] == -32001
    handshake = initialize(child)
    initial_notice = call(child, "notice.status")["result"]
    assert initial_notice == {"source": "unavailable", "cloudAllowed": False, "items": []}
    assert call(child, "notice.refresh", {"url": "https://example.com/arbitrary"})["error"]["code"] == -32602
    checks.append("empty bulletin cache keeps campus profiles closed; custom bulletin origins rejected")
    notice_summary = None
    if args.refresh_notice:
        live = call(child, "notice.refresh", timeout=35)["result"]
        assert live["source"] == "online", "public bulletin unavailable via the configured routes"
        cached = call(child, "notice.status")["result"]
        assert cached == {**live, "source": "cache"}
        notice_summary = {"itemCount": len(live["items"]), "cloudAllowed": live["cloudAllowed"],
                          "fetchedAt": live["fetchedAt"]}
        checks.append("published bulletin fetched and reloaded from private cache")
    resource = call(child, "runtime.status")["result"]
    assert not resource["available"] and resource["architecture"] == handshake["architecture"]
    assert call(child, "runtime.download", {"url": "https://example.com/arbitrary"})["error"]["code"] == -32602
    assert call(child, "warp.register", {"name": "test", "url": "https://example.com/arbitrary"})["error"]["code"] == -32602
    geodata = call(child, "geodata.status")["result"]
    assert not geodata["available"] and len(geodata["files"]) == 3
    assert call(child, "geodata.prepare", {"url": "https://example.com/arbitrary"})["error"]["code"] == -32602
    assert call(child, "configuration.prepare", {"path": "/tmp/arbitrary"})["error"]["code"] == -32602
    device = json.loads((ROOT / "shared/fixtures/warp-credential.json").read_text())["device"]
    assert call(child, "configuration.prepare", {"source": "warp", "settingsRevision": 0,
        "credentialRevision": str(uuid.uuid4()), "tunnel": {k: device[k] for k in ("privateKey", "peerPublicKey", "ipv4", "ipv6")}})["error"]["code"] == -32006
    checks.append("configuration preparation rejects arbitrary paths and missing resources")
    runtime_progress = []
    geodata_progress = []
    if args.prepare_geodata:
        reply = call(child, "geodata.prepare", timeout=190, progress=geodata_progress)
        assert "result" in reply, reply
        geodata = reply["result"]
        assert geodata["available"] and all(f["available"] for f in geodata["files"])
        assert any(p["phase"] == "downloading" for p in geodata_progress)
        assert call(child, "geodata.status", timeout=35)["result"] == geodata
        catalog = json.loads((ROOT / "internal/mihomo/geodata-assets.json").read_text())
        assert geodata["revision"] == catalog["revision"]
        for asset in catalog["assets"]:
            path = directory / "main-cache/geodata" / catalog["revision"] / asset["name"]
            assert path.stat().st_size == asset["size"]
            assert hashlib.sha256(path.read_bytes()).hexdigest() == asset["sha256"]
        checks.append("production geodata preparation, complete pinned set, independent digests and progress")
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
              "geodata": geodata, "geodataProgress": geodata_progress, "notice": notice_summary,
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
