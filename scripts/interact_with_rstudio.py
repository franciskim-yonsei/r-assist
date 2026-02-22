#!/usr/bin/env python3
import os
import re
import shutil
import subprocess
import sys
import tempfile
import time
from dataclasses import dataclass, field
from pathlib import Path
from typing import List, Optional, Tuple


class ValidationError(Exception):
    pass


class SendError(Exception):
    pass


COMMON_BLOCKED_PATTERNS = [
    r"<<-",
    r"->>",
    r"(^|[^A-Za-z0-9_.])(save|saveRDS|load|setwd|options|Sys\.setenv|library|require|attach|detach|sink|system|system2)\s*\(",
    r"(^|[^A-Za-z0-9_.])(q|quit)\s*\(",
]

APPEND_FILE_BLOCKED_PATTERNS = [
    r"(^|[^A-Za-z0-9_.])(write|writeLines|write\.csv|write\.csv2|write\.delim|write\.delim2|write\.table|fwrite|cat|saveRDS|save|load|file\.create|dir\.create|unlink|file\.remove|file\.rename|file\.copy|file\.append|download\.file|png|jpeg|svg|bmp|tiff|pdf|postscript|quartz|x11)\s*\(",
]


@dataclass
class State:
    append_code_snippets: List[str] = field(default_factory=list)
    result_expr: str = ""
    state_export_expr: str = ""
    create_global_specs: List[str] = field(default_factory=list)
    modify_global_snippets: List[str] = field(default_factory=list)

    session_dir: str = ""
    request_id: str = "1"
    rpostback_bin: str = ""
    out_path: str = ""
    timeout_seconds: str = "8"
    rpc_timeout_seconds: str = "12"
    benchmark_mode: bool = False
    benchmark_unit: str = "seconds"
    print_code: bool = False
    capture_output: bool = False

    def clear_capabilities(self) -> None:
        self.append_code_snippets = []
        self.result_expr = ""
        self.state_export_expr = ""
        self.create_global_specs = []
        self.modify_global_snippets = []
        self.benchmark_mode = False


@dataclass
class SendContext:
    expect_result: bool
    out_path: str
    is_temp_out_path: bool
    state_export_path: str
    append_only: bool


def trim(value: str) -> str:
    return value.strip()


def contains_regex(value: str, regex: str) -> bool:
    return re.search(regex, value, re.IGNORECASE | re.MULTILINE) is not None


def escape_for_r_string(value: str) -> str:
    value = value.replace("\\", "\\\\")
    value = value.replace('"', r'\"')
    value = value.replace("\n", r"\n")
    return value


def join_lines(lines: List[str]) -> str:
    if not lines:
        return ""
    return "\n".join(lines) + "\n"


def indent_block(text: str, indent: str) -> str:
    if not text:
        return ""
    return "".join(f"{indent}{line}\n" for line in text.rstrip("\n").split("\n"))


def validate_common_blocklist(code: str, label: str) -> None:
    for regex in COMMON_BLOCKED_PATTERNS:
        if contains_regex(code, regex):
            raise ValidationError(f"{label} contains blocked pattern ({regex}).")

    if contains_regex(code, r"(^|[^A-Za-z0-9_.])source\s*\("):
        if not contains_regex(code, r"source\s*\([^)]*local\s*="):
            raise ValidationError(f"{label} uses source(...) without local= explicitly set.")
        if contains_regex(code, r"source\s*\([^)]*local\s*=\s*FALSE"):
            raise ValidationError(f"{label} uses source(..., local = FALSE), which is not allowed.")


def validate_append_file_restrictions(code: str) -> None:
    for regex in APPEND_FILE_BLOCKED_PATTERNS:
        if contains_regex(code, regex):
            raise ValidationError("APPEND_CODE may not write files.")


def validate_assignment_free(code: str, label: str) -> None:
    if contains_regex(code, r"<-"):
        raise ValidationError(f"{label} cannot contain '<-' assignment.")
    if contains_regex(code, r"->"):
        raise ValidationError(f"{label} cannot contain right-arrow assignment.")


def validate_identifier(value: str, label: str) -> None:
    if re.fullmatch(r"[A-Za-z.][A-Za-z0-9._]*", value) is None:
        raise ValidationError(f"{label} '{value}' is not a valid identifier.")


def validate_name_expr_spec(spec: str, capability_label: str) -> Tuple[str, str]:
    if ":=" not in spec:
        raise ValidationError(f"{capability_label} requires '<name>:=<expr>'.")

    name_part, expr_part = spec.split(":=", 1)
    var_name = trim(name_part)
    var_expr = trim(expr_part)

    if not var_name or not var_expr:
        raise ValidationError(f"{capability_label} requires non-empty name and expression.")

    validate_identifier(var_name, f"{capability_label} name")
    if contains_regex(var_expr, r"(<-|->|=)\s*$"):
        raise ValidationError(f"{capability_label} expression for '{var_name}' looks incomplete.")

    validate_common_blocklist(var_expr, f"{capability_label} expression '{var_name}'")
    validate_assignment_free(var_expr, f"{capability_label} expression '{var_name}'")
    return var_name, var_expr


