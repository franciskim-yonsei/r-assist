#!/usr/bin/env python3
import argparse
import os
import re
import shutil
import subprocess
import sys
from pathlib import Path


def usage() -> str:
    return (
        "Usage:\n"
        "  communicate_with_rstudio_console_with_rpc_low_level.py --code '<R code>' "
        "[--session-dir <dir>] [--id <jsonrpc-id>] [--rpostback-bin <path>] "
        "[--isolate-code 0|1] [--rpc-timeout <seconds>]\n\n"
        "Examples:\n"
        "  communicate_with_rstudio_console_with_rpc_low_level.py --code 'print(\"Hello from codex!\")'\n"
        "  communicate_with_rstudio_console_with_rpc_low_level.py --code 'dput(x, file = \"/tmp/x.txt\")' --id 7\n"
    )


def eprint(msg: str) -> None:
    print(msg, file=sys.stderr)


def extract_state_value(file_path: Path, key: str) -> str:
    if not file_path.exists():
        return ""
    pattern = re.compile(rf'^{re.escape(key)}="(.*)"$')
    try:
        with file_path.open("r", encoding="utf-8", errors="replace") as handle:
            for line in handle:
                line = line.rstrip("\n")
                match = pattern.match(line)
                if match:
                    return match.group(1)
    except OSError:
        return ""
    return ""


def newest_session_dir() -> Path:
    base = Path.home() / ".local/share/rstudio/sessions/active"
    sessions = [p for p in base.glob("session-*") if p.is_dir()]
    if not sessions:
        return Path("")
    sessions.sort(key=lambda p: p.stat().st_mtime, reverse=True)
    return sessions[0]


def escape_code(code: str) -> str:
    code = code.replace("\\", "\\\\")
    code = code.replace('"', '\\"')
    code = code.replace("\n", "\\n")
    return code


def has_timeout_binary() -> bool:
    return shutil.which("timeout") is not None


def read_last_line(path: Path) -> str:
    if not path.exists():
        return ""
    try:
        with path.open("r", encoding="utf-8", errors="replace") as handle:
            lines = handle.read().splitlines()
            return lines[-1] if lines else ""
    except OSError:
        return ""


def run_rpostback(rpostback_bin: str, payload: str, rpc_timeout_seconds: int) -> tuple[int, str]:
    cmd = [rpostback_bin, "--command", "console_input", "--argument", payload]

    if has_timeout_binary():
        wrapped = [
            "timeout",
            "--foreground",
            "--signal=TERM",
            "--kill-after=2",
            f"{rpc_timeout_seconds}s",
        ] + cmd
        proc = subprocess.run(wrapped, capture_output=True, text=True)
        output = (proc.stdout or "") + (proc.stderr or "")
        return proc.returncode, output

    try:
        proc = subprocess.run(
            cmd,
            capture_output=True,
            text=True,
            timeout=rpc_timeout_seconds,
        )
        output = (proc.stdout or "") + (proc.stderr or "")
        return proc.returncode, output
    except subprocess.TimeoutExpired as exc:
        out = (exc.stdout or "") + (exc.stderr or "")
        return 124, out


def session_pid_state(pid: str) -> str:
    if not pid or re.fullmatch(r"\d+", pid) is None:
        return "unknown"
    rc = subprocess.run(["ps", "-p", pid], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL).returncode
    return "alive" if rc == 0 else "dead"


