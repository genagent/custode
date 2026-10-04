#!/usr/bin/env python3
"""Synthetic CLI protocol fixture. No actual provider or paid model is used."""
import json
import os
from pathlib import Path
import re
import shlex
import subprocess
import sys
import time
import uuid

provider = "codex" if "exec" in sys.argv else "claude"
# Every native fixture requires actual EOF; an open port pipe would hang here.
if sys.stdin.read() != "":
    raise SystemExit("Synthetic fixture expected empty stdin")
root = Path.cwd().parent
if "--version" in sys.argv:
    if (root / "version-block").exists():
        (root / "version-started").write_text("ready")
        while (root / "version-block").exists():
            time.sleep(0.01)
    print("synthetic assurance CLI fixture")
    raise SystemExit(0)
if provider == "claude" and not os.environ.get("USER"):
    print("Synthetic fixture requires native account USER environment.", file=sys.stderr)
    raise SystemExit(1)
if provider == "claude" and sys.argv[-2] != "--":
    print("Synthetic fixture requires a prompt terminator.", file=sys.stderr)
    raise SystemExit(1)
root = Path.cwd().parent
with (root / "calls").open("a") as stream:
    stream.write(provider + "\n")
(root / "started").write_text(str(os.getpid()))
while (root / "block").exists():
    time.sleep(0.01)
prompt = sys.argv[-1]
session = "synthetic-" + str(uuid.uuid4())
if provider == "claude":
    Path("submission.py").write_text("from baseline import baseline_add\n\ndef sum_pair(a, b):\n    return baseline_add(a, b)\n")
    events = [{"type": "system", "subtype": "init", "session_id": session, "model": "synthetic-claude-model"},
              {"type": "result", "subtype": "success", "is_error": False, "session_id": session, "result": "Synthetic implementation fixture."}]
else:
    command = re.search(r"Run this exact command once: (.+)\.\n", prompt).group(1)
    observed = subprocess.run(command, shell=True, capture_output=True, text=True)
    mode = (root / "mode").read_text().strip() if (root / "mode").exists() else "direct"
    emitted = command
    if mode == "single":
        emitted = "/bin/zsh -lc " + shlex.quote(command)
    if mode == "double":
        emitted = "/bin/zsh -lc " + json.dumps(command)
    output = observed.stdout
    if mode == "warning":
        output = "git: warning: confstr() failed with code 5: couldn't get path of DARWIN_USER_TEMP_DIR; using /tmp instead\n" + output
    if mode == "ambiguous-json":
        output = output + output
    if mode == "unknown-diagnostic":
        output = "Unexpected check failure diagnostic\n" + output
    if mode == "forged-output":
        payload = json.loads(output)
        payload["artifact_revision"] = "f" * 40
        output = json.dumps(payload)
    if mode == "bad-row":
        payload = json.loads(output)
        payload["checks"] = [7] * 10
        payload["passed"] = False
        output = json.dumps(payload)
        observed.returncode = 1
    if mode == "outside-cwd":
        emitted = "python3 -B verify.py"
    case = re.search(r"case_revision=([0-9a-f]{64})", prompt).group(1)
    artifact = re.search(r"artifact_revision=([0-9a-f]{40})", prompt).group(1)
    opinion = {"case_revision": case, "artifact_revision": artifact,
               "verdict": "clean" if observed.returncode == 0 else "findings",
               "findings": [] if observed.returncode == 0 else ["Synthetic fixture observed deterministic failure."]}
    events = [{"type": "thread.started", "thread_id": session}, {"type": "turn.started"},
              {"type": "item.completed", "item": {"type": "command_execution", "id": "check-1", "command": emitted,
                 "aggregated_output": output, "exit_code": observed.returncode, "status": "failed" if observed.returncode != 0 or mode == "failed-zero" else "completed"}},
              {"type": "item.completed", "item": {"type": "agent_message", "id": "opinion-1", "text": json.dumps(opinion)}},
              {"type": "turn.completed", "usage": {"input_tokens": 1, "output_tokens": 1}}]
for event in events:
    print(json.dumps(event), flush=True)