def validate_append_snippet(snippet: str) -> None:
    if not trim(snippet):
        raise ValidationError("append cannot be empty.")
    validate_common_blocklist(snippet, "Appended code")
    if contains_regex(snippet, r"(^|[^A-Za-z0-9_.])(\.GlobalEnv|globalenv\s*\()"):
        raise ValidationError("Appended code cannot directly target .GlobalEnv.")
    validate_append_file_restrictions(snippet)


def validate_result_expr(expr: str) -> None:
    if not trim(expr):
        raise ValidationError("result cannot be empty.")
    if "\n" in expr:
        raise ValidationError("result must be one line.")
    validate_common_blocklist(expr, "Result expression")
    validate_assignment_free(expr, "Result expression")


def validate_state_export_expr(expr: str) -> None:
    if not trim(expr):
        raise ValidationError("export cannot be empty.")
    if "\n" in expr:
        raise ValidationError("export must be one line.")
    validate_common_blocklist(expr, "R_STATE_EXPORT expression")
    validate_assignment_free(expr, "R_STATE_EXPORT expression")


def validate_modify_global_snippet(snippet: str) -> None:
    if not trim(snippet):
        raise ValidationError("modify cannot be empty.")
    validate_common_blocklist(snippet, "Global-modify code")


def extract_kv_value(path: Path, key: str) -> str:
    if not path.exists():
        return ""
    pattern = re.compile(rf'^{re.escape(key)}="(.*)"$')
    with path.open("r", encoding="utf-8", errors="replace") as handle:
        for line in handle:
            line = line.rstrip("\n")
            match = pattern.match(line)
            if match:
                return match.group(1)
    return ""


def session_pid_is_alive(pid: str) -> bool:
    if not pid or re.fullmatch(r"\d+", pid) is None:
        return False
    if not Path(f"/proc/{pid}").exists():
        return False
    cmd = ["ps", "-p", pid, "-o", "args="]
    proc = subprocess.run(cmd, capture_output=True, text=True)
    if proc.returncode != 0:
        return False
    return "/usr/lib/rstudio-server/bin/rsession" in proc.stdout


def infer_stream_from_pid(pid: str) -> str:
    if not pid or re.fullmatch(r"\d+", pid) is None:
        return ""
    for pid_file in sorted(Path("/var/run/rstudio-server/rstudio-rsession").glob("*.pid")):
        try:
            candidate_pid = pid_file.read_text(encoding="utf-8", errors="replace").strip()
        except OSError:
            continue
        if candidate_pid == pid:
            return pid_file.stem
    return ""


def active_session_dirs() -> List[Path]:
    base = Path.home() / ".local/share/rstudio/sessions/active"
    sessions = [p for p in base.glob("session-*") if p.is_dir()]
    sessions.sort(key=lambda p: p.stat().st_mtime, reverse=True)
    return sessions


def resolve_session_dir(state: State) -> Path:
    if state.session_dir:
        session_dir = Path(state.session_dir)
        if not (session_dir / "session-persistent-state").exists():
            raise SendError(f"Specified session-dir is missing session-persistent-state: {session_dir}")
        return session_dir

    current_pid = os.environ.get("RSTUDIO_SESSION_PID", "")

    if session_pid_is_alive(current_pid):
        for candidate in active_session_dirs():
            state_file = candidate / "session-persistent-state"
            env_file = candidate / "suspended-session-data/environment_vars"
            if not state_file.exists() or not env_file.exists():
                continue
            env_pid = extract_kv_value(env_file, "RSTUDIO_SESSION_PID")
            if env_pid == current_pid:
                return candidate

    for candidate in active_session_dirs():
        if (candidate / "session-persistent-state").exists():
            return candidate

    raise SendError("Unable to locate an active RStudio session state file.")


def apply_env_file(env_file: Path) -> None:
    if not env_file.exists():
        return
    pattern = re.compile(r'^([A-Za-z_][A-Za-z0-9_]*)="(.*)"$')
    with env_file.open("r", encoding="utf-8", errors="replace") as handle:
        for line in handle:
            line = line.rstrip("\n")
            match = pattern.match(line)
            if not match:
                continue
            key = match.group(1)
            value = match.group(2)
            os.environ[key] = value


