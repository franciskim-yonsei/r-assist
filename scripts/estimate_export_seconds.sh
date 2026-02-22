#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage:
  estimate_export_seconds.sh [--timeout <seconds>] [--rpc-timeout <seconds>] '<R expression>'

Description:
  Evaluate object size for the provided R expression in the live RStudio session and print:
    max(5, ceiling(0.5 * size_in_MB + 10))

Examples:
  estimate_export_seconds.sh 'total'
  estimate_export_seconds.sh --timeout 120 --rpc-timeout 120 'list(meta = total@meta.data)'
USAGE
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WRAPPER="$SCRIPT_DIR/interact_with_rstudio.sh"
TIMEOUT_SECONDS="30"
RPC_TIMEOUT_SECONDS="30"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --timeout)
      TIMEOUT_SECONDS="${2-}"
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
    --)
      shift
      break
      ;;
    *)
      break
      ;;
  esac
done

if [[ ! "$TIMEOUT_SECONDS" =~ ^[0-9]+$ ]]; then
  echo "--timeout must be an integer number of seconds." >&2
  exit 2
fi

if [[ ! "$RPC_TIMEOUT_SECONDS" =~ ^[0-9]+$ ]]; then
  echo "--rpc-timeout must be an integer number of seconds." >&2
  exit 2
fi

if [[ $# -lt 1 ]]; then
  usage >&2
  exit 2
fi

R_EXPR="$*"
if [[ "$R_EXPR" == *$'\n'* ]]; then
  echo "R expression must be one line." >&2
  exit 2
fi

APPEND_LINE=".codex_size_mb <- as.numeric(object.size((${R_EXPR}))) / (1024^2)"
RESULT_EXPR="max(5, ceiling(0.5 * .codex_size_mb + 10))"

bash "$WRAPPER" \
  --append-code "$APPEND_LINE" \
  --set-result-expr "$RESULT_EXPR" \
  --rpc-timeout "$RPC_TIMEOUT_SECONDS" \
  --timeout "$TIMEOUT_SECONDS"
