#!/usr/bin/env python3
"""Exercise the debug service in an isolated, temporary user launchd job.

No root installation, network changes or persistent login item. Each run binds
the copied probe's signed identity, verifies both peer directions, and boots the
job out in a finally block. A rejection counts only between successful calls.
"""
import argparse
import base64
import copy
import datetime
import hashlib
import http.server
import threading
import json
import os
from pathlib import Path
import plistlib
import platform
import re
import shutil
import subprocess
import time
import uuid

from chain_route_probe import verify_chain_route
from worker_probe import call as worker_call
from session_probe import isolated_network, state, until

ROOT = Path(__file__).resolve().parents[2]


def run(args, *, check=True, timeout=30):
    result = subprocess.run([str(arg) for arg in args], text=True, capture_output=True, timeout=timeout)
    if check and result.returncode:
        raise RuntimeError(f"{Path(str(args[0])).name} failed ({result.returncode}): {result.stderr.strip()}")
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--no-build", action="store_true", help="Use the current debug build")
    parser.add_argument("--runtime-fixtures", type=Path, help="Exercise resource FD transfer with pinned official files")
    parser.add_argument("--geodata-fixtures", type=Path)
    parser.add_argument("--chain-worker", type=Path, help="Check an imported subscription from the real worker through XPC and the pinned core")
    parser.add_argument("--network-run", action="store_true", help="Verify session RPC and supervisor using isolated DNS and a TUN-free core")
    args = parser.parse_args()
    if (args.network_run or args.chain_worker) and not args.runtime_fixtures:
        parser.error("Session and chain tests need the runtime and geodata fixtures")
    if bool(args.runtime_fixtures) != bool(args.geodata_fixtures):
        parser.error("Supply both runtime and geodata fixtures")
    if os.geteuid() == 0:
        raise RuntimeError("This probe must run as the logged-in user, never as root")
    if not args.no_build:
        run(["bash", ROOT / "scripts/macos/swift.sh", "build"], timeout=180)
    binaries = Path(run(["bash", ROOT / "scripts/macos/swift.sh", "build", "--show-bin-path"]).stdout.strip())
    work = ROOT / "build/service-probes" / str(uuid.uuid4())
    work.mkdir(parents=True, mode=0o700)
    os.chmod(work, 0o700)
    # Keep sessions/<UUID>/c.sock within Darwin's 104-byte sun_path.
    data_root = ROOT / "build" / ("n-" + uuid.uuid4().hex[:8])
    data_root.mkdir(mode=0o755)
    fixture_dns = isolated_network(data_root) if args.network_run else None
    probe = work / "freev6-probe"
    service = work / "freev6-network-service"
    untrusted = work / "untrusted-probe"
    upgraded = work / "upgraded-probe"
    for source, destination, identifier in [
        (binaries / "freev6-probe", probe, "dev.freev6.probe.client"),
        (binaries / "freev6-network-service", service, "dev.freev6.probe.service"),
        (binaries / "freev6-probe", untrusted, "dev.freev6.probe.untrusted"),
    ]:
        shutil.copy2(source, destination)
        run(["/usr/bin/codesign", "--force", "--sign", "-", "--options", "runtime", "--identifier", identifier, destination])
        run(["/usr/bin/codesign", "--verify", "--strict", destination])

    # Adding an empty entitlement section changes the CodeDirectory while
    # retaining the same identifier and runtime protection, without extra powers.
    shutil.copy2(probe, upgraded)
    empty_entitlements = work / "empty.entitlements"
    empty_entitlements.write_bytes(plistlib.dumps({}))
    run(["/usr/bin/codesign", "--force", "--sign", "-", "--options", "runtime", "--identifier",
         "dev.freev6.probe.client", "--entitlements", empty_entitlements, upgraded])
    run(["/usr/bin/codesign", "--verify", "--strict", upgraded])

    registration = json.loads(run([probe, "registration", service]).stdout)
    service_hash = registration["service"]["cdHash"]
    record = data_root / "registration.json"

    def write_record(value):
        record.write_text(json.dumps(value))
        os.chmod(record, 0o600)

    write_record(registration)
    label = "dev.freev6.probe." + str(uuid.uuid4())
    domain = f"gui/{os.getuid()}"
    target = f"{domain}/{label}"
    job = work / "service.plist"
    job.write_bytes(plistlib.dumps({
        "Label": label,
        "ProgramArguments": [str(service), "--probe-run" if args.network_run else "--probe", label, str(record)],
        "MachServices": {label: True},
        "ThrottleInterval": 1,
        "AbandonProcessGroup": False,
        "StandardOutPath": str(work / "service.stdout"),
        "StandardErrorPath": str(work / "service.stderr"),
    }))
    cases = []

    def handshake(executable=probe, expected_hash=service_hash, rejected=False):
        result = run([executable, "mach", label, expected_hash], check=False, timeout=15)
        if rejected:
            if result.returncode != 1 or "NSCocoaErrorDomain" not in result.stderr or "timed out" in result.stderr:
                raise RuntimeError(f"Expected explicit XPC rejection, got {result.returncode}: {result.stdout} {result.stderr}")
        elif result.returncode or "privileged=false" not in result.stdout:
            raise RuntimeError(f"Trusted handshake failed: {result.stdout} {result.stderr}")

    def case(name):
        cases.append(name)
        print(f"PASS: {name}", flush=True)

    def process_id():
        output = run(["/bin/launchctl", "print", target]).stdout
        match = re.search(r"\bpid = (\d+)", output)
        if not match:
            raise RuntimeError("Service has no running process")
        return int(match.group(1))

    def resources():
        return json.loads(run([probe, "resources", label, service_hash], timeout=40).stdout)

    def resource_cases():
        runtime = json.loads((ROOT / "internal/mihomo/runtime-assets.json").read_text())
        geo = json.loads((ROOT / "internal/mihomo/geodata-assets.json").read_text())
        arch = {"arm64": "arm64", "x86_64": "amd64"}[platform.machine()]
        core = next(a for a in runtime["assets"] if a["os"] == "darwin" and a["arch"] == arch)
        core_id = f"mihomo-darwin-{arch}-{runtime['version']}"
        assets = [(core_id, args.runtime_fixtures / core["archive"], core_id, core["binarySha256"])]
        for a in geo["assets"]:
            group = "geodata-" + geo["revision"]
            assets.append((group + "/" + a["name"], args.geodata_fixtures / a["name"], group + "-" + a["name"], a["sha256"]))
        if any(a["available"] for a in resources()):
            raise RuntimeError("Fresh service unexpectedly has resources")
        request = {
            "protocolVersion": 6, "requestID": str(uuid.uuid4()), "settingsRevision": 1,
            "credentialRevision": str(uuid.uuid4()), "runtimeID": core_id,
            "geodataID": "geodata-" + geo["revision"],
            "configuration": json.loads((ROOT / "shared/fixtures/warp-business-configuration.json").read_text()),
        }
        request_file = work / "configuration-request.json"
        request_file.write_text(json.dumps(request))
        absent = run([probe, "check-configuration", label, service_hash, request_file], check=False)
        if absent.returncode != 1 or "固定摘要" not in absent.stderr:
            raise RuntimeError("Service accepted configuration before its resources were installed")
        cache = work / "client-cache"
        cached_core = cache / "runtime" / core["sha256"] / core["archive"]
        cached_core.parent.mkdir(parents=True, mode=0o700)
        shutil.copyfile(args.runtime_fixtures / core["archive"], cached_core)
        cached_core.chmod(0o600)
        cached_geo = cache / "geodata" / geo["revision"]
        cached_geo.mkdir(parents=True, mode=0o700)
        for a in geo["assets"]:
            destination = cached_geo / a["name"]
            shutil.copyfile(args.geodata_fixtures / a["name"], destination)
            destination.chmod(0o600)
        prepared = json.loads(run([probe, "prepare-configuration", label, service_hash, cache, request_file], timeout=150).stdout)
        expected_keys = {"protocolVersion", "requestID", "policyVersion", "settingsRevision", "credentialRevision", "mode", "proxyCount", "ruleCount", "coreValidated"}
        if set(prepared) != expected_keys or prepared["requestID"].lower() != request["requestID"].lower() or prepared["proxyCount"] != 28:
            raise RuntimeError("Unexpected configuration acknowledgement")
        if prepared["protocolVersion"] != 6 or prepared["coreValidated"] is not True:
            raise RuntimeError("Service did not confirm actual core validation")
        if (data_root / "network-session.json").exists() or list((data_root / "sessions").iterdir()):
            raise RuntimeError("Successful core check left private session files")
        original = json.loads(json.dumps(request))
        for key, value in [("external-controller", "0.0.0.0:9090"), ("tun", {"enable": False}), ("secret", "rejected-secret-marker")]:
            bad = json.loads(json.dumps(original)); bad["configuration"][key] = value
            request_file.write_text(json.dumps(bad))
            rejected = run([probe, "check-configuration", label, service_hash, request_file], check=False)
            if rejected.returncode != 1 or "字段无效" not in rejected.stderr or "rejected-secret-marker" in rejected.stderr:
                raise RuntimeError("System configuration injection not rejected safely")
        request_file.write_text(json.dumps(original))
        result = json.loads(run([probe, "check-configuration", label, service_hash, request_file]).stdout)
        if result["settingsRevision"] != original["settingsRevision"]:
            raise RuntimeError("Configuration revision mismatch")
        core_config = work / "core-config"
        core_config.mkdir(mode=0o700)
        run([probe, "assemble-configuration", request_file, core_config / "config.json"])
        for a in geo["assets"]:
            shutil.copyfile(data_root / "resources" / ("geodata-" + geo["revision"] + "-" + a["name"]), core_config / a["name"])
        check = run([data_root / "resources" / core_id, "-t", "-d", core_config, "-f", core_config / "config.json"])
        (work / "core-check.log").write_text(check.stdout + check.stderr)
        case("App resource transfer and service configuration validation succeed; system-field injection rejected; assembled policy passes real core -t")
        if args.chain_worker:
            key = base64.b64encode(os.urandom(32)).decode()
            device = json.loads((ROOT / "shared/fixtures/warp-credential.json").read_text())["device"]
            worker_resources = work / "worker-resources"
            worker_resources.mkdir(mode=0o700)
            with subprocess.Popen([args.chain_worker.resolve(), "--data-dir", work / "worker-data", "--cache-dir", cache,
                                   "--resource-dir", worker_resources, "--log-dir", work / "worker-logs"],
                                  stdin=subprocess.PIPE, stdout=subprocess.PIPE) as child:
                try:
                    worker_call(child, "initialize", {"protocolVersion": 1})
                    imported = worker_call(child, "chain.preview", {"expectedRevision": 0, "key": key,
                        "file": str(ROOT / "shared/fixtures/chain-proxies.yaml")})["result"]
                    saved = worker_call(child, "chain.commit", {"expectedRevision": 0, "token": imported["token"]})["result"]
                    chain = worker_call(child, "configuration.prepare", {"source": "warp", "settingsRevision": saved["revision"],
                        "chainKey": key, "credentialRevision": original["credentialRevision"],
                        "tunnel": {k: device[k] for k in ("privateKey", "peerPublicKey", "ipv4", "ipv6")}}, timeout=40)["result"]
                    notice_record = {"fetchedAt": datetime.datetime.now(datetime.timezone.utc).isoformat(), "items": [], "cloudProfile": True}
                    (work / "worker-data" / "maintainer-notice.json").write_text(json.dumps(notice_record))
                    disabled = worker_call(child, "chain.enable", {"expectedRevision": saved["revision"], "enabled": False})["result"]
                    draft = worker_call(child, "cloud.preview", {"expectedRevision": disabled["revision"], "key": key,
                        "source": "file", "value": str(ROOT / "shared/fixtures/chain-proxies.yaml")})["result"]
                    campus_saved = worker_call(child, "cloud.commit", {"expectedRevision": disabled["revision"], "token": draft["token"]})["result"]
                    campus = worker_call(child, "configuration.prepare", {"source": "cloud", "settingsRevision": campus_saved["revision"],
                        "profileKey": key, "credentialRevision": campus_saved["cloud"]["id"]}, timeout=40)["result"]
                finally:
                    child.stdin.close()
                    child.wait(timeout=10)
            chain_request = {**original, "requestID": str(uuid.uuid4()), "settingsRevision": chain["settingsRevision"],
                             "configuration": chain["configuration"]}
            chain_file = work / "chain-request.json"
            chain_file.write_text(json.dumps(chain_request))
            checked = json.loads(run([probe, "check-configuration", label, service_hash, chain_file], timeout=60).stdout)
            if checked["coreValidated"] is not True or checked["proxyCount"] != 34:
                raise RuntimeError("Service did not validate all imported protocol families")
            run([probe, "assemble-configuration", chain_file, core_config / "chain.json"])
            run([data_root / "resources" / core_id, "-t", "-d", core_config, "-f", core_config / "chain.json"])
            case("real worker imports six proxy types; native service validates chain policy and pinned core parses the assembled configuration")
            for mutation in ("plugin", "local-path", "dialer", "global", "access", "missing-udp", "early-udp"):
                bad = copy.deepcopy(chain_request)
                bad["requestID"] = str(uuid.uuid4())
                config = bad["configuration"]
                groups = {g["name"]: g for g in config["proxy-groups"]}
                node = config["proxies"][-1]
                if mutation == "plugin":
                    node["plugin"] = "rejected-secret-marker"
                elif mutation == "local-path":
                    node["certificate"] = "/tmp/rejected-secret-marker"
                elif mutation == "dialer":
                    node["dialer-proxy"] = "DIRECT"
                elif mutation == "global":
                    groups["GLOBAL"]["proxies"] = ["🚀 节点选择"]
                elif mutation == "access":
                    groups["☑️ 手动切换"]["proxies"][0] = node["name"]
                elif mutation == "missing-udp":
                    config["rules"].pop()
                else:
                    config["rules"].insert(0, "NETWORK,UDP,DIRECT")
                request_file.write_text(json.dumps(bad))
                rejected = run([probe, "check-configuration", label, service_hash, request_file], check=False)
                if rejected.returncode != 1 or "字段无效" not in rejected.stderr or "rejected-secret-marker" in rejected.stderr:
                    raise RuntimeError("Service did not reject unsafe chain configuration: " + mutation)
            request_file.write_text(json.dumps(original))
            case("service independently rejects seven modified chains including unsafe fields, bypasses and missing or injected UDP rules")
            verify_chain_route(data_root / "resources" / core_id, chain["configuration"], work / "chain-route")
            case("loopback two-hop TCP follows the imported HTTP dialer in rule and global modes; failed access and unsupported UDP never reach the direct destination")
            campus_request = {**original, "requestID": str(uuid.uuid4()), "settingsRevision": campus["settingsRevision"],
                              "credentialRevision": campus["credentialRevision"], "profileSource": "cloud",
                              "configuration": campus["configuration"]}
            campus_file = work / "campus-request.json"
            for edit in ("source", "dialer", "privileged-field", "direct-group", "udp"):
                bad = copy.deepcopy(campus_request)
                config = bad["configuration"]
                if edit == "source":
                    bad.pop("profileSource")
                elif edit == "dialer":
                    config["proxies"][0]["dialer-proxy"] = "DIRECT"
                elif edit == "privileged-field":
                    config["proxies"][0]["interface-name"] = "en0"
                elif edit == "direct-group":
                    next(g for g in config["proxy-groups"] if g["name"] == "GLOBAL")["proxies"] = ["DIRECT"]
                else:
                    config["rules"].pop()
                campus_file.write_text(json.dumps(bad))
                rejected = run([probe, "check-configuration", label, service_hash, campus_file], check=False)
                if rejected.returncode != 1 or "字段无效" not in rejected.stderr:
                    raise RuntimeError("Service accepted altered campus configuration: " + edit)
            campus_file.write_text(json.dumps(campus_request))
            checked = json.loads(run([probe, "check-configuration", label, service_hash, campus_file], timeout=60).stdout)
            if not checked["coreValidated"] or checked["proxyCount"] != 6:
                raise RuntimeError("Campus configuration failed the pinned core check")
            case("backup profile without WARP credentials passes service/core validation; five altered campus requests are refused")
            verify_chain_route(data_root / "resources" / core_id, campus["configuration"], work / "campus-route", campus=True)
            case("campus route uses one proxy in rule and global modes; failed egress and unsupported UDP do not bypass it")
        for resource_id, source, destination, digest in assets:
            incoming = work / "incoming"
            shutil.copyfile(source, incoming)
            incoming.chmod(0o600)
            output = run([probe, "install-resource", label, service_hash, resource_id, incoming], timeout=40)
            if not next(a["available"] for a in json.loads(output.stdout) if a["id"] == resource_id):
                raise RuntimeError("Installed resource not available")
            stored = data_root / "resources" / destination
            if hashlib.sha256(stored.read_bytes()).hexdigest() != digest:
                raise RuntimeError("Private resource digest mismatch")
            if stored.stat().st_mode & 0o777 != (0o500 if resource_id == core_id else 0o400):
                raise RuntimeError("Private resource permissions mismatch")
            incoming.write_bytes(b"corrupt replacement")
            rejected = run([probe, "install-resource", label, service_hash, resource_id, incoming], check=False, timeout=40)
            if rejected.returncode != 1 or "固定摘要" not in rejected.stderr:
                raise RuntimeError("Corrupt resource was not explicitly rejected")
            if hashlib.sha256(stored.read_bytes()).hexdigest() != digest:
                raise RuntimeError("Rejected replacement changed existing resource")
        if not all(a["available"] for a in resources()):
            raise RuntimeError("Complete resource set unavailable")
        source = work / "incoming"
        unknown = run([probe, "install-resource", label, service_hash, "../../unapproved", source], check=False)
        if unknown.returncode != 1 or "可信清单" not in unknown.stderr:
            raise RuntimeError("Unknown resource/path was not rejected")
        denied = run([untrusted, "install-resource", label, service_hash, core_id, source], check=False)
        if denied.returncode != 1 or "NSCocoaErrorDomain" not in denied.stderr:
            raise RuntimeError("Unregistered resource client was not rejected")
        if any(p.name.startswith(".staging-") for p in (data_root / "resources").iterdir()):
            raise RuntimeError("Resource staging files remained")
        source.unlink()
        stored_names = {p.name for p in (data_root / "resources").iterdir()}
        if stored_names != {a[2] for a in assets} | {"resources.lock"}:
            raise RuntimeError("Unexpected file written by service configuration check")
        # A ready service can reuse its verified assets after user cache removal.
        shutil.rmtree(cache)
        run([probe, "prepare-configuration", label, service_hash, cache, request_file], timeout=45)
        case("real XPC file descriptors install pinned core/geodata; corrupt, unknown and unregistered requests rejected")

    def network_cases():
        request = work / "configuration-request.json"
        def rpc(action, *values, reject=False, client=probe):
            result = run([client, "session-" + action, label, service_hash, *values], check=False, timeout=60)
            if reject:
                if result.returncode != 1:
                    raise RuntimeError(f"Expected {action} rejection")
                return
            if result.returncode:
                raise RuntimeError(f"{action}: {result.stderr}")
            return json.loads(result.stdout)
        def start():
            idle = rpc("status")
            assert idle["phase"] == "stopped" and fixture_dns() is None
            active = rpc("start", idle["idleToken"], request)
            assert active["phase"] == "running" and fixture_dns()["ServerPort"] == 1053
            return idle["idleToken"], active["sessionID"], active["revision"]
        def stopped():
            # A mutation racing the timer may return busy. Read the journal
            # first, then require a confirmed idle RPC and restored fixture.
            if (data_root / "network-session.json").exists():
                return False
            return rpc("status")["phase"] == "stopped" and fixture_dns() is None
        if args.chain_worker:
            campus_file = work / "campus-request.json"
            campus = json.loads(campus_file.read_text())
            active = rpc("start", rpc("status")["idleToken"], campus_file)
            if (active["phase"] != "running" or active["credentialRevision"].lower() != campus["credentialRevision"].lower()
                    or active["settingsRevision"] != campus["settingsRevision"]):
                raise RuntimeError("Campus session did not bind the saved profile version")
            assert rpc("stop", active["sessionID"], active["revision"])["phase"] == "stopped"
            assert stopped()
            case("authenticated campus session starts with its profile UUID and no WARP credential, then restores fixture DNS")
        run([probe, "desktop-session", label, service_hash, request], timeout=90)
        assert stopped()
        case("native desktop starts, changes mode and both node groups, rejects stale controls, measures REJECT, samples traffic and quits through authenticated XPC")
        _, session, revision = start()
        with subprocess.Popen([probe, "session-slow-delay", label, service_hash, session, str(revision)],
                              stdout=subprocess.PIPE, stderr=subprocess.PIPE) as pending:
            try:
                if not delay_started.wait(timeout=5) or pending.poll() is not None:
                    raise RuntimeError("Slow measurement never reached the controlled loopback proxy")
                stop_started = time.monotonic()
                confirmed = rpc("stop", session, revision)
                stop_seconds = time.monotonic() - stop_started
                # The core delay deadline is five seconds. A stop queued behind
                # the measurement cannot pass while the proxy withholds its reply.
                if stop_seconds >= 4 or confirmed["phase"] != "stopped" or fixture_dns() is not None:
                    raise RuntimeError("Stop waited for a slow measurement or left DNS active")
                _, replacement, next_revision = start()
                output, _ = pending.communicate(timeout=10)
                if pending.returncode != 1 or output or replacement == session:
                    raise RuntimeError("An obsolete measurement succeeded after disconnect")
                rpc("slow-delay", session, revision, reject=True)
                assert rpc("status", replacement)["phase"] == "running"
                assert rpc("stop", replacement, next_revision)["phase"] == "stopped"
            finally:
                if pending.poll() is None:
                    pending.kill()
                pending.wait(timeout=5)
        case(f"slow core measurement in flight: stopped and restored fixture DNS in {stop_seconds:.2f}s; new session rejected old requests")
        token, session, revision = start()
        rpc("status", client=untrusted, reject=True)
        assert rpc("status", session)["phase"] == "running"
        rpc("start", token, request, reject=True)
        rpc("stop", session, revision - 1, reject=True)
        rpc("stop", uuid.uuid4(), revision, reject=True)
        assert rpc("status", session)["sessionID"] == session
        assert rpc("stop", session, revision)["phase"] == "stopped"
        assert rpc("stop", session, revision)["phase"] == "stopped"
        rpc("start", token, request, reject=True)
        case("XPC start, owner heartbeat, stale/replayed requests, signature rejection and idempotent stop")
        _, session, revision = start()
        block = data_root / "block-dns-recovery"
        block.touch()
        rpc("stop", session, revision, reject=True)
        pending = rpc("status")
        assert pending["phase"] == "recoveryRequired" and pending["revision"] > revision
        core_label = "dev.freev6.core." + session.lower()
        assert state(core_label)["pid"] and fixture_dns()["ServerPort"] == 1053
        block.unlink()
        until(stopped)
        assert state(core_label) is None
        case("supervisor retains core on rollback failure and retries until system state is restored")
        _, session, _ = start()
        core_label = "dev.freev6.core." + session.lower()
        run(["/bin/launchctl", "kill", "SIGKILL", domain + "/" + core_label])
        until(stopped)
        assert state(core_label) is None
        case("supervisor restores DNS when the running core alone crashes")
        _, session, _ = start()
        run(["/bin/launchctl", "kickstart", "-k", target])
        handshake()
        until(stopped)
        assert state("dev.freev6.core." + session.lower()) is None
        case("restarted XPC daemon independently restores an active client session")
        _, session, _ = start()
        time.sleep(18)
        assert rpc("status", session)["phase"] == "running"
        time.sleep(15)
        assert rpc("status")["phase"] == "running"
        # Observing the current state without its session ID does not renew.
        assert rpc("status", uuid.uuid4())["phase"] == "running"
        until(stopped, timeout=24)
        assert state("dev.freev6.core." + session.lower()) is None
        case("matching heartbeat extends the owner lease; disappearance expires it and restores DNS")

    health_server = None
    delay_started = threading.Event()
    if args.network_run:
        class HealthHandler(http.server.BaseHTTPRequestHandler):
            def do_CONNECT(self):
                if self.path != "www.gstatic.com:80":
                    self.send_error(403)
                    return
                # Hold the CONNECT handshake until the core closes the socket.
                # This server never connects to the named host.
                delay_started.set()
                self.connection.settimeout(8)
                try:
                    self.connection.recv(1)
                except OSError:
                    pass

            def do_GET(self):
                self.send_response(204)
                self.end_headers()

            do_HEAD = do_GET

            def log_message(self, *args):
                pass

        health_server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), HealthHandler)
        options = data_root / "probe-options.json"
        fields = json.loads(options.read_bytes())
        fields["healthPort"] = health_server.server_port
        options.write_text(json.dumps(fields))
        threading.Thread(target=health_server.serve_forever, daemon=True).start()
    installed = False
    try:
        run(["/bin/launchctl", "bootstrap", domain, job])
        installed = True
        handshake()
        case("registered client and service mutually authenticate")
        if args.runtime_fixtures:
            resource_cases()
        if args.network_run:
            network_cases()
        handshake(untrusted, rejected=True)
        handshake()
        case("different client CDHash rejected; trusted client remains usable")
        handshake(expected_hash="0" * 40, rejected=True)
        handshake()
        case("client rejects unexpected service CDHash")
        previous_pid = process_id()
        stale = None
        if args.runtime_fixtures:
            stale = data_root / "resources" / (".staging-" + str(uuid.uuid4()))
            stale.write_bytes(b"interrupted transfer fixture")
            stale.chmod(0o600)
        run(["/bin/launchctl", "kickstart", "-k", target])
        handshake()
        if process_id() == previous_pid:
            raise RuntimeError("Service did not restart")
        case("launchd restart preserves registered identity")
        if args.runtime_fixtures:
            if not all(a["available"] for a in resources()):
                raise RuntimeError("Resources failed verification after service restart")
            if stale.exists():
                raise RuntimeError("Interrupted private staging was not cleaned")
            case("private resources independently verified and interrupted staging cleaned after launchd restart")
        wrong_user = json.loads(json.dumps(registration))
        wrong_user["clients"][0]["uid"] = os.getuid() + 1
        write_record(wrong_user)
        run(["/bin/launchctl", "kickstart", "-k", target])
        handshake(rejected=True)
        write_record(registration)
        run(["/bin/launchctl", "kickstart", "-k", target])
        handshake()
        case("registered identity is bound to its UID")
        renewed = json.loads(run([upgraded, "registration", service]).stdout)
        old_identity = registration["clients"][0]["identity"]
        new_identity = renewed["clients"][0]["identity"]
        if old_identity["identifier"] != new_identity["identifier"] or old_identity["cdHash"] == new_identity["cdHash"]:
            raise RuntimeError("Expected same identifier with a different CodeDirectory hash")
        handshake(upgraded, rejected=True)
        write_record(renewed)
        run(["/bin/launchctl", "kickstart", "-k", target])
        handshake(upgraded)
        handshake(probe, rejected=True)
        handshake(upgraded)
        case("client hash rotation requires re-enrollment and revokes the old hash")
    finally:
        if health_server:
            health_server.shutdown()
            health_server.server_close()
        if installed:
            run(["/bin/launchctl", "bootout", target])
            if run(["/bin/launchctl", "print", target], check=False).returncode == 0:
                raise RuntimeError("Probe job remained registered after cleanup")
            if args.network_run and (data_root / "network-session.json").exists():
                interrupted = json.loads((data_root / "network-session.json").read_text())
                session_id = uuid.UUID(interrupted["sessionID"])
                core_label = "dev.freev6.core." + str(session_id)
                if state(core_label):
                    run(["/bin/launchctl", "bootout", domain + "/" + core_label])
            case("temporary launchd job removed")

    shutil.move(data_root, work / "service-data")
    report = {
        "timestamp": datetime.datetime.now(datetime.timezone.utc).isoformat(),
        "scope": "user-domain debug Mach service; no root installation or network changes",
        "registration": registration,
        "cases": cases,
    }
    (work / "result.json").write_text(json.dumps(report, indent=2) + "\n")
    print(f"Evidence: {work / 'result.json'}")


if __name__ == "__main__":
    main()
