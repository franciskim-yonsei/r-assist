#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  communicate_with_rstudio_console_with_rpc_low_level.sh --code '<R code>' [--session-dir <dir>] [--id <jsonrpc-id>] [--rpostback-bin <path>] [--isolate-code 0|1]

Examples:
  communicate_with_rstudio_console_with_rpc_low_level.sh --code 'print("Hello from codex!")'
  communicate_with_rstudio_console_with_rpc_low_level.sh --code 'dput(x, file = "/tmp/x.txt")' --id 7
EOF
}

CODE=""
SESSION_DIR=""
REQUEST_ID="1"
RPOSTBACK_BIN="${RPOSTBACK_BIN:-/usr/lib/rstudio-server/bin/rpostback}"
ISOLATE_CODE="1"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --code)
      CODE="${2-}"
      shift 2
      ;;
    --session-dir)
      SESSION_DIR="${2-}"
      shift 2
      ;;
    --id)
      REQUEST_ID="${2-}"
      shift 2
      ;;
    --rpostback-bin)
      RPOSTBACK_BIN="${2-}"
      shift 2
      ;;
    --isolate-code)
      ISOLATE_CODE="${2-}"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

if [[ -z "$CODE" ]]; then
  echo "Missing required --code argument" >&2
  usage >&2
  exit 2
fi

if [[ "$ISOLATE_CODE" != "0" && "$ISOLATE_CODE" != "1" ]]; then
  echo "Invalid --isolate-code value: $ISOLATE_CODE (use 0 or 1)" >&2
  usage >&2
  exit 2
fi

if [[ "$ISOLATE_CODE" == "1" ]]; then
  CODE="local({
${CODE}
}, envir = new.env(parent = .GlobalEnv))"
fi

if [[ -z "$SESSION_DIR" ]]; then
  SESSION_DIR="$(ls -dt "$HOME"/.local/share/rstudio/sessions/active/session-* 2>/dev/null | head -n1 || true)"
fi

if [[ -z "$SESSION_DIR" || ! -f "$SESSION_DIR/session-persistent-state" ]]; then
  echo "Unable to locate an active RStudio session state file." >&2
  exit 1
fi

CID="$(sed -n 's/^active-client-id="\(.*\)"/\1/p' "$SESSION_DIR/session-persistent-state" | head -n1)"

if [[ -z "$CID" ]]; then
  echo "active-client-id not found in $SESSION_DIR/session-persistent-state" >&2
  exit 1
fi

ESCAPED_CODE="$CODE"
ESCAPED_CODE="${ESCAPED_CODE//\\/\\\\}"
ESCAPED_CODE="${ESCAPED_CODE//\"/\\\"}"
ESCAPED_CODE="${ESCAPED_CODE//$'\n'/\\n}"
PAYLOAD="{\"jsonrpc\":\"2.0\",\"method\":\"console_input\",\"clientId\":\"$CID\",\"params\":[\"$ESCAPED_CODE\",\"\",0],\"id\":$REQUEST_ID}"

# Some RStudio builds return exit code 1 even when the JSON-RPC response is successful.
# Decide success from the response envelope, not only process rc.
set +e
RPC_OUTPUT="$("$RPOSTBACK_BIN" --command console_input --argument "$PAYLOAD" 2>&1)"
RPC_RC=$?
set -e

if [[ -n "$RPC_OUTPUT" ]]; then
  printf '%s\n' "$RPC_OUTPUT"
fi

if [[ "$RPC_OUTPUT" == *"\"error\""* ]]; then
  echo "JSON-RPC error returned for console_input." >&2
  exit 1
fi

if [[ "$RPC_OUTPUT" == *"\"result\""* ]]; then
  exit 0
fi

RPOSTBACK_LOG="$HOME/.local/share/rstudio/log/rpostback.log"
if [[ -f "$RPOSTBACK_LOG" ]]; then
  LAST_LOG="$(tail -n1 "$RPOSTBACK_LOG" || true)"
  if [[ -n "$LAST_LOG" ]]; then
    echo "rpostback failed (rc=$RPC_RC): $LAST_LOG" >&2
    if [[ "$LAST_LOG" == *"Operation not permitted"* ]]; then
      echo "Hint: run this command outside sandbox / with elevated permissions so it can access the local rsession socket." >&2
    fi
  fi
fi

echo "rpostback did not return a JSON-RPC result (rc=$RPC_RC)." >&2
exit 1
