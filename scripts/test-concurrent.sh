#!/bin/zsh
set -eu
cd "${0:A:h}/.."
python3 - <<'PY'
import os
import signal
import subprocess
import sys
import tempfile

def descendants(root):
    rows = subprocess.check_output(["ps", "-axo", "pid=,ppid="], text=True)
    pairs = [tuple(map(int, line.split())) for line in rows.splitlines() if len(line.split()) == 2]
    found = []
    frontier = {root}
    while frontier:
        children = {pid for pid, parent in pairs if parent in frontier and pid not in found}
        found.extend(children)
        frontier = children
    return found

def stop(pid, sig):
    try:
        os.kill(pid, sig)
    except ProcessLookupError:
        pass

env = os.environ.copy()
env["VOLTRA_CONCURRENT_TAP_TEST"] = "1"
subprocess.run(["swift", "build", "--build-tests"], env=env, check=True)
with tempfile.TemporaryDirectory(prefix="voltra-concurrent-") as temp:
    env["VOLTRA_TEST_TMPDIR"] = temp
    process = subprocess.Popen(["swift", "test", "--skip-build", "--filter", "ConcurrentTapIntegrationTests"], env=env, start_new_session=True)
    try:
        result = process.wait(timeout=45)
    except subprocess.TimeoutExpired:
        print("Concurrent audio test timed out; stopping the test processes.", flush=True)
        children = descendants(process.pid)
        for pid in reversed(children):
            stop(pid, signal.SIGTERM)
        stop(process.pid, signal.SIGTERM)
        try:
            process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            stop(process.pid, signal.SIGKILL)
            process.wait()
        for pid in reversed(children):
            stop(pid, signal.SIGKILL)
        result = 124
sys.exit(result)
PY