def load_session_environment(session_dir: Path) -> None:
    env_file = session_dir / "suspended-session-data/environment_vars"
    current_stream = os.environ.get("RSTUDIO_SESSION_STREAM", "")
    current_token = os.environ.get("RS_PORT_TOKEN", "")
    current_pid = os.environ.get("RSTUDIO_SESSION_PID", "")

    if current_stream and current_token and session_pid_is_alive(current_pid):
        return

    if env_file.exists():
        file_pid = extract_kv_value(env_file, "RSTUDIO_SESSION_PID")
        if session_pid_is_alive(file_pid):
            apply_env_file(env_file)

    if ((not os.environ.get("RSTUDIO_SESSION_STREAM")) or (not os.environ.get("RS_PORT_TOKEN"))) and env_file.exists():
        apply_env_file(env_file)

    env_pid = os.environ.get("RSTUDIO_SESSION_PID", "")
    if not os.environ.get("RSTUDIO_SESSION_STREAM") and session_pid_is_alive(env_pid):
        inferred_stream = infer_stream_from_pid(env_pid)
        if inferred_stream:
            os.environ["RSTUDIO_SESSION_STREAM"] = inferred_stream


def get_session_property_file(session_dir: Path, key: str) -> Optional[Path]:
    typo = session_dir / "properites" / key
    fixed = session_dir / "properties" / key
    if typo.exists():
        return typo
    if fixed.exists():
        return fixed
    return None


def check_session_busy_before_rpc(session_dir: Path) -> bool:
    executing_file = get_session_property_file(session_dir, "executing")
    executing_value = ""
    if executing_file is not None:
        try:
            executing_value = "".join(executing_file.read_text(encoding="utf-8", errors="replace").split())
        except OSError:
            executing_value = ""

    if executing_value == "1":
        print("RStudio session appears busy (executing=1).", file=sys.stderr)
        print("Finish or interrupt the current console task, then retry.", file=sys.stderr)
        return False
    return True


def get_executing_flag_value(session_dir: Path) -> str:
    executing_file = get_session_property_file(session_dir, "executing")
    if executing_file is None:
        return "<missing>"
    try:
        executing_value = "".join(executing_file.read_text(encoding="utf-8", errors="replace").split())
    except OSError:
        executing_value = ""
    return executing_value or "<missing>"


def result_file_size_bytes(path: Path) -> int:
    try:
        return path.stat().st_size
    except OSError:
        return 0


def diagnose_result_wait_timeout(out_path: Path, session_dir: Path) -> None:
    executing_value = get_executing_flag_value(session_dir)
    out_exists = out_path.exists()
    out_size = result_file_size_bytes(out_path)

    pid_value = os.environ.get("RSTUDIO_SESSION_PID", "")
    pid_state = "<missing>"
    if pid_value:
        if session_pid_is_alive(pid_value):
            pid_state = "alive"
        elif re.fullmatch(r"\d+", pid_value):
            pid_state = "dead_or_not_rsession"
        else:
            pid_state = "invalid"

    state_file = session_dir / "session-persistent-state"
    abend_value = extract_kv_value(state_file, "abend")
    if not abend_value:
        abend_value = "<missing>"

    causes: List[str] = []
    if executing_value == "1":
        causes.append("compute_still_running")
    if out_exists and out_size == 0 and executing_value != "1":
        causes.append("handoff_or_write_delay")
    if not out_exists:
        causes.append("output_path_unavailable")
    if pid_state in {"dead_or_not_rsession", "invalid"} or abend_value == "1":
        causes.append("session_liveness_issue")
    if not causes:
        causes.append("unknown")

    print(f"Timeout diagnostics: causes={','.join(causes)}", file=sys.stderr)
    print(
        f"Timeout diagnostics: executing={executing_value} output_exists={1 if out_exists else 0} "
        f"output_size_bytes={out_size} session_pid={pid_value or '<missing>'}({pid_state}) abend={abend_value}",
        file=sys.stderr,
    )

    if executing_value == "1":
        print("Likely cause: R code is still running in the live console.", file=sys.stderr)
        print("Action: interrupt or wait for the current console task before retrying.", file=sys.stderr)
    if out_exists and out_size == 0 and executing_value != "1":
        print("Possible cause: compute finished but result handoff/file write lagged.", file=sys.stderr)
        print("Action: increase timeout, reduce payload size, and retry once.", file=sys.stderr)
    if not out_exists:
        print("Possible cause: output file was removed or inaccessible while waiting.", file=sys.stderr)
        print("Action: verify /tmp availability and file permissions, then retry.", file=sys.stderr)
    if pid_state in {"dead_or_not_rsession", "invalid"} or abend_value == "1":
        print("Possible cause: session snapshot points to a dead/restarted rsession.", file=sys.stderr)
        print("Action: re-resolve live runtime env vars and retry once.", file=sys.stderr)


def parse_bool(value: str) -> bool:
    normalized = value.strip().lower()
    if normalized in {"1", "true", "on", "yes"}:
        return True
    if normalized in {"0", "false", "off", "no"}:
        return False
    raise ValidationError(f"Invalid boolean value: {value!r}")


def ensure_int_string(value: str, label: str) -> None:
    if re.fullmatch(r"\d+", value) is None:
        raise ValidationError(f"{label} must be an integer.")


def extract_parse_error_line(parse_output: str) -> Optional[int]:
    for line in parse_output.splitlines():
        match = re.search(r":(\d+):(\d+):", line)
        if match:
            try:
                return int(match.group(1))
            except ValueError:
                return None
    return None


