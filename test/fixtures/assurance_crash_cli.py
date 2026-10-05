#!/usr/bin/env python3
"""Synthetic initialization only; no provider or model calls."""
import json
import sys
import time
if "--version" in sys.argv:
    print("synthetic-crash-cli-v1")
    raise SystemExit(0)
provider = "codex" if "exec" in sys.argv else "claude"
event = ({"type": "thread.started", "thread_id": "synthetic-crash-session"}
         if provider == "codex" else
         {"type": "system", "subtype": "init", "session_id": "synthetic-crash-session", "model": "synthetic-model"})
print(json.dumps(event), flush=True)
# The independent controller must observe and inject the crash; never fake a terminal.
time.sleep(60)
