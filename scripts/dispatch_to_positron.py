#!/usr/bin/env python3
import argparse
import glob
import hashlib
import hmac
import http.client
import json
import os
import re
import socket
import subprocess
import sys
import time
import urllib.parse
import uuid

try:
    import zmq
except ModuleNotFoundError:
    print(
        "dispatch_to_positron.py requires pyzmq for the default python3 interpreter. "
        "Install python3-zmq or pyzmq so python3 can import zmq.",
        file=sys.stderr,
    )
    sys.exit(1)


ARK_PATTERN = re.compile(
    r"^\s*(\d+)\s+(/\S*positron-r/resources/ark/ark)\s+"
    r".*--connection_file\s+(/tmp/registration_r-([a-f0-9]+)\.json)\s+.*--session-mode\s+console\b"
)


def usage() -> str:
    return (
        "Usage:\n"
        "  dispatch_to_positron.py --code '<R code>' [--id <jsonrpc-id>] "
        "[--isolate-code 0|1] [--rpc-timeout <seconds>] [--session-id <id>]\n"
    )


def eprint(msg: str) -> None:
    print(msg, file=sys.stderr)


def _find_active_session(explicit_session_id: str = "") -> tuple[int, str, str]:
    ps = subprocess.check_output(["ps", "-eo", "pid,args"], text=True)
    rows: list[tuple[int, str, str]] = []
    for line in ps.splitlines():
        match = ARK_PATTERN.match(line)
        if not match:
            continue
        pid = int(match.group(1))
        reg_path = match.group(3)
        session_id = f"r-{match.group(4)}"
        if explicit_session_id and session_id != explicit_session_id:
            continue
        rows.append((pid, reg_path, session_id))
    if not rows:
        raise RuntimeError("No active Positron R console kernel found")
    return sorted(rows)[-1]


def _read_json(path: str) -> dict:
    with open(path, "r", encoding="utf-8") as handle:
        return json.load(handle)


def _supervisor_logs() -> list[str]:
    patterns = [
        "/tmp/kallichore-*.log",
        "~/.local/state/positron/logs/*/exthost*/positron.positron-supervisor/Kernel Supervisor.log",
        "~/.positron-server/data/logs/*/exthost*/positron.positron-supervisor/Kernel Supervisor.log",
    ]
    files: list[str] = []
    seen: set[str] = set()
    for pattern in patterns:
        for path in glob.glob(os.path.expanduser(pattern)):
            if path in seen:
                continue
            seen.add(path)
            files.append(path)
    files.sort(key=lambda path: os.path.getmtime(path), reverse=True)
    return files


def _kallichore_connection_file_from_supervisor_log(log_file: str) -> str | None:
    try:
        with open(log_file, "r", encoding="utf-8", errors="ignore") as handle:
            for line in reversed(handle.readlines()):
                match = re.search(r"Generated connection file path:\s+(\S+\.json)\b", line)
                if match:
                    return match.group(1)
                match = re.search(r"Streaming Kallichore server logs (?:from|at)\s+(\S+\.log)\b", line)
                if match:
                    return re.sub(r"\.log$", ".json", match.group(1))
    except FileNotFoundError:
        return None
    return None


def _find_kallichore_connection(session_id: str, reg_path: str) -> dict:
    session_marker = f'Wrote registration file for session {session_id} at "{reg_path}"'
    for log_file in _supervisor_logs():
        try:
            with open(log_file, "r", encoding="utf-8", errors="ignore") as handle:
                for line in reversed(handle.readlines()):
                    if session_marker not in line:
                        continue
                    if log_file.startswith("/tmp/kallichore-") and log_file.endswith(".log"):
                        conn_path = re.sub(r"\.log$", ".json", log_file)
                    else:
                        conn_path = _kallichore_connection_file_from_supervisor_log(log_file)
                    if not conn_path or not os.path.exists(conn_path):
                        continue
                    payload = _read_json(conn_path)
                    if "socket_path" in payload and "bearer_token" in payload:
                        return payload
        except FileNotFoundError:
            continue
    raise RuntimeError(f"No Kallichore connection info found for {session_id}")


class _UnixHTTPConnection(http.client.HTTPConnection):
    def __init__(self, socket_path: str, timeout: float = 4.0):
        super().__init__("localhost", timeout=timeout)
        self._socket_path = socket_path

    def connect(self) -> None:
        self.sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.sock.settimeout(self.timeout)
        self.sock.connect(self._socket_path)