def format_parse_error_snippet(r_code: str, line_no: int, context: int = 2) -> str:
    lines = r_code.splitlines()
    if line_no < 1 or not lines:
        return ""
    start = max(1, line_no - context)
    end = min(len(lines), line_no + context)
    block = ["R snippet around parse error:"]
    for idx in range(start, end + 1):
        marker = ">>" if idx == line_no else "  "
        block.append(f"{marker} {idx:4d}: {lines[idx - 1]}")
    return "\n".join(block)


def pending_capability_count(state: State) -> int:
    return (
        len(state.append_code_snippets)
        + int(bool(state.result_expr))
        + int(bool(state.state_export_expr))
        + len(state.create_global_specs)
        + len(state.modify_global_snippets)
    )


def build_prompt(state: State) -> str:
    pending = pending_capability_count(state)
    result_set = 1 if state.result_expr else 0
    export_set = 1 if state.state_export_expr else 0
    return f"rstudio-bridge[pending={pending},result={result_set},export={export_set}]> "


def validate_state_for_send(state: State) -> SendContext:
    has_append = bool(state.append_code_snippets)
    has_result = bool(state.result_expr)
    has_export = bool(state.state_export_expr)
    has_create = bool(state.create_global_specs)
    has_modify = bool(state.modify_global_snippets)
    has_any = has_append or has_result or has_export or has_create or has_modify
    has_terminal = has_result or has_export or has_create or has_modify

    if not has_any:
        raise ValidationError("At least one capability is required.")

    if state.state_export_expr:
        if state.result_expr or state.create_global_specs or state.modify_global_snippets:
            raise ValidationError(
                "export cannot be combined with result, create, or modify."
            )

    if state.benchmark_unit not in {"seconds", "ms"}:
        raise ValidationError("benchmark-unit must be either 'seconds' or 'ms'.")

    if state.benchmark_mode:
        if not state.result_expr:
            raise ValidationError("benchmark requires result.")
        if state.state_export_expr or state.create_global_specs or state.modify_global_snippets:
            raise ValidationError(
                "benchmark cannot be combined with export, create, or modify."
            )

    ensure_int_string(state.request_id, "id")
    ensure_int_string(state.timeout_seconds, "timeout")
    ensure_int_string(state.rpc_timeout_seconds, "rpc-timeout")

    for snippet in state.append_code_snippets:
        validate_append_snippet(snippet)

    if state.result_expr:
        validate_result_expr(state.result_expr)

    if state.state_export_expr:
        validate_state_export_expr(state.state_export_expr)

    for snippet in state.create_global_specs:
        validate_name_expr_spec(snippet, "create")

    for snippet in state.modify_global_snippets:
        validate_modify_global_snippet(snippet)

    expect_result = bool(state.result_expr or state.state_export_expr)
    append_only = has_append and not has_terminal

    if state.capture_output and not expect_result:
        raise ValidationError("capture-output requires result or export.")

    out_path = state.out_path
    is_temp_out_path = False
    if expect_result and not out_path:
        fd, tmp = tempfile.mkstemp(prefix="codex_rstudio_capability_result_", suffix=".txt", dir="/tmp")
        os.close(fd)
        out_path = tmp
        is_temp_out_path = True

    state_export_path = ""
    if state.state_export_expr:
        fd, tmp = tempfile.mkstemp(prefix="codex_rstudio_state_", suffix=".rds", dir="/tmp")
        os.close(fd)
        state_export_path = tmp

    return SendContext(
        expect_result=expect_result,
        out_path=out_path,
        is_temp_out_path=is_temp_out_path,
        state_export_path=state_export_path,
        append_only=append_only,
    )


def find_rpc_script(script_dir: Path) -> Path:
    local_rpc_py = script_dir / "communicate_with_rstudio_console_with_rpc_low_level.py"
    if local_rpc_py.exists():
        return local_rpc_py
    home_rpc_py = Path.home() / ".codex/skills/r-assist/scripts/communicate_with_rstudio_console_with_rpc_low_level.py"
    if home_rpc_py.exists():
        return home_rpc_py
    raise SendError("Unable to locate communicate_with_rstudio_console_with_rpc_low_level.py")