def main() -> int:
    parser = argparse.ArgumentParser(add_help=False)
    parser.add_argument("--code", default="")
    parser.add_argument("--session-dir", default="")
    parser.add_argument("--id", default="1")
    parser.add_argument("--rpostback-bin", default=os.environ.get("RPOSTBACK_BIN", "/usr/lib/rstudio-server/bin/rpostback"))
    parser.add_argument("--isolate-code", default="1")
    parser.add_argument("--rpc-timeout", default=os.environ.get("RPC_TIMEOUT_SECONDS", "12"))
    parser.add_argument("-h", "--help", action="store_true")

    args, unknown = parser.parse_known_args()
    if unknown:
        eprint(f"Unknown argument: {unknown[0]}")
        eprint(usage())
        return 2

    if args.help:
        print(usage(), end="")
        return 0

    code = args.code
    if not code:
        eprint("Missing required --code argument")
        eprint(usage())
        return 2

    if args.isolate_code not in {"0", "1"}:
        eprint(f"Invalid --isolate-code value: {args.isolate_code} (use 0 or 1)")
        eprint(usage())
        return 2

    if re.fullmatch(r"\d+", str(args.rpc_timeout)) is None:
        eprint(f"Invalid --rpc-timeout value: {args.rpc_timeout} (use integer seconds)")
        eprint(usage())
        return 2

    rpc_timeout_seconds = int(args.rpc_timeout)

    if args.isolate_code == "1":
        code = f"local({{\n{code}\n}}, envir = new.env(parent = .GlobalEnv))"

    session_dir = Path(args.session_dir) if args.session_dir else newest_session_dir()
    if not session_dir or not (session_dir / "session-persistent-state").exists():
        eprint("Unable to locate an active RStudio session state file.")
        return 1

    state_file = session_dir / "session-persistent-state"
    cid = extract_state_value(state_file, "active-client-id")
    abend = extract_state_value(state_file, "abend")

    env_file = session_dir / "suspended-session-data/environment_vars"
    env_session_pid = extract_state_value(env_file, "RSTUDIO_SESSION_PID")

    if not cid:
        eprint(f"active-client-id not found in {state_file}")
        return 1

    escaped_code = escape_code(code)
    payload = (
        "{"
        "\"jsonrpc\":\"2.0\","
        "\"method\":\"console_input\","
        f"\"clientId\":\"{cid}\","
        f"\"params\":[\"{escaped_code}\",\"\",0],"
        f"\"id\":{args.id}"
        "}"
    )

    rpostback_log = Path.home() / ".local/share/rstudio/log/rpostback.log"
    before_mtime = ""
    if rpostback_log.exists():
        try:
            before_mtime = str(int(rpostback_log.stat().st_mtime))
        except OSError:
            before_mtime = ""

    rpc_rc, rpc_output = run_rpostback(args.rpostback_bin, payload, rpc_timeout_seconds)

    if rpc_output:
        print(rpc_output, end="" if rpc_output.endswith("\n") else "\n")

    if rpc_rc in {124, 137}:
        pid_state = session_pid_state(env_session_pid)
        eprint(f"rpostback timed out after {rpc_timeout_seconds}s.")
        eprint(
            "Session metadata: "
            f"dir={session_dir} "
            f"abend={abend or '<missing>'} "
            f"active-client-id={cid} "
            f"env-session-pid={env_session_pid or '<missing>'} ({pid_state})"
        )
        if abend == "1" or pid_state == "dead":
            eprint(
                "Hint: session snapshot metadata may be stale. Prefer live runtime env vars "
                "(RSTUDIO_SESSION_STREAM/RS_PORT_TOKEN) over suspended-session-data values."
            )
        return 1

    if '"error"' in rpc_output:
        eprint("JSON-RPC error returned for console_input.")
        return 1

    if '"result"' in rpc_output:
        return 0

    last_log = ""
    if rpostback_log.exists():
        after_mtime = ""
        try:
            after_mtime = str(int(rpostback_log.stat().st_mtime))
        except OSError:
            after_mtime = ""

        if after_mtime and (not before_mtime or after_mtime != before_mtime):
            last_log = read_last_line(rpostback_log)

    if last_log:
        eprint(f"rpostback failed (rc={rpc_rc}): {last_log}")
        if "Operation not permitted" in last_log:
            eprint("Hint: run this command outside sandbox / with elevated permissions so it can access the local rsession socket.")

    if rpc_rc != 0:
        eprint("Hint: if this call ran in sandbox, rerun the same single-segment command with escalation; sandbox postback access is a known failure mode.")
        eprint("Hint: stale snapshot env vars can break auth; avoid overriding live RStudio env vars when they are already present.")

    eprint(f"rpostback did not return a JSON-RPC result (rc={rpc_rc}).")
    return 1


if __name__ == "__main__":
    sys.exit(main())