def _find_connection_info(session_id: str, reg_path: str) -> dict:
    server = _find_kallichore_connection(session_id, reg_path)
    socket_path = server.get("socket_path")
    bearer_token = server.get("bearer_token")
    if not socket_path or not bearer_token:
        raise RuntimeError(f"Incomplete Kallichore connection info for {session_id}")

    conn = _UnixHTTPConnection(str(socket_path), timeout=4.0)
    try:
        path = f"/sessions/{urllib.parse.quote(session_id)}/connection_info"
        conn.request("GET", path, headers={"Authorization": f"Bearer {bearer_token}"})
        response = conn.getresponse()
        body = response.read()
    finally:
        conn.close()

    if response.status != 200:
        detail = body.decode("utf-8", errors="replace").strip()
        raise RuntimeError(f"Kallichore returned HTTP {response.status} for {session_id}: {detail}")

    payload = json.loads(body.decode("utf-8"))
    if not isinstance(payload, dict) or "shell_port" not in payload:
        raise RuntimeError(f"Invalid connection_info payload for {session_id}")
    return payload


def _signer(key: str):
    key_bytes = key.encode()

    def sign(parts: list[bytes]) -> bytes:
        digest = hmac.new(key_bytes, digestmod=hashlib.sha256)
        for part in parts:
            digest.update(part)
        return digest.hexdigest().encode()

    return sign


def _build_message(sign, session: str, msg_type: str, content: dict) -> list[bytes]:
    header = {
        "msg_id": uuid.uuid4().hex,
        "username": "codex",
        "session": session,
        "date": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        "msg_type": msg_type,
        "version": "5.3",
    }
    parent = {}
    meta = {}
    frames = [
        json.dumps(header, separators=(",", ":")).encode(),
        json.dumps(parent, separators=(",", ":")).encode(),
        json.dumps(meta, separators=(",", ":")).encode(),
        json.dumps(content, separators=(",", ":")).encode(),
    ]
    return [b"<IDS|MSG>", sign(frames), *frames]


def _parse_message(frames: list[bytes]) -> tuple[dict, dict]:
    marker_index = frames.index(b"<IDS|MSG>")
    return json.loads(frames[marker_index + 2]), json.loads(frames[marker_index + 5])


def _wrap_code(code: str, isolate_code: str) -> str:
    if isolate_code == "0":
        return code
    if isolate_code == "1":
        return f"local({{\n{code}\n}}, envir = new.env(parent = .GlobalEnv))"
    raise RuntimeError(f"Invalid --isolate-code value: {isolate_code} (use 0 or 1)")


def execute_code(code: str, rpc_timeout_seconds: int, explicit_session_id: str = "") -> int:
    _, reg_path, session_id = _find_active_session(explicit_session_id)
    registration = _read_json(reg_path)
    connection_info = _find_connection_info(session_id, reg_path)

    ctx = zmq.Context.instance()
    sock = ctx.socket(zmq.DEALER)
    sock.setsockopt(zmq.LINGER, 0)
    sock.setsockopt(zmq.RCVTIMEO, max(1000, rpc_timeout_seconds * 1000))
    sock.setsockopt(zmq.SNDTIMEO, 1500)
    sock.connect(f"tcp://127.0.0.1:{int(connection_info['shell_port'])}")

    request = {
        "code": code,
        "silent": False,
        "store_history": False,
        "allow_stdin": False,
        "stop_on_error": True,
        "user_expressions": {},
    }
    session = uuid.uuid4().hex
    sign = _signer(registration["key"])

    try:
        sock.send_multipart(_build_message(sign, session, "execute_request", request))
        reply = sock.recv_multipart()
    finally:
        sock.close()

    header, _ = _parse_message(reply)
    if header.get("msg_type") != "execute_reply":
        raise RuntimeError(f"Unexpected reply type: {header.get('msg_type')}")
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(add_help=False)
    parser.add_argument("--code", default="")
    parser.add_argument("--session-id", default="")
    parser.add_argument("--id", default="1")
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

    if not args.code:
        eprint("Missing required --code argument")
        eprint(usage())
        return 2

    if re.fullmatch(r"\d+", str(args.rpc_timeout)) is None:
        eprint(f"Invalid --rpc-timeout value: {args.rpc_timeout} (use integer seconds)")
        eprint(usage())
        return 2

    try:
        return execute_code(
            code=_wrap_code(args.code, args.isolate_code),
            rpc_timeout_seconds=int(args.rpc_timeout),
            explicit_session_id=args.session_id.strip(),
        )
    except Exception as exc:
        eprint(str(exc))
        return 1


if __name__ == "__main__":
    sys.exit(main())