def check_r_code_parse(r_code: str, expect_result: bool, out_path: str) -> None:
    fd_code, code_path = tempfile.mkstemp(prefix="codex_rstudio_check_", suffix=".R", dir="/tmp")
    os.close(fd_code)
    fd_log, log_path = tempfile.mkstemp(prefix="codex_rstudio_check_parse_", suffix=".txt", dir="/tmp")
    os.close(fd_log)

    code_file = Path(code_path)
    log_file = Path(log_path)
    try:
        code_file.write_text(r_code, encoding="utf-8")
        escaped_code_path = escape_for_r_string(code_path)
        expr = f'parse(file = "{escaped_code_path}")'
        proc = subprocess.run(
            ["Rscript", "-e", expr],
            capture_output=True,
            text=True,
        )
        log_file.write_text((proc.stdout or "") + (proc.stderr or ""), encoding="utf-8")
        if proc.returncode != 0:
            parse_out = log_file.read_text(encoding="utf-8", errors="replace")
            snippet = ""
            line_no = extract_parse_error_line(parse_out)
            if line_no is not None:
                snippet = format_parse_error_snippet(r_code, line_no)
            print("__SYNTAX_ERROR__", file=sys.stderr)
            print(parse_out, file=sys.stderr)
            if snippet:
                print(snippet, file=sys.stderr)
            if expect_result:
                payload = f"__SYNTAX_ERROR__\n{parse_out}"
                if snippet:
                    payload += f"\n{snippet}\n"
                Path(out_path).write_text(payload, encoding="utf-8")
            raise ValidationError("R syntax check failed.")
    finally:
        try:
            code_file.unlink()
        except OSError:
            pass
        try:
            log_file.unlink()
        except OSError:
            pass


