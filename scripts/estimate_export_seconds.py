#!/usr/bin/env python3
import argparse
import os
import re
import subprocess
import sys
import tempfile
import time
from pathlib import Path


def usage() -> str:
    return (
        "Usage:\n"
        "  estimate_export_seconds.py [--timeout <seconds>] [--rpc-timeout <seconds>] '<R expression>'\n\n"
        "Description:\n"
        "  Evaluate object size for the provided R expression in the live RStudio session and print:\n"
        "    max(5, ceiling(0.5 * size_in_MB + 10))\n\n"
        "Examples:\n"
        "  estimate_export_seconds.py 'total'\n"
        "  estimate_export_seconds.py --timeout 120 --rpc-timeout 120 'list(meta = total@meta.data)'\n"
    )


def eprint(msg: str) -> None:
    print(msg, file=sys.stderr)


def is_int_string(value: str) -> bool:
    return re.fullmatch(r"\d+", value) is not None


def escape_for_r_string(value: str) -> str:
    value = value.replace("\\", "\\\\")
    value = value.replace('"', '\\"')
    value = value.replace("\n", "\\n")
    return value


def find_rpc_script(script_dir: Path) -> Path:
    local = script_dir / "communicate_with_rstudio_console_with_rpc_low_level.py"
    if local.exists():
        return local
    home = Path.home() / ".codex/skills/r-assist/scripts/communicate_with_rstudio_console_with_rpc_low_level.py"
    if home.exists():
        return home
    raise FileNotFoundError("Unable to locate communicate_with_rstudio_console_with_rpc_low_level.py")


def main() -> int:
    parser = argparse.ArgumentParser(add_help=False)
    parser.add_argument("--timeout", default="30")
    parser.add_argument("--rpc-timeout", default="30")
    parser.add_argument("-h", "--help", action="store_true")
    parser.add_argument("expr", nargs=argparse.REMAINDER)

    args = parser.parse_args()

    if args.help:
        print(usage(), end="")
        return 0

    if not is_int_string(args.timeout):
        eprint("--timeout must be an integer number of seconds.")
        return 2

    if not is_int_string(args.rpc_timeout):
        eprint("--rpc-timeout must be an integer number of seconds.")
        return 2

    if not args.expr:
        eprint(usage())
        return 2

    r_expr = " ".join(args.expr)
    if "\n" in r_expr:
        eprint("R expression must be one line.")
        return 2

    script_dir = Path(__file__).resolve().parent
    try:
        rpc_script = find_rpc_script(script_dir)
    except FileNotFoundError as exc:
        eprint(str(exc))
        return 1

    fd, out_path = tempfile.mkstemp(prefix="codex_estimate_export_seconds_", suffix=".txt", dir="/tmp")
    os.close(fd)
    out_file = Path(out_path)

    escaped_out = escape_for_r_string(out_path)
    code = "\n".join(
        [
            f'.codex_result_out_path <- "{escaped_out}"',
            (
                ".codex_result <- tryCatch({ "
                f".codex_size_mb <- as.numeric(object.size(({r_expr}))) / (1024^2); "
                "max(5, ceiling(0.5 * .codex_size_mb + 10)) "
                "}, error = function(e) e)"
            ),
            'if (inherits(.codex_result, "error")) {',
            '  writeLines(paste0("__ERROR__:", conditionMessage(.codex_result)), .codex_result_out_path)',
            '} else {',
            '  dput(.codex_result, file = .codex_result_out_path)',
            '}',
        ]
    )

    try:
        cmd = [
            "python3",
            str(rpc_script),
            "--code",
            code,
            "--rpc-timeout",
            args.rpc_timeout,
        ]
        proc = subprocess.run(cmd, capture_output=True, text=True)

        if proc.returncode != 0:
            if proc.stdout:
                print(proc.stdout, end="")
            if proc.stderr:
                print(proc.stderr, file=sys.stderr, end="")
            return 1

        deadline = time.time() + int(args.timeout)
        while time.time() < deadline:
            try:
                if out_file.exists() and out_file.stat().st_size > 0:
                    print(out_file.read_text(encoding="utf-8", errors="replace"), end="")
                    return 0
            except OSError:
                pass
            time.sleep(0.2)

        eprint(f"Timed out waiting for result file: {out_path}")
        return 1
    finally:
        try:
            out_file.unlink()
        except OSError:
            pass


if __name__ == "__main__":
    sys.exit(main())
