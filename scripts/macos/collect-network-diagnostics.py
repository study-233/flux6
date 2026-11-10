#!/usr/bin/env python3
"""Offline, read-only observer for an already installed FreeV6 connection attempt.

Does not start services, read credentials, or change proxy/DNS/routes. While a
new tunnel exists, optionally repeats the product's fixed HTTPS check as the
logged-in user. Those results are explicitly separate from the root probe.
"""
import argparse
import concurrent.futures
import ctypes
import datetime
import json
import os
from pathlib import Path
import re
import signal
import socket
import subprocess
import threading
import time

TARGET = "https://www.gstatic.com/generate_204"
ZONE = datetime.timezone(datetime.timedelta(hours=8))


def now():
    return datetime.datetime.now(ZONE).isoformat(timespec="milliseconds")


def command(argv, timeout=12):
    started = now()
    try:
        result = subprocess.run(argv, capture_output=True, text=True, timeout=timeout)
        return dict(started=started, finished=now(), exit=result.returncode,
                    stdout=result.stdout[:65536], stderr=result.stderr[:4096])
    except (OSError, subprocess.TimeoutExpired) as error:
        return dict(started=started, finished=now(), error=type(error).__name__)


class Children:
    def __init__(self):
        self.lib = ctypes.CDLL("/usr/lib/libproc.dylib")
        self.lib.proc_listchildpids.argtypes = [ctypes.c_int, ctypes.c_void_p, ctypes.c_int]
        self.lib.proc_listchildpids.restype = ctypes.c_int
        self.lib.proc_pidpath.argtypes = [ctypes.c_int, ctypes.c_void_p, ctypes.c_uint32]
        self.lib.proc_pidpath.restype = ctypes.c_int

    def read(self, parent):
        pids = (ctypes.c_int * 256)()
        count = self.lib.proc_listchildpids(parent, pids, ctypes.sizeof(pids))
        values = {}
        for pid in list(pids)[:max(0, count) // ctypes.sizeof(ctypes.c_int)]:
            if pid <= 0:
                continue
            path = ctypes.create_string_buffer(4096)
            if self.lib.proc_pidpath(pid, path, len(path)) > 0:
                values[pid] = path.value.decode(errors="replace")
        return values


class Collector:
    def __init__(self, output, duration, probes=True, core_logs=False):
        self.output, self.duration, self.probes = output, duration, probes
        self.output.mkdir(parents=True, mode=0o700)
        self.lock = threading.Lock()
        self.stop = threading.Event()
        self.pool = concurrent.futures.ThreadPoolExecutor(max_workers=6)
        self.jobs = []
        self.started = datetime.datetime.now().strftime("%Y-%m-%d %H:%M:%S")
        self.start_epoch = time.time()
        self.service = None
        self.seen = set()
        self.attempts = 0
        self.children = Children()
        self.core_logs = core_logs
        self.core_process = None
        self.core_reader = None

    def start_core_logs(self):
        helper = Path(__file__).with_name('collect-core-network-diagnostics.py').resolve()
        ready = threading.Event()
        self.core_process = subprocess.Popen(
            ['/usr/bin/sudo', '-n', '/usr/bin/python3', str(helper), '--duration', str(self.duration)],
            stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)

        def read():
            for line in self.core_process.stdout:
                try:
                    event = json.loads(line)
                    self.record('core_observation', event=event)
                    if event.get('kind') == 'core_observer_ready':
                        ready.set()
                        print('核心日志采集已就绪（只读）。', flush=True)
                except ValueError:
                    self.record('core_observer_message', message=line[:1024])
        self.core_reader = threading.Thread(target=read, daemon=True)
        self.core_reader.start()
        if not ready.wait(timeout=4):
            self.core_process.stdin.close()
            self.record('core_observer_not_ready')
            raise RuntimeError('核心日志采集没有启动，请重新运行“FreeV6核心离线诊断.command”并完成本机管理员授权；暂时不需要测试连接。')

    def record(self, kind, **data):
        row = dict(time=now(), kind=kind, **data)
        with self.lock:
            with (self.output / "events.jsonl").open("a") as stream:
                stream.write(json.dumps(row, ensure_ascii=False) + "\n")

    def submit(self, function, *args):
        self.jobs.append(self.pool.submit(function, *args))

    def discover_service(self):
        result = command(["/bin/launchctl", "print", "system/dev.freev6.network-service"], 3)
        match = re.search(r"^\s*pid = (\d+)$", result.get("stdout", ""), re.M)
        pid = int(match[1]) if match else None
        if pid != self.service:
            self.service = pid
            self.record("service", pid=pid, status=result)

    def snapshot(self, reason, interfaces):
        self.record("network_snapshot", reason=reason, interfaces=sorted(interfaces),
                    proxy=command(["/usr/sbin/scutil", "--proxy"]),
                    dns=command(["/usr/sbin/scutil", "--dns"]),
                    ipv4=command(["/usr/sbin/netstat", "-rn", "-f", "inet"]),
                    ipv6=command(["/usr/sbin/netstat", "-rn", "-f", "inet6"]))

    def probe(self, added):
        # Wait for the product's DNS transaction; a probe before that point is
        # not comparable with its egress check. Never hold a tunnel open.
        deadline = time.monotonic() + 3
        ready = False
        while time.monotonic() < deadline and not self.stop.is_set():
            if not added.issubset(set(socket.if_nameindex())):
                self.record("probe_skipped", reason="tunnel removed before DNS became ready")
                return
            dns = command(["/usr/sbin/scutil", "--dns"], 2)
            if re.search(r"nameserver\[\d+\]\s*:\s*127\.0\.0\.1", dns.get("stdout", "")):
                ready = True
                break
            time.sleep(.02)
        if not ready:
            self.record("probe_skipped", reason="no loopback DNS observed on the new tunnel")
            return
        before = sorted(socket.if_nameindex())
        self.record("user_probe_started", interfaces=before, dns=dns)
        result = command([
            "/usr/bin/curl", "--disable", "--noproxy", "*", "--silent", "--show-error",
            "--proto", "=https", "--max-time", "8", "--connect-timeout", "4",
            "--max-filesize", "1024", "--output", "/dev/null", "--write-out",
            "%{http_code} %{remote_ip} dns=%{time_namelookup} tcp=%{time_connect} "
            "tls=%{time_appconnect} total=%{time_total}", TARGET])
        after = sorted(socket.if_nameindex())
        fields = result.get("stdout", "").split()
        route = None
        if len(fields) >= 2:
            peer = fields[1]
            for family, flag in [(socket.AF_INET, "-inet"), (socket.AF_INET6, "-inet6")]:
                try:
                    socket.inet_pton(family, peer)
                except OSError:
                    continue
                route = command(["/sbin/route", "-n", "get", flag, peer], 3)
                break
        still_present = added.issubset(set(socket.if_nameindex()))
        self.record("user_probe_result", result=result, interfaces_before=before,
                    interfaces_after=after, peer_route=route,
                    tunnel_present_through_route=still_present,
                    note="Independent logged-in-user probe, not the root service curl result")
        print("已记录一次独立 HTTPS 检查；继续保留 FreeV6 的错误提示即可。", flush=True)

    def journal(self):
        root = Path.home() / "Library/Logs/dev.freev6.desktop/journal-v1"
        rows = []
        for file in root.glob("*.events.json"):
            try:
                for event in json.loads(file.read_text()):
                    epoch = event["date"] + 978307200
                    if epoch >= self.start_epoch - 60:
                        rows.append(dict(time=datetime.datetime.fromtimestamp(epoch, ZONE).isoformat(),
                                         source=file.stem, event=event["event"]))
            except (OSError, ValueError, KeyError, TypeError):
                self.record("journal_read_failed", file=file.name)
        self.record("application_events", events=sorted(rows, key=lambda row: row["time"]))

    def run(self):
        self.record("started", uid=os.geteuid(), duration=self.duration, endpoint=TARGET,
                    behavior="Read-only observation; independent HTTPS probe only after a new tunnel and loopback DNS")
        previous = set(socket.if_nameindex())
        baseline = previous.copy()
        self.snapshot("before", previous)
        self.discover_service()
        if self.core_logs:
            self.start_core_logs()
        print("\n采集已开始，可以断开聊天代理后测试 FreeV6。", flush=True)
        print("测试出现错误后，恢复原代理，再回这里按回车结束采集。", flush=True)
        print(f"最多记录 {self.duration // 60} 分钟。结果目录：{self.output}\n", flush=True)

        def keyboard():
            try:
                input()
                self.stop.set()
            except EOFError:
                pass
        if os.isatty(0):
            threading.Thread(target=keyboard, daemon=True).start()
        deadline, discover_at = time.monotonic() + self.duration, time.monotonic() + 2
        active_children = {}
        while not self.stop.is_set() and time.monotonic() < deadline:
            current = set(socket.if_nameindex())
            if current != previous:
                added = {item for item in current - previous if item[1].startswith("utun")}
                self.record("interfaces_changed", interfaces=sorted(current), added=sorted(current - previous),
                            removed=sorted(previous - current))
                self.submit(self.snapshot, "interface change", current)
                if added:
                    self.attempts += 1
                    print(f"观察到新隧道（第 {self.attempts} 次），正在记录。", flush=True)
                    if self.probes:
                        self.submit(self.probe, added)
                previous = current
            if time.monotonic() >= discover_at:
                self.discover_service()
                discover_at = time.monotonic() + 2
            children = self.children.read(self.service) if self.service else {}
            for pid, path in children.items():
                if pid not in self.seen and path in ("/usr/bin/curl", "/sbin/route"):
                    self.seen.add(pid)
                    self.record("service_child_started", pid=pid, parent=self.service, executable=path,
                                interfaces=sorted(current))
            for pid, path in active_children.items():
                if pid not in children and path in ("/usr/bin/curl", "/sbin/route"):
                    self.record("service_child_finished", pid=pid, executable=path,
                                note="Exit code is not available to this observer")
            active_children = children
            self.stop.wait(.002 if current - baseline else .04)

        self.stop.set()
        if self.core_process:
            self.core_process.stdin.close()
            try:
                self.core_process.wait(timeout=6)
                self.core_reader.join(timeout=1)
                self.record('core_observer_exit', exit=self.core_process.returncode)
            except subprocess.TimeoutExpired:
                self.record('core_observer_exit_pending', note='helper has its own bounded deadline')
        self.pool.shutdown(wait=True)
        for job in self.jobs:
            try:
                job.result()
            except Exception as error:
                self.record("collector_job_failed", error=type(error).__name__)
        self.journal()
        self.snapshot("after", set(socket.if_nameindex()))
        predicate = ('process == "dev.freev6.network-service" OR '
                     '(process == "launchd" AND eventMessage CONTAINS "freev6") OR '
                     '(process == "configd" AND (eventMessage CONTAINS "utun" OR '
                     'eventMessage CONTAINS "DNS configuration updated"))')
        if self.seen:
            predicate += " OR " + " OR ".join(f"processIdentifier == {pid}" for pid in sorted(self.seen))
        result = command(["/usr/bin/log", "show", "--start", self.started,
                          "--style", "compact", "--info", "--predicate", predicate], 30)
        (self.output / "system.log").write_text(result.get("stdout", "") + result.get("stderr", ""))
        self.record("finished", attempts=self.attempts, system_log_exit=result.get("exit"))
        (self.output / "READ-ME.txt").write_text(
            f"FreeV6 offline capture: {self.output}\n"
            "events.jsonl: timeline, routes/DNS, product curl/route lifecycle, independent HTTPS result.\n"
            "system.log: narrowly filtered system events.\n"
            "No credentials/configuration contents are collected. No settings or services are changed.\n"
            "Independent probe results must be interpreted against the tunnel lifetime.\n"
            "The observer cannot read the root curl exit status. Seeing a root route subprocess means\n"
            "the current product code passed curl exit=0, HTTP 204 and peer-address parsing.\n")
        print(f"\n采集完成：{self.output}\n恢复代理后，在聊天中告诉我‘采集完成’即可。", flush=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--duration", type=int, default=900)
    parser.add_argument("--no-probes", action="store_true")
    parser.add_argument("--core-logs", action="store_true", help="read root core logs using a previously authorized sudo session")
    parser.add_argument("--output", type=Path)
    args = parser.parse_args()
    if not 1 <= args.duration <= 1800:
        parser.error("duration must be between 1 and 1800 seconds")
    os.umask(0o077)
    root = Path(__file__).resolve().parents[2]
    output = args.output or root / "build/http-diagnosis" / datetime.datetime.now(ZONE).strftime("offline-%Y%m%d-%H%M%S")
    collector = Collector(output, args.duration, not args.no_probes, args.core_logs)
    for sig in (signal.SIGINT, signal.SIGTERM):
        signal.signal(sig, lambda *_: collector.stop.set())
    collector.run()


if __name__ == "__main__":
    main()