def build_r_code(state: State, send_ctx: SendContext) -> str:
    r_exec_lines: List[str] = []
    r_create_lines: List[str] = []
    r_modify_lines: List[str] = []
    r_create_names: List[str] = []

    for snippet in state.append_code_snippets:
        r_exec_lines.append(snippet)

    if state.result_expr:
        if state.benchmark_mode:
            r_exec_lines.append('.codex_bench_t0 <- proc.time()[["elapsed"]]')
            r_exec_lines.append(
                f'.codex_result_expr <- tryCatch({{ invisible(({state.result_expr})); proc.time()[["elapsed"]] - .codex_bench_t0 }}, error = function(e) e)'
            )
            if state.benchmark_unit == "ms":
                r_exec_lines.append('if (!inherits(.codex_result_expr, "error")) .codex_result_expr <- .codex_result_expr * 1000')
        else:
            r_exec_lines.append(
                f'.codex_result_expr <- tryCatch(({state.result_expr}), error = function(e) e)'
            )

    if state.state_export_expr:
        escaped_state_path = escape_for_r_string(send_ctx.state_export_path)
        r_exec_lines.append(f'.codex_state_export_path <- "{escaped_state_path}"')
        r_exec_lines.append(f'.codex_state_payload <- ({state.state_export_expr})')
        r_exec_lines.append('saveRDS(.codex_state_payload, file = .codex_state_export_path, compress = "xz")')
        r_exec_lines.append('rm(.codex_state_payload)')
        r_exec_lines.append('if (!file.exists(.codex_state_export_path)) stop("State export file was not created")')
        r_exec_lines.append('.codex_result_expr <- .codex_state_export_path')

    seen = set()
    for spec in state.create_global_specs:
        name, expr = validate_name_expr_spec(spec, "create")
        if name in seen:
            raise ValidationError(f"create duplicates name '{name}' in one invocation.")
        seen.add(name)
        r_create_names.append(name)
        r_create_lines.append(
            f'if (exists("{name}", envir = .GlobalEnv, inherits = FALSE)) stop("CREATE_NEW_GLOBAL_VARIABLE refused: \'{name}\' already exists in .GlobalEnv")'
        )
        r_create_lines.append(f'{name} <- ({expr})')
        r_create_lines.append(f'assign("{name}", {name}, envir = .GlobalEnv)')

    for snippet in state.modify_global_snippets:
        escaped = escape_for_r_string(snippet)
        r_modify_lines.append(f'eval(parse(text = "{escaped}"), envir = .GlobalEnv)')

    r_allowed_added = ",".join(f'"{name}"' for name in r_create_names)
    r_exec_block = join_lines(r_exec_lines)
    r_create_block = join_lines(r_create_lines)
    r_modify_block = join_lines(r_modify_lines)

    out_path_escaped = ""
    if send_ctx.expect_result:
        out_path_escaped = escape_for_r_string(send_ctx.out_path)

    r_code = ""
    r_code += '.codex_before <- ls(envir = .GlobalEnv, all.names = TRUE)\n'
    r_code += f'.codex_allowed_added <- c({r_allowed_added})\n'
    r_code += f'.codex_result_out_path <- "{out_path_escaped}"\n'
    r_code += f'.codex_capture_output <- {"TRUE" if state.capture_output else "FALSE"}\n'
    r_code += '.codex_captured_stdout <- character(0)\n'
    r_code += '.codex_captured_stderr <- character(0)\n'
    r_code += '.codex_result_written <- FALSE\n'
    r_code += '.codex_exec_result <- NULL\n'
    r_code += '.codex_run_core <- function() {\n'
    r_code += '  .codex_exec_result <<- with(new.env(parent = .GlobalEnv), {\n'
    r_code += indent_block(r_exec_block, "    ")
    r_code += '  })\n'
    if r_create_block:
        r_code += indent_block(r_create_block, "  ")
    if r_modify_block:
        r_code += indent_block(r_modify_block, "  ")
    r_code += '}\n'
    r_code += '.codex_msg <- function(x) {\n'
    r_code += '  if (inherits(x, "condition")) conditionMessage(x) else as.character(x)\n'
    r_code += '}\n'
    r_code += '.codex_exec_error <- tryCatch({\n'
    r_code += '  if (.codex_capture_output) {\n'
    r_code += '    .codex_captured_stdout <- capture.output({\n'
    r_code += '      withCallingHandlers({\n'
    r_code += '        .codex_run_core()\n'
    r_code += '      }, message = function(m) {\n'
    r_code += '        .codex_captured_stderr <<- c(.codex_captured_stderr, conditionMessage(m))\n'
    r_code += '        invokeRestart("muffleMessage")\n'
    r_code += '      }, warning = function(w) {\n'
    r_code += '        .codex_captured_stderr <<- c(.codex_captured_stderr, paste0("WARNING: ", conditionMessage(w)))\n'
    r_code += '        invokeRestart("muffleWarning")\n'
    r_code += '      })\n'
    r_code += '    }, type = "output")\n'
    r_code += '  } else {\n'
    r_code += '    .codex_run_core()\n'
    r_code += '  }\n'
    r_code += '}, error = function(e) e)\n'

    if send_ctx.expect_result:
        r_code += 'if (!is.null(.codex_exec_error)) {\n'
        r_code += '  if (.codex_capture_output) {\n'
        r_code += '    dput(list(error = .codex_msg(.codex_exec_error), stdout = .codex_captured_stdout, stderr = .codex_captured_stderr), file = .codex_result_out_path)\n'
        r_code += '  } else {\n'
        r_code += '    writeLines(paste0("__ERROR__:", .codex_msg(.codex_exec_error)), .codex_result_out_path)\n'
        r_code += '  }\n'
        r_code += '  .codex_result_written <- TRUE\n'
        r_code += '}\n'
        r_code += 'if (is.null(.codex_exec_error) && is.null(.codex_exec_result)) {\n'
        r_code += '  if (.codex_capture_output) {\n'
        r_code += '    dput(list(error = "no result produced", stdout = .codex_captured_stdout, stderr = .codex_captured_stderr), file = .codex_result_out_path)\n'
        r_code += '  } else {\n'
        r_code += '    writeLines("__ERROR__: no result produced", .codex_result_out_path)\n'
        r_code += '  }\n'
        r_code += '  .codex_result_written <- TRUE\n'
        r_code += '}\n'
        r_code += 'if (is.null(.codex_exec_error) && inherits(.codex_exec_result, "error")) {\n'
        r_code += '  if (.codex_capture_output) {\n'
        r_code += '    dput(list(error = .codex_msg(.codex_exec_result), stdout = .codex_captured_stdout, stderr = .codex_captured_stderr), file = .codex_result_out_path)\n'
        r_code += '  } else {\n'
        r_code += '    writeLines(paste0("__ERROR__:", .codex_msg(.codex_exec_result)), .codex_result_out_path)\n'
        r_code += '  }\n'
        r_code += '  .codex_result_written <- TRUE\n'
        r_code += '}\n'
        r_code += 'if (is.null(.codex_exec_error) && !inherits(.codex_exec_result, "error") && !is.null(.codex_exec_result)) {\n'
        r_code += '  if (.codex_capture_output) {\n'
        r_code += '    dput(list(result = .codex_exec_result, stdout = .codex_captured_stdout, stderr = .codex_captured_stderr), file = .codex_result_out_path)\n'
        r_code += '  } else {\n'
        r_code += '    dput(.codex_exec_result, file = .codex_result_out_path)\n'
        r_code += '  }\n'
        r_code += '  .codex_result_written <- TRUE\n'
        r_code += '}\n'

    r_code += 'if (!is.null(.codex_exec_error)) {\n'
    r_code += '  stop(.codex_msg(.codex_exec_error))\n'
    r_code += '}\n'
    r_code += '.codex_after <- ls(envir = .GlobalEnv, all.names = TRUE)\n'
    r_code += '.codex_new <- setdiff(.codex_after, .codex_before)\n'
    r_code += '.codex_removed <- setdiff(.codex_before, .codex_after)\n'
    r_code += '.codex_unexpected_new <- setdiff(.codex_new, .codex_allowed_added)\n'
    r_code += '.codex_unexpected_removed <- setdiff(.codex_removed, character(0))\n'
    r_code += 'if (length(.codex_unexpected_new) > 0 || length(.codex_unexpected_removed) > 0) {\n'
    r_code += '  stop("Global environment leak detected")\n'
    r_code += '}\n'
    return r_code


