#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOH'
Usage:
  communicate_with_rstudio_console_with_rpc_low_level.sh --code '<R code>' [--session-dir <dir>] [--id <jsonrpc-id>] [--rpostback-bin <path>] [--isolate-code 0|1] [--rpc-timeout <seconds>]

Examples:
  communicate_with_rstudio_console_with_rpc_low_level.sh --code 'print("Hello from codex!")'
  communicate_with_rstudio_console_with_rpc_low_level.sh --code 'dput(x, file = "/tmp/x.txt")' --id 7
EOH
}

CODE=""
SESSION_DIR=""
REQUEST_ID="1"
RPOSTBACK_BIN="${RPOSTBACK_BIN:-/usr/lib/rstudio-server/bin/rpostback}"
ISOLATE_CODE="1"
RPC_TIMEOUT_SECONDS="${RPC_TIMEOUT_SECONDS:-12}"

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
    --rpc-timeout)
      RPC_TIMEOUT_SECONDS="${2-}"
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

if [[ ! "$RPC_TIMEOUT_SECONDS" =~ ^[0-9]+$ ]]; then
  echo "Invalid --rpc-timeout value: $RPC_TIMEOUT_SECONDS (use integer seconds)" >&2
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
ABEND="$(sed -n 's/^abend="\(.*\)"/\1/p' "$SESSION_DIR/session-persistent-state" | head -n1)"
ENV_FILE="$SESSION_DIR/suspended-session-data/environment_vars"
ENV_SESSION_PID=""
if [[ -f "$ENV_FILE" ]]; then
  ENV_SESSION_PID="$(sed -n 's/^RSTUDIO_SESSION_PID="\(.*\)"/\1/p' "$ENV_FILE" | head -n1)"
fi

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
RPOSTBACK_LOG="$HOME/.local/share/rstudio/log/rpostback.log"
RPOSTBACK_LOG_MTIME_BEFORE=""
if [[ -f "$RPOSTBACK_LOG" ]]; then
  RPOSTBACK_LOG_MTIME_BEFORE="$(stat -c %Y "$RPOSTBACK_LOG" 2>/dev/null || true)"
fi

set +e
if command -v timeout >/dev/null 2>&1; then
  RPC_OUTPUT="$(timeout --foreground --signal=TERM --kill-after=2 "${RPC_TIMEOUT_SECONDS}s" "$RPOSTBACK_BIN" --command console_input --argument "$PAYLOAD" 2>&1)"
  RPC_RC=$?
else
  RPC_OUTPUT="$("$RPOSTBACK_BIN" --command console_input --argument "$PAYLOAD" 2>&1)"
  RPC_RC=$?
fi
set -e

if [[ -n "$RPC_OUTPUT" ]]; then
  printf '%s\n' "$RPC_OUTPUT"
fi

if [[ "$RPC_RC" -eq 124 || "$RPC_RC" -eq 137 ]]; then
  PID_STATE="unknown"
  if [[ -n "$ENV_SESSION_PID" && "$ENV_SESSION_PID" =~ ^[0-9]+$ ]]; then
    if ps -p "$ENV_SESSION_PID" >/dev/null 2>&1; then
      PID_STATE="alive"
    else
      PID_STATE="dead"
    fi
  fi

  echo "rpostback timed out after ${RPC_TIMEOUT_SECONDS}s." >&2
  echo "Session metadata: dir=$SESSION_DIR abend=${ABEND:-<missing>} active-client-id=$CID env-session-pid=${ENV_SESSION_PID:-<missing>} (${PID_STATE})" >&2
  if [[ "$ABEND" == "1" || "$PID_STATE" == "dead" ]]; then
    echo "Hint: session snapshot metadata may be stale. Prefer live runtime env vars (RSTUDIO_SESSION_STREAM/RS_PORT_TOKEN) over suspended-session-data values." >&2
  fi
  exit 1
fi

if [[ "$RPC_OUTPUT" == *"\"error\""* ]]; then
  echo "JSON-RPC error returned for console_input." >&2
  exit 1
fi

if [[ "$RPC_OUTPUT" == *"\"result\""* ]]; then
  exit 0
fi

LAST_LOG=""
if [[ -f "$RPOSTBACK_LOG" ]]; then
  RPOSTBACK_LOG_MTIME_AFTER="$(stat -c %Y "$RPOSTBACK_LOG" 2>/dev/null || true)"
  if [[ -n "$RPOSTBACK_LOG_MTIME_AFTER" ]]; then
    if [[ -z "$RPOSTBACK_LOG_MTIME_BEFORE" || "$RPOSTBACK_LOG_MTIME_AFTER" != "$RPOSTBACK_LOG_MTIME_BEFORE" ]]; then
      LAST_LOG="$(tail -n1 "$RPOSTBACK_LOG" || true)"
    fi
  fi
fi

if [[ -n "$LAST_LOG" ]]; then
  echo "rpostback failed (rc=$RPC_RC): $LAST_LOG" >&2
  if [[ "$LAST_LOG" == *"Operation not permitted"* ]]; then
    echo "Hint: run this command outside sandbox / with elevated permissions so it can access the local rsession socket." >&2
  fi
fi

if [[ "$RPC_RC" -ne 0 ]]; then
  echo "Hint: if this call ran in sandbox, rerun the same single-segment command with escalation; sandbox postback access is a known failure mode." >&2
  echo "Hint: stale snapshot env vars can break auth; avoid overriding live RStudio env vars when they are already present." >&2
fi

echo "rpostback did not return a JSON-RPC result (rc=$RPC_RC)." >&2
exit 1
