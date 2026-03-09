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
import sys
import time
import urllib.parse
import uuid
from pathlib import Path

try:
    import zmq
except ModuleNotFoundError:
    print(
        "dispatch_to_positron.py requires pyzmq for the default python3 interpreter. "
        "Install python3-zmq or pyzmq so python3 can import zmq.",
        file=sys.stderr,
    )
    sys.exit(1)


SESSION_MODES = {"console", "notebook"}


def usage() -> str:
    return (
        "Usage:\n"
        "  dispatch_to_positron.py --code '<R code>' [--id <jsonrpc-id>] "
        "[--isolate-code 0|1] [--rpc-timeout <seconds>] "
        "[--session-mode console|notebook] [--session-id <id>] "
        "[--notebook-uri <uri>] [--silent 0|1]\n"
    )


def eprint(msg: str) -> None:
    print(msg, file=sys.stderr)


def _read_json(path: str) -> dict:
    with open(path, "r", encoding="utf-8") as handle:
        return json.load(handle)


def _normalize_notebook_uri(value: str) -> str:
    normalized = value.strip()
    if not normalized:
        return ""
    if re.match(r"^[A-Za-z][A-Za-z0-9+.-]*:", normalized):
        return normalized
    return Path(normalized).expanduser().resolve().as_uri()


def _supervisor_connection_files() -> list[str]:
    files: list[str] = []
    seen: set[str] = set()
    for path in glob.glob("/tmp/kallichore-*.json"):
        if path in seen:
            continue
        seen.add(path)
        files.append(path)
    files.sort(key=lambda item: os.path.getmtime(item), reverse=True)
    return files


class _UnixHTTPConnection(http.client.HTTPConnection):
    def __init__(self, socket_path: str, timeout: float = 4.0):
        super().__init__("localhost", timeout=timeout)
        self._socket_path = socket_path

    def connect(self) -> None:
        self.sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.sock.settimeout(self.timeout)
        self.sock.connect(self._socket_path)


def _list_supervisor_sessions(server: dict) -> list[dict]:
    socket_path = server.get("socket_path")
    bearer_token = server.get("bearer_token")
    if not socket_path or not bearer_token:
        return []

    conn = _UnixHTTPConnection(str(socket_path), timeout=4.0)
    try:
        conn.request("GET", "/sessions", headers={"Authorization": f"Bearer {bearer_token}"})
        response = conn.getresponse()
        body = response.read()
    except OSError:
        return []
    finally:
        try:
            conn.close()
        except OSError:
            pass

    if response.status != 200:
        return []

    try:
        payload = json.loads(body.decode("utf-8"))
    except json.JSONDecodeError:
        return []

    sessions = payload.get("sessions", [])
    if not isinstance(sessions, list):
        return []
    return sessions


def _rank_session(session: dict) -> tuple[int, str]:
    process_id = session.get("process_id")
    try:
        pid_rank = int(process_id)
    except (TypeError, ValueError):
        pid_rank = -1
    started_rank = str(session.get("started") or "")
    return pid_rank, started_rank


def _describe_session(session: dict) -> str:
    session_id = str(session.get("session_id") or "<unknown>")
    session_mode = str(session.get("session_mode") or "<unknown>")
    working_directory = str(session.get("working_directory") or "").strip()
    notebook_uri = str(session.get("notebook_uri") or "").strip()
    started = str(session.get("started") or "").strip()

    parts = [session_id, f"mode={session_mode}"]
    if notebook_uri:
        parts.append(f"notebook={notebook_uri}")
    elif working_directory:
        parts.append(f"cwd={working_directory}")
    if started:
        parts.append(f"started={started}")
    return ", ".join(parts)


def _format_session_candidates(sessions: list[dict]) -> str:
    if not sessions:
        return ""
    ordered = sorted(sessions, key=_rank_session)
    return "\n".join(f"- {_describe_session(session)}" for session in ordered)


def _registration_path_for_session(session_id: str) -> str:
    return f"/tmp/registration_{session_id}.json"