def run_rpc_send(rpc_script: Path, rpc_args: List[str], suppress_stdout: bool, rpc_timeout_seconds: str) -> int:
    cmd = ["python3", str(rpc_script)] + rpc_args
    use_timeout = shutil.which("timeout") is not None

    if use_timeout:
        wrapped = [
            "timeout",
            "--foreground",
            "--signal=TERM",
            "--kill-after=2",
            f"{rpc_timeout_seconds}s",
        ] + cmd
        proc = subprocess.run(wrapped, capture_output=True, text=True)
    else:
        proc = subprocess.run(cmd, capture_output=True, text=True)

    if not suppress_stdout and proc.stdout:
        print(proc.stdout, end="")
    elif suppress_stdout:
        pass

    if proc.stderr:
        print(proc.stderr, file=sys.stderr, end="")

    if proc.returncode in {124, 137}:
        print(f"RPC send timed out after {rpc_timeout_seconds}s.", file=sys.stderr)
        return 124

    return proc.returncode


def run_low_level_passthrough(argv: List[str], script_dir: Path) -> int:
    try:
        rpc_script = find_rpc_script(script_dir)
    except SendError as exc:
        print(str(exc), file=sys.stderr)
        return 1

    proc = subprocess.run(["python3", str(rpc_script)] + argv)
    return proc.returncode


def send_current_state(state: State, script_dir: Path) -> None:
    send_ctx = validate_state_for_send(state)
    success = False

    try:
        session_dir = resolve_session_dir(state)
        load_session_environment(session_dir)
        r_code = build_r_code(state, send_ctx)

        if send_ctx.append_only:
            print(
                "Warning: APPEND-only send has no structured return value. "
                "Add result:/export:/create:/modify: if you need output.",
                file=sys.stderr,
            )

        check_r_code_parse(r_code, send_ctx.expect_result, send_ctx.out_path)

        if state.print_code:
            print("Generated R code:", file=sys.stderr)
            print(r_code, file=sys.stderr)

        rpc_script = find_rpc_script(script_dir)
        rpc_args = [
            "--code",
            r_code,
            "--isolate-code",
            "1",
            "--id",
            state.request_id,
            "--rpc-timeout",
            state.rpc_timeout_seconds,
            "--session-dir",
            str(session_dir),
        ]
        if state.rpostback_bin:
            rpc_args += ["--rpostback-bin", state.rpostback_bin]

        if send_ctx.expect_result:
            Path(send_ctx.out_path).write_text("", encoding="utf-8")

        if not check_session_busy_before_rpc(session_dir):
            raise SendError("Failed busy precheck.")

        suppress_stdout = send_ctx.expect_result
        rc = run_rpc_send(
            rpc_script=rpc_script,
            rpc_args=rpc_args,
            suppress_stdout=suppress_stdout,
            rpc_timeout_seconds=state.rpc_timeout_seconds,
        )
        if rc != 0:
            raise SendError("Failed to send RPC request.")

        if send_ctx.expect_result:
            deadline = time.time() + int(state.timeout_seconds)
            out_file = Path(send_ctx.out_path)
            while time.time() < deadline:
                if out_file.exists() and out_file.stat().st_size > 0:
                    print(out_file.read_text(encoding="utf-8", errors="replace"), end="")
                    break
                time.sleep(0.2)

            if not (out_file.exists() and out_file.stat().st_size > 0):
                print(f"Timed out waiting for result file: {send_ctx.out_path}", file=sys.stderr)
                diagnose_result_wait_timeout(out_file, session_dir)
                raise SendError("Timed out waiting for result file.")

        success = True
    finally:
        if send_ctx.is_temp_out_path and send_ctx.out_path:
            try:
                Path(send_ctx.out_path).unlink()
            except OSError:
                pass
        if not success and send_ctx.state_export_path:
            try:
                Path(send_ctx.state_export_path).unlink()
            except OSError:
                pass


def print_help() -> None:
    print(
        "Commands:\n"
        "  append:<R statement>          Append statement in scratch env\n"
        "  result:<R expression>         Set result expression (single line)\n"
        "  export:<R expression>         Export expression via saveRDS and return file path\n"
        "  create:<name>:=<expr>         Create new variable in .GlobalEnv\n"
        "  modify:<R statement>          Evaluate statement in .GlobalEnv\n"
        "  session-dir:<dir>             Override active RStudio session directory\n"
        "  id:<int>                      JSON-RPC request id\n"
        "  rpostback-bin:<path>          Override rpostback binary\n"
        "  out:<path>                    Result output file\n"
        "  timeout:<seconds>             Wait timeout for result file\n"
        "  rpc-timeout:<seconds>         Hard timeout for RPC send step\n"
        "  benchmark:<on|off>            Benchmark result expression\n"
        "  benchmark-unit:<seconds|ms>   Unit for benchmark\n"
        "  print-code:<on|off>           Print generated R snippet to stderr\n"
        "  capture-output:<on|off>       Return structured stdout/stderr with result\n"
        "\n"
        "Control:\n"
        "  show                           Show current accumulated state\n"
        "  clear                          Clear accumulated capabilities\n"
        "  send                           Validate/build/send accumulated request\n"
        "  help                           Show this help\n"
        "  quit                           Exit\n"
    )


