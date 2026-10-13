#!/usr/bin/env python3
"""Finite synthetic CLI. Never imports a provider SDK or invokes a provider binary."""
import json
import os
import signal
import socket
import subprocess
import sys

config = json.loads(sys.argv[-1])
spec = config["spec"]
role = "tool" if "--proof-child" in sys.argv else "cli"
connection = socket.create_connection(("127.0.0.1", spec["port"]))


def event(name, **values):
    connection.sendall((json.dumps(dict(event=name, role=role, token=spec["token"],
                                       attempt=config["attempt"], **values)) + "\n").encode())


def ignore_term(_signum, _frame):
    event("term_ignored")


signal.signal(signal.SIGTERM, ignore_term)
child = None
if role == "cli":
    child = subprocess.Popen([sys.executable, __file__, "--proof-child", sys.argv[-1]],
                             start_new_session=spec["escape"],
                             stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
event("hello", pid=os.getpid(), ppid=os.getppid(), pgid=os.getpgrp(),
      argv=sys.argv[1:-1], cwd=os.getcwd())
if role == "cli":
    print(json.dumps(dict(type="system", subtype="init",
                          session_id=f"fixture-{config['attempt']}")), flush=True)

try:
    for line in connection.makefile("r"):
        command = json.loads(line)["command"]
        if command == "result" and role == "cli":
            print(json.dumps(dict(type="result", subtype="success", is_error=False,
                                  session_id=f"fixture-{config['attempt']}",
                                  result="fixture answer")), flush=True)
            event("result_written")
        elif command == "effect":
            with open(os.path.join(spec["dir"], role + ".effects"), "a", encoding="utf-8") as output:
                output.write("effect\n")
                output.flush()
                os.fsync(output.fileno())
            event("effect_written")
        elif command == "ack_stop":
            event("stop_acknowledged")  # Intentionally does not stop.
        elif command == "exit":
            event("exiting")
            break
finally:
    if child is not None:
        # The test controls child exit independently. Waiting reaps the child.
        child.wait()
    connection.close()
