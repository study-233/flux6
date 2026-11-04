"""Helpers shared by isolated user-domain launchd recovery probes."""
from pathlib import Path
import plistlib
import subprocess
import time
import uuid


def run(args, check=True, timeout=60):
    r = subprocess.run([str(a) for a in args], capture_output=True, text=True, timeout=timeout)
    if check and r.returncode:
        raise RuntimeError(r.stderr)
    return r


def until(test, timeout=30):
    end = time.monotonic() + timeout
    while time.monotonic() < end:
        if result := test():
            return result
        time.sleep(0.03)
    raise RuntimeError("Session probe timed out")


def state(label):
    for line in run(["/bin/launchctl", "list"]).stdout.splitlines()[1:]:
        pid, status, name = line.split(None, 2)
        if name == label:
            return {"pid": None if pid == "-" else int(pid), "exit": int(status)}
    return None


def boot(probe: Path, arguments, *, domain, folder, name, jobs):
    label = "dev.freev6.probe.session." + uuid.uuid4().hex
    path = folder / (name + ".plist")
    path.write_bytes(plistlib.dumps({"Label": label, "ProgramArguments": [str(probe)] + list(map(str, arguments)),
        "RunAtLoad": True, "KeepAlive": False, "AbandonProcessGroup": False, "ExitTimeOut": 2,
        "StandardOutPath": str(folder / (name + ".stdout")), "StandardErrorPath": str(folder / (name + ".stderr"))}))
    jobs.append(label)
    run(["/bin/launchctl", "bootstrap", domain, path])
    return label
