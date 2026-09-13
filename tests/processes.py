"""Exercise TERM, stubborn processes and zombies using real local children."""
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import time

root = Path(__file__).resolve().parent.parent
with tempfile.TemporaryDirectory() as temp:
    runtime = Path(temp) / "runtime"
    env = dict(os.environ, AMNEZIA_PROXY_RUNTIME_DIR=str(runtime),
               AMNEZIA_PROXY_STATE_DIR=temp + "/state", AMNEZIA_PROXY_CACHE_DIR=temp + "/cache")

    def shell(code, pid):
        return subprocess.run(["bash", "-c", 'source bin/amnezia-proxy; init_paths; ' + code,
                               "test", str(pid)], cwd=root, env=env, capture_output=True, timeout=8)

    for stubborn in (False, True):
        ready = Path(temp) / "ready"
        child_code = ("import signal, pathlib, time; "
                      + ("signal.signal(signal.SIGTERM, signal.SIG_IGN); " if stubborn else "")
                      + f"pathlib.Path({str(ready)!r}).touch(); time.sleep(60)")
        child = subprocess.Popen([sys.executable, "-c", child_code, "3proxy", str(runtime / "3proxy.cfg")])
        try:
            deadline = time.monotonic() + 3
            while not ready.exists():
                if time.monotonic() > deadline:
                    raise AssertionError("child startup timed out")
                time.sleep(0.01)
            result = shell('write_process_record "$PID_FILE" "$1"; stop_proxy', child.pid)
            if stubborn:
                assert result.returncode != 0, "stubborn process reported stopped"
                assert (runtime / "3proxy.pid").exists(), "PID lost after timeout"
                assert child.poll() is None, "unexpected force-kill"
            else:
                assert result.returncode == 0, result.stderr.decode()
                assert not (runtime / "3proxy.pid").exists(), "PID left after TERM"
                assert child.wait(timeout=1) == -15, "TERM not delivered"
        finally:
            if child.poll() is None:
                child.kill()
            child.wait()
            ready.unlink(missing_ok=True)
            (runtime / "3proxy.pid").unlink(missing_ok=True)

    # The Python parent deliberately delays wait(), leaving an observable zombie.
    child = subprocess.Popen(["true"])
    try:
        deadline = time.monotonic() + 3
        while Path(f"/proc/{child.pid}/stat").read_text().rsplit(") ", 1)[1].split()[0] != "Z":
            if time.monotonic() > deadline:
                raise AssertionError("zombie did not appear")
            time.sleep(0.01)
        result = shell('write_process_record "$PID_FILE" "$1"; stop_proxy', child.pid)
        assert result.returncode == 0, result.stderr.decode()
        assert not (runtime / "3proxy.pid").exists(), "zombie blocked cleanup"
    finally:
        child.wait()
print("OK: real TERM, timeout preservation and zombie cleanup passed")
