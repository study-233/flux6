"""Bounded request/response helpers for private worker probe pipes."""
import json
import os
import select
import struct
import time
import uuid


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