def _find_target_session(
    session_mode: str,
    explicit_session_id: str = "",
    notebook_uri: str = "",
) -> tuple[dict, dict]:
    normalized_uri = _normalize_notebook_uri(notebook_uri)
    candidates: list[tuple[dict, dict]] = []

    for conn_path in _supervisor_connection_files():
        try:
            server = _read_json(conn_path)
        except (FileNotFoundError, json.JSONDecodeError, OSError):
            continue

        for session in _list_supervisor_sessions(server):
            if not isinstance(session, dict):
                continue
            if session.get("language") != "R":
                continue
            if not session.get("connected"):
                continue
            if session.get("session_mode") != session_mode:
                continue
            session_id = str(session.get("session_id") or "").strip()
            if not session_id:
                continue
            reg_path = _registration_path_for_session(session_id)
            if not os.path.exists(reg_path):
                continue
            if explicit_session_id and session_id != explicit_session_id:
                continue
            if normalized_uri:
                candidate_uri = _normalize_notebook_uri(str(session.get("notebook_uri") or ""))
                if candidate_uri != normalized_uri:
                    continue
            candidates.append((server, session))

    if explicit_session_id:
        if not candidates:
            raise RuntimeError(f"No connected Positron R session found for session id {explicit_session_id}")
        return sorted(candidates, key=lambda item: _rank_session(item[1]))[-1]

    if normalized_uri:
        if not candidates:
            raise RuntimeError(f"No connected Positron notebook session found for {normalized_uri}")
        return sorted(candidates, key=lambda item: _rank_session(item[1]))[-1]

    if session_mode == "notebook":
        if not candidates:
            raise RuntimeError("No connected Positron R notebook kernel found")
        if len(candidates) > 1:
            details = _format_session_candidates([session for _, session in candidates])
            raise RuntimeError(
                "Multiple connected Positron notebook kernels found. "
                "Provide --notebook-uri or --session-id.\n"
                f"{details}"
            )
        return candidates[0]

    if not candidates:
        raise RuntimeError("No active Positron R console kernel found")
    if len(candidates) > 1:
        details = _format_session_candidates([session for _, session in candidates])
        raise RuntimeError(
            "Multiple connected Positron R console sessions found. "
            "Provide --session-id.\n"
            f"{details}"
        )
    return candidates[0]


def _find_connection_info(server: dict, session_id: str) -> dict:
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


def execute_code(
    code: str,
    rpc_timeout_seconds: int,
    session_mode: str = "console",
    explicit_session_id: str = "",
    notebook_uri: str = "",
    silent: bool = False,
) -> int:
    server, session = _find_target_session(
        session_mode=session_mode,
        explicit_session_id=explicit_session_id,
        notebook_uri=notebook_uri,
    )
    session_id = str(session["session_id"])
    reg_path = _registration_path_for_session(session_id)
    registration = _read_json(reg_path)
    connection_info = _find_connection_info(server, session_id)

    ctx = zmq.Context.instance()
    sock = ctx.socket(zmq.DEALER)
    sock.setsockopt(zmq.LINGER, 0)
    sock.setsockopt(zmq.RCVTIMEO, max(1000, rpc_timeout_seconds * 1000))
    sock.setsockopt(zmq.SNDTIMEO, 1500)
    sock.connect(f"tcp://127.0.0.1:{int(connection_info['shell_port'])}")

    request = {
        "code": code,
        "silent": bool(silent),
        "store_history": False,
        "allow_stdin": False,
        "stop_on_error": True,
        "user_expressions": {},
    }
    session_uuid = uuid.uuid4().hex
    sign = _signer(registration["key"])

    try:
        sock.send_multipart(_build_message(sign, session_uuid, "execute_request", request))
        reply = sock.recv_multipart()
    finally:
        sock.close()

    header, content = _parse_message(reply)
    if header.get("msg_type") != "execute_reply":
        raise RuntimeError(f"Unexpected reply type: {header.get('msg_type')}")
    if content.get("status") != "ok":
        raise RuntimeError(str(content))
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(add_help=False)
    parser.add_argument("--code", default="")
    parser.add_argument("--session-mode", default="console")
    parser.add_argument("--session-id", default="")
    parser.add_argument("--notebook-uri", default="")
    parser.add_argument("--id", default="1")
    parser.add_argument("--isolate-code", default="1")
    parser.add_argument("--silent", default="0")
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

    if args.session_mode not in SESSION_MODES:
        eprint(f"Invalid --session-mode value: {args.session_mode} (use console or notebook)")
        eprint(usage())
        return 2

    if re.fullmatch(r"\d+", str(args.rpc_timeout)) is None:
        eprint(f"Invalid --rpc-timeout value: {args.rpc_timeout} (use integer seconds)")
        eprint(usage())
        return 2

    if args.silent not in {"0", "1"}:
        eprint(f"Invalid --silent value: {args.silent} (use 0 or 1)")
        eprint(usage())
        return 2

    try:
        return execute_code(
            code=_wrap_code(args.code, args.isolate_code),
            rpc_timeout_seconds=int(args.rpc_timeout),
            session_mode=args.session_mode.strip(),
            explicit_session_id=args.session_id.strip(),
            notebook_uri=args.notebook_uri.strip(),
            silent=args.silent == "1",
        )
    except Exception as exc:
        eprint(str(exc))
        return 1


if __name__ == "__main__":
    sys.exit(main())