def show_state(state: State) -> None:
    print(f"  pending capabilities: {pending_capability_count(state)}")
    print("State summary:")
    print(f"  append snippets: {len(state.append_code_snippets)}")
    print(f"  result set: {bool(state.result_expr)}")
    print(f"  export set: {bool(state.state_export_expr)}")
    print(f"  create specs: {len(state.create_global_specs)}")
    print(f"  modify snippets: {len(state.modify_global_snippets)}")
    print(f"  session-dir: {state.session_dir or '<auto>'}")
    print(f"  id: {state.request_id}")
    print(f"  rpostback-bin: {state.rpostback_bin or '<default>'}")
    print(f"  out: {state.out_path or '<tmp-if-needed>'}")
    print(f"  timeout: {state.timeout_seconds}")
    print(f"  rpc-timeout: {state.rpc_timeout_seconds}")
    print(f"  benchmark: {'on' if state.benchmark_mode else 'off'}")
    print(f"  benchmark-unit: {state.benchmark_unit}")
    print(f"  print-code: {'on' if state.print_code else 'off'}")
    print(f"  capture-output: {'on' if state.capture_output else 'off'}")


def apply_input_line(state: State, line: str) -> Optional[str]:
    normalized = line.strip()
    if not normalized:
        return None

    if normalized in {"help", "?"}:
        print_help()
        return None

    if normalized == "show":
        show_state(state)
        return None

    if normalized == "clear":
        state.clear_capabilities()
        print("Cleared accumulated capabilities.")
        return None

    if normalized == "send":
        return "send"

    if normalized in {"quit", "exit"}:
        return "quit"

    if ":" not in line:
        raise ValidationError("Input must be '<prefix>:<payload>' or a control command.")

    prefix, payload = line.split(":", 1)
    key = prefix.strip().lower()

    if key in {"append", "append-code"}:
        validate_append_snippet(payload)
        state.append_code_snippets.append(payload)
    elif key in {"result", "set-result-expr"}:
        validate_result_expr(payload)
        state.result_expr = payload
    elif key in {"export", "r-state-export"}:
        validate_state_export_expr(payload)
        state.state_export_expr = payload
    elif key in {"create", "create-global-variable"}:
        validate_name_expr_spec(payload, "create")
        state.create_global_specs.append(payload)
    elif key in {"modify", "modify-global-env"}:
        validate_modify_global_snippet(payload)
        state.modify_global_snippets.append(payload)
    elif key == "session-dir":
        state.session_dir = payload.strip()
    elif key == "id":
        ensure_int_string(payload.strip(), "id")
        state.request_id = payload.strip()
    elif key == "rpostback-bin":
        state.rpostback_bin = payload.strip()
    elif key == "out":
        state.out_path = payload.strip()
    elif key == "timeout":
        ensure_int_string(payload.strip(), "timeout")
        state.timeout_seconds = payload.strip()
    elif key == "rpc-timeout":
        ensure_int_string(payload.strip(), "rpc-timeout")
        state.rpc_timeout_seconds = payload.strip()
    elif key == "benchmark":
        state.benchmark_mode = parse_bool(payload)
    elif key == "benchmark-unit":
        value = payload.strip()
        if value not in {"seconds", "ms"}:
            raise ValidationError("benchmark-unit must be either 'seconds' or 'ms'.")
        state.benchmark_unit = value
    elif key == "print-code":
        state.print_code = parse_bool(payload)
    elif key == "capture-output":
        state.capture_output = parse_bool(payload)
    else:
        raise ValidationError(f"Unknown input prefix: {prefix}")

    return None


def repl() -> int:
    if len(sys.argv) > 1:
        script_dir = Path(__file__).resolve().parent
        return run_low_level_passthrough(sys.argv[1:], script_dir)

    state = State()
    script_dir = Path(__file__).resolve().parent

    print("interactive_rstudio_bridge ready. Type 'help' for commands.")
    while True:
        try:
            line = input(build_prompt(state))
        except EOFError:
            print()
            return 0
        except KeyboardInterrupt:
            print("", file=sys.stderr)
            return 130

        try:
            action = apply_input_line(state, line)
            if action == "quit":
                return 0
            if action == "send":
                send_succeeded = False
                try:
                    send_current_state(state, script_dir)
                    send_succeeded = True
                finally:
                    state.clear_capabilities()
                if send_succeeded:
                    print("Send completed; capability state cleared.")
                else:
                    print("Send failed; capability state cleared.", file=sys.stderr)
        except ValidationError as exc:
            print(str(exc), file=sys.stderr)
        except SendError as exc:
            print(str(exc), file=sys.stderr)
        except Exception as exc:  # defensive catch for loop resilience
            print(f"Unexpected error: {exc}", file=sys.stderr)


if __name__ == "__main__":
    sys.exit(repl())
