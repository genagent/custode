#!/usr/bin/env python3
"""A no-LLM CLI with one observable child, used by worker and stream tests."""
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import time

root = Path.cwd()
if (root / "success").exists():
    print(json.dumps({"type": "result", "subtype": "success", "result": "finished", "session_id": "fake-session", "is_error": False}))
    sys.exit(0)

if "--child" in sys.argv:
    time.sleep(2)
    (root / "late-write").write_text("child survived")
    time.sleep(30)
    sys.exit(0)

child = subprocess.Popen([sys.executable, __file__, "--child"])

def stop(_signum, _frame):
    child.terminate()
    child.wait()
    sys.exit(0)

signal.signal(signal.SIGTERM, stop)
(root / "pids").write_text(f"{os.getpid()} {child.pid}")
if (root / "stream").exists():
    while child.poll() is None:
        print(json.dumps({"type": "system", "subtype": "init", "session_id": "fake-session"}), flush=True)
        time.sleep(0.05)
else:
    child.wait()
