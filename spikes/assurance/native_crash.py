"""Opt-in external controller. Signals only privately observed descendant identities.
Never equates observed cleanup with all-descendant settlement or releases a reservation.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import signal
import subprocess
import time

LIMIT = 512_000


def write(path, value):
    path.write_text(json.dumps(value, indent=2) + "\n")
    path.chmod(0o600)


def snapshot():
    # No argv or environment: env -i arguments can contain API credentials.
    output = subprocess.check_output(["ps", "-axo", "pid=,ppid=,lstart=,comm="], timeout=3)
    rows = {}
    for line in output.decode(errors="replace").splitlines():
        fields = line.split(maxsplit=7)
        if len(fields) == 8:
            pid, parent = int(fields[0]), int(fields[1])
            rows[pid] = {"pid": pid, "parent": parent, "started": " ".join(fields[2:7]),
                         "image": fields[7]}
    return rows


def descendants(root, rows):
    found = {root} if root in rows else set()
    while True:
        new = {pid for pid, row in rows.items() if row["parent"] in found} - found
        if not new:
            return found
        found |= new


def same(identity, row):
    return row is not None and all(identity[key] == row[key] for key in ["pid", "started", "image"])


def signal_owned(identity, action, observed):
    if observed.get(identity["pid"]) != identity:
        raise ValueError("unobserved identity refused")
    current = snapshot().get(identity["pid"])
    if not same(identity, current):
        return False
    try:
        os.kill(identity["pid"], action)
        return True
    except ProcessLookupError:
        return False


def initialized(provider, raw):
    events = []
    for line in raw.splitlines():
        try:
            event = json.loads(line)
        except (ValueError, UnicodeDecodeError):
            continue
        if isinstance(event, dict):
            events.append(event)
    terminals = ({"result"} if provider == "claude" else {"turn.completed", "turn.failed", "error"})
    if any(event.get("type") in terminals for event in events):
        raise ValueError("native terminal preceded injected crash")
    key = "session_id" if provider == "claude" else "thread_id"
    relevant = [e for e in events if e.get("type") == "system" and e.get("subtype") == "init"] if provider == "claude" else [e for e in events if e.get("type") == "thread.started"]
    identities = {e.get(key) for e in relevant if isinstance(e.get(key), str) and e.get(key)}
    if len(identities) > 1:
        raise ValueError("conflicting native initialization identities")
    if not identities:
        return None
    return {"session_id": identities.pop(), "model": relevant[0].get("model")}


def writer(path, host, rows):
    owned = descendants(host, rows) - {host}
    candidates = []
    for pid in owned:
        proc = subprocess.run(["lsof", "-a", "-p", str(pid), "-d", "1", "-Fn"],
                              capture_output=True, timeout=3)
        names = [line[1:] for line in proc.stdout.decode(errors="replace").splitlines() if line.startswith("n")]
        if str(path) in names:
            candidates.append(pid)
    if not candidates:
        return None
    # The deepest writer is the native engine when a wrapper retains fd 1.
    leaves = [pid for pid in candidates if not (descendants(pid, rows) - {pid}) & set(candidates)]
    if len(leaves) != 1:
        raise ValueError("ambiguous native stdout writer")
    return rows[leaves[0]]


def read_bounded(path):
    with path.open("rb") as stream:
        raw = stream.read(LIMIT + 1)
    if len(raw) > LIMIT:
        raise ValueError("native capture bound exceeded")
    return raw


def observe(directory, process, deadline, provider, observed):
    while time.monotonic() < deadline:
        rows = snapshot()
        for pid in descendants(process.pid, rows):
            old = observed.get(pid)
            if old is not None and old["started"] != rows[pid]["started"]:
                raise ValueError("controlled process identity changed")
            observed[pid] = rows[pid]
        write(directory / "startup-identities.json", list(observed.values()))
        state = directory / "proof" / "case-state.json"
        if state.is_file():
            context = json.loads(state.read_text())
            host = int(context["host_pid"])
            if host not in descendants(process.pid, rows):
                raise ValueError("recorded host is outside the controlled process")
            for path in directory.glob("custode-verification-*/stdout"):
                if path.is_symlink() or not path.is_file():
                    continue
                raw = read_bounded(path)
                read_bounded(path.with_name("stderr"))
                init = initialized(provider, raw)
                if init:
                    identity = writer(path, host, rows)
                    if identity:
                        return context, rows[host], identity, path, init, rows
        if process.poll() is not None:
            raise ValueError("host ended before observed initialization")
        time.sleep(.02)
    raise TimeoutError("native initialization deadline")


def cleanup(observed):
    # Each identity is revalidated. Reparenting is allowed only for already observed identities.
    for identity in reversed(list(observed.values())):
        signal_owned(identity, signal.SIGKILL, observed)
    deadline = time.monotonic() + 5
    while time.monotonic() < deadline:
        rows = snapshot()
        alive = [row for row in observed.values() if same(row, rows.get(row["pid"]))]
        if not alive:
            return True
        time.sleep(.05)
    return False


def phase_command(args, provider, directory, phase):
    command = ["mix", "custode.assurance.crash_proof", "--root", str(directory / "proof"),
               "--provider", provider, "--phase", phase,
               "--claude-model", args.claude_model, "--codex-model", args.codex_model]
    if args.synthetic:
        command.append("--synthetic")
    return command


def spawn_phase(args, provider, directory, phase):
    env = dict(os.environ, MIX_ENV="test", TMPDIR=str(directory), CUSTODE_TEST_MCP_PORT="6184",
               CUSTODE_NATIVE_CRASH_PROOF="1")
    output = open(directory / (phase + "-host.log"), "xb")
    os.chmod(output.name, 0o600)
    process = subprocess.Popen(phase_command(args, provider, directory, phase), env=env,
                               stdin=subprocess.DEVNULL, stdout=output, stderr=subprocess.STDOUT,
                               start_new_session=True)
    output.close()
    return process


def crash_case(args, provider, directory):
    directory.mkdir(mode=0o700)
    host_process = spawn_phase(args, provider, directory, "worker")
    owned = {}
    try:
        context, host, native, path, init, rows = observe(directory, host_process, time.monotonic() + 60, provider, owned)
        native_branch = descendants(native["pid"], rows)
        # Retain the whole own host tree for failure cleanup, including CLI wrappers.
        owned.update({pid: rows[pid] for pid in descendants(host_process.pid, rows)})
        for pid in native_branch:
            signal_owned(rows[pid], signal.SIGSTOP, owned)
        retained = directory / "native-stdout.jsonl"
        retained.write_bytes(read_bounded(path))
        retained.chmod(0o600)
        write(directory / "observation.json", {"host": host, "native": native, "owned": list(owned.values()),
                                               "init": init, "stdout_path": str(path), "case_id": context["case_id"]})
        target = native if provider == "claude" else host
        if not signal_owned(target, signal.SIGKILL, owned):
            raise ValueError("crash target ended before signal")
        if provider == "claude":
            host_exit = host_process.wait(timeout=10)
            if host_exit != 0:
                raise ValueError("worker crash host did not finish recording")
        else:
            host_process.wait(timeout=10)
        settled = cleanup(owned)
        if not settled:
            raise ValueError("observed process cleanup incomplete")
        owned = {}
        # Native cleanup is not positive settlement. The reservation stays durable.
        time.sleep(32)
        recovery = spawn_phase(args, provider, directory, "recover")
        try:
            code = recovery.wait(timeout=60)
        finally:
            if recovery.poll() is None:
                rows = snapshot()
                cleanup({pid: rows[pid] for pid in descendants(recovery.pid, rows)})
        if code != 0:
            raise ValueError("fresh recovery phase failed")
        recovered = json.loads((directory / "proof" / "recovery-result.json").read_text())
        expected = "incomplete" if provider == "claude" else "running"
        if recovered["native_record"]["status"] != expected or not recovered["passed"]:
            raise ValueError("durable interruption classification or controls failed")
        return {"provider": provider, "failure": "native_worker_killed" if provider == "claude" else "owning_BEAM_killed",
                "initialization_observed": True, "native_status": expected, "recovery": recovered,
                "observed_processes_gone": settled, "all_descendants_attestation": "missing",
                "stdout_sha256": hashlib.sha256(retained.read_bytes()).hexdigest(),
                "native_identity_sha256": hashlib.sha256(json.dumps(native, sort_keys=True).encode()).hexdigest(),
                "native_session_sha256": hashlib.sha256(init["session_id"].encode()).hexdigest()}
    finally:
        if owned:
            cleanup(owned)
        elif host_process.poll() is None:
            rows = snapshot()
            cleanup({pid: rows[pid] for pid in descendants(host_process.pid, rows)})


CONTROL_KEYS = ("replay_preserves_original", "workspace_redelivery_refused", "stale_generation_refused",
                "native_records_unchanged", "one_original_native_record", "missing_success_stays_missing",
                "no_effect_authority", "no_imported_late_evidence")


def public_controls(controls):
    if set(controls) != set(CONTROL_KEYS) or any(type(controls[key]) is not bool for key in CONTROL_KEYS):
        raise ValueError("unexpected recovery controls")
    return {key: controls[key] for key in CONTROL_KEYS}


def projection(private):
    cases = []
    for case in private["cases"]:
        cases.append({key: case[key] for key in ["provider", "failure", "initialization_observed", "native_status",
                      "observed_processes_gone", "all_descendants_attestation", "stdout_sha256",
                      "native_identity_sha256", "native_session_sha256"]} |
                     {"controls": public_controls(case["recovery"]["controls"]), "recovery_model_invocations": 0,
                      "decision": case["recovery"]["decision"]["status"]})
    return {"schema": "custode.native-crash-public.v1", "synthetic": private["synthetic"],
            "source_revision": private["source_revision"], "source_sha256": private["source_sha256"],
            "status": private["status"], "model_launch_requests": private["model_launch_requests"], "cases": cases,
            "limits": ["No positive all-descendant settlement or reservation release.",
                       "No automatic retry, effect authority or human acceptance.",
                       "Initialization establishes a native session, not completed inference or quality.",
                       "Claude configured budget stop is not a billing ceiling; Codex cost unknown."]}


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--root", required=True)
    parser.add_argument("--synthetic", action="store_true")
    parser.add_argument("--claude-model", default="sonnet")
    parser.add_argument("--codex-model", default="gpt-5.5")
    args = parser.parse_args()
    if os.environ.get("CUSTODE_NATIVE_CRASH_PROOF") != "1":
        raise ValueError("explicit crash proof opt-in required")
    root = Path(args.root)
    if not root.is_absolute() or root.exists() or root.is_symlink():
        raise ValueError("fresh absolute root required")
    root.mkdir(parents=True, mode=0o700)
    root.chmod(0o700)
    sources = ["spikes/assurance/native_crash.py", "lib/custode/assurance/native/crash_proof.ex",
               "lib/mix/tasks/custode.assurance.crash_proof.ex", "test/fixtures/assurance_crash_cli.py",
               "lib/custode/assurance/native.ex", "lib/custode/assurance/native/events.ex",
               "lib/custode/verification/runner.ex", "priv/assurance_native/baseline.py",
               "priv/assurance_native/verify.py", "mix.lock"]
    private = {"schema": "custode.native-crash-private.v1", "synthetic": args.synthetic, "status": "incomplete",
               "source_revision": subprocess.check_output(["git", "rev-parse", "HEAD"], text=True).strip(),
               "model_launch_requests": 0, "source_sha256": {name: hashlib.sha256(Path(name).read_bytes()).hexdigest() for name in sources}, "cases": []}
    snapshots = root / "source"
    snapshots.mkdir(mode=0o700)
    for name in sources:
        target = snapshots / name
        target.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
        target.write_bytes(Path(name).read_bytes())
        target.chmod(0o600)
    write(root / "report-private.json", private)
    for provider in ["claude", "codex"]:
        private["model_launch_requests"] += 1
        write(root / "report-private.json", private)
        case = crash_case(args, provider, root / provider)
        private["cases"].append(case)
        write(root / "report-private.json", private)
    private["status"] = "passed"
    write(root / "report-private.json", private)
    write(root / "report-public.json", projection(private))
    print("Two bounded crash controls retained privately; no reservation released.")


if __name__ == "__main__":
    main()
