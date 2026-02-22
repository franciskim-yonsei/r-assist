#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  interact_with_rstudio.sh [options]
    [--append-code '<R statement>']...
    [--set-result-expr '<R expression>']
    [--cache-code '<R statement>']...
    [--clear-cache]
    [--create-global-variable '<name>=<expr>']...
    [--modify-global-env '<R statement>']

Options:
  --session-dir <dir>           Override active RStudio session directory
  --id <jsonrpc-id>             JSON-RPC request id (default: 1)
  --rpostback-bin <path>        Override rpostback binary path
  --out <path>                  Output file for --set-result-expr value (optional)
  --timeout <seconds>           Wait timeout for result file (default: 8)
  --print-code                  Print generated R snippet to stderr
  -h, --help                    Show this help

Capabilities:
  --append-code '<R statement>'
      Append R statement in temporary scratch environment (assignment allowed).
  --set-result-expr '<R expression>'
      Evaluate expression and return value via dput result file transport.
  --cache-code '<R statement>'
      Append R statement in cache scope (container: codex_cache in .GlobalEnv).
      Use for cache create/update/delete behavior.
  --clear-cache
      Clear cache contents and remove codex_cache binding from .GlobalEnv.
  --create-global-variable '<name>=<expr>'
      Create a new variable in .GlobalEnv (fails if name already exists).
  --modify-global-env '<R statement>'
      Modify existing global state via explicit global-eval statement.

Examples:
  interact_with_rstudio.sh --set-result-expr 'class(project_obj$sample_01)'
  interact_with_rstudio.sh \
    --append-code 'obj <- project_obj$sample_01' \
    --append-code 'plot_obj <- Seurat::DimPlot(obj)' \
    --set-result-expr 'head(plot_obj$data$colour)'
  interact_with_rstudio.sh --cache-code 'cached_prod <- (matrix(rnorm(9), 3) %*% matrix(rnorm(9), 3))'
  interact_with_rstudio.sh --cache-code 'rm(list = "cached_prod")'
  interact_with_rstudio.sh --clear-cache
EOF
}

APPEND_CODE_SNIPPETS=()
RESULT_EXPR=""
CACHE_CODE_SNIPPETS=()
CLEAR_CACHE=0
CREATE_GLOBAL_SPECS=()
MODIFY_GLOBAL_SNIPPETS=()

SESSION_DIR=""
REQUEST_ID="1"
RPOSTBACK_BIN=""
OUT_PATH=""
TIMEOUT_SECONDS="8"
IS_TEMP_OUT_PATH=0
PRINT_CODE=0
LOCK_WAIT_SECONDS="${LOCK_WAIT_SECONDS:-120}"
POST_TIMEOUT_RECOVERY_SECONDS="${POST_TIMEOUT_RECOVERY_SECONDS:-20}"
POST_TIMEOUT_POLL_INTERVAL_SECONDS="${POST_TIMEOUT_POLL_INTERVAL_SECONDS:-1}"
TIMEOUT_MARKER_TTL_SECONDS="${TIMEOUT_MARKER_TTL_SECONDS:-900}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RPC_SCRIPT="$SCRIPT_DIR/communicate_with_rstudio_console_with_rpc_low_level.sh"
CACHE_ENV_NAME="codex_cache"
SESSION_LOCK_PATH=""
SESSION_TIMEOUT_MARKER_PATH=""
SESSION_LOCK_FD=""
LAST_TRANSPORT_PROBE_OUTPUT=""
LAST_R_ERROR_FEEDBACK=""

trim() {
  local value="$1"
  value="${value#"${value%%[![:space:]]*}"}"
  value="${value%"${value##*[![:space:]]}"}"
  printf '%s' "$value"
}

contains_regex() {
  local value="$1"
  local regex="$2"
  if printf '%s' "$value" | grep -Eiq -- "$regex"; then
    return 0
  fi
  return 1
}

escape_for_r_string() {
  local value="$1"
  value="${value//\\/\\\\}"
  value="${value//\"/\\\"}"
  value="${value//$'\n'/\\n}"
  printf '%s' "$value"
}

print_last_r_error_feedback() {
  local diag_out_path=""
  local diag_out_path_escaped=""
  local diag_code=""
  local diag_content=""
  local -a diag_rpc_args=()
  LAST_R_ERROR_FEEDBACK=""

  diag_out_path="$(mktemp /tmp/codex_rstudio_last_error.XXXXXX.txt)"
  diag_out_path_escaped="$(escape_for_r_string "$diag_out_path")"
  diag_code=".codex_diag_path <- \"${diag_out_path_escaped}\"; .codex_diag_msg <- tryCatch(geterrmessage(), error = function(e) conditionMessage(e)); .codex_diag_tb <- tryCatch(capture.output(traceback()), error = function(e) character(0)); .codex_diag <- c(.codex_diag_msg, if (length(.codex_diag_tb) > 0) c(\"--- traceback ---\", .codex_diag_tb) else character(0)); writeLines(.codex_diag, .codex_diag_path)"

  diag_rpc_args=(--code "$diag_code" --isolate-code 1 --id "$REQUEST_ID")
  if [[ -n "$SESSION_DIR" ]]; then
    diag_rpc_args+=(--session-dir "$SESSION_DIR")
  fi
  if [[ -n "$RPOSTBACK_BIN" ]]; then
    diag_rpc_args+=(--rpostback-bin "$RPOSTBACK_BIN")
  fi

  if bash "$RPC_SCRIPT" "${diag_rpc_args[@]}" >/dev/null 2>&1; then
    if [[ -s "$diag_out_path" ]]; then
      diag_content="$(cat "$diag_out_path")"
      LAST_R_ERROR_FEEDBACK="$diag_content"
      if [[ -n "$(trim "$diag_content")" ]]; then
        echo "R session feedback after timeout:" >&2
        printf '%s\n' "$diag_content" >&2
      fi
    fi
  fi

  rm -f "$diag_out_path"
}

diagnostic_indicates_parse_error() {
  local diag="$1"
  if [[ -z "$(trim "$diag")" ]]; then
    return 1
  fi
  if contains_regex "$diag" 'Error:[[:space:]]*unexpected'; then
    return 0
  fi
  if contains_regex "$diag" 'parse[[:space:]-]*error'; then
    return 0
  fi
  if contains_regex "$diag" 'syntax[[:space:]-]*error'; then
    return 0
  fi
  return 1
}

emit_status() {
  local status="$1"
  local detail="${2-}"
  if [[ -n "$detail" ]]; then
    echo "INTERACT_STATUS:${status}:${detail}" >&2
    return
  fi
  echo "INTERACT_STATUS:${status}" >&2
}

resolve_session_dir() {
  if [[ -n "$SESSION_DIR" ]]; then
    if [[ ! -f "$SESSION_DIR/session-persistent-state" ]]; then
      echo "Specified --session-dir is missing session-persistent-state: $SESSION_DIR" >&2
      exit 1
    fi
    return
  fi

  SESSION_DIR="$(ls -dt "$HOME"/.local/share/rstudio/sessions/active/session-* 2>/dev/null | head -n1 || true)"
  if [[ -z "$SESSION_DIR" || ! -f "$SESSION_DIR/session-persistent-state" ]]; then
    echo "Unable to locate an active RStudio session state file." >&2
    exit 1
  fi
}

load_session_environment() {
  local env_file=""
  env_file="$SESSION_DIR/suspended-session-data/environment_vars"
  if [[ ! -f "$env_file" ]]; then
    return
  fi

  # The environment file is generated by RStudio and contains simple KEY="value" entries.
  # Export all variables from the current session context so postback transport
  # can resolve local stream/socket settings consistently.
  set -a
  source "$env_file"
  set +a
}

setup_session_state_paths() {
  local session_key=""
  session_key="$(basename "$SESSION_DIR")"
  if [[ -z "$session_key" ]]; then
    session_key="unknown-session"
  fi

  SESSION_LOCK_PATH="/tmp/codex_rstudio_${session_key}.lock"
  SESSION_TIMEOUT_MARKER_PATH="/tmp/codex_rstudio_${session_key}.timeout"
}

acquire_session_lock() {
  exec {SESSION_LOCK_FD}>"$SESSION_LOCK_PATH"
  if ! flock -w "$LOCK_WAIT_SECONDS" "$SESSION_LOCK_FD"; then
    emit_status "transport_error" "session_lock_timeout"
    echo "Timed out waiting for session lock: $SESSION_LOCK_PATH" >&2
    exit 1
  fi
}

clear_timeout_marker() {
  if [[ -n "$SESSION_TIMEOUT_MARKER_PATH" ]]; then
    rm -f "$SESSION_TIMEOUT_MARKER_PATH"
  fi
}

mark_timeout_marker() {
  if [[ -n "$SESSION_TIMEOUT_MARKER_PATH" ]]; then
    date +%s >"$SESSION_TIMEOUT_MARKER_PATH"
  fi
}

probe_transport_ready() {
  local probe_output=""
  local -a probe_args=()

  probe_args=(--code "invisible(NULL)" --isolate-code 1 --id "$REQUEST_ID")
  if [[ -n "$SESSION_DIR" ]]; then
    probe_args+=(--session-dir "$SESSION_DIR")
  fi
  if [[ -n "$RPOSTBACK_BIN" ]]; then
    probe_args+=(--rpostback-bin "$RPOSTBACK_BIN")
  fi

  if probe_output="$(bash "$RPC_SCRIPT" "${probe_args[@]}" 2>&1)"; then
    LAST_TRANSPORT_PROBE_OUTPUT="$probe_output"
    return 0
  fi

  LAST_TRANSPORT_PROBE_OUTPUT="$probe_output"
  return 1
}

wait_for_transport_ready() {
  local deadline=$((SECONDS + $1))
  while (( SECONDS < deadline )); do
    if probe_transport_ready; then
      return 0
    fi
    sleep "$POST_TIMEOUT_POLL_INTERVAL_SECONDS"
  done
  return 1
}

recover_previous_unknown_state() {
  local marker_content=""
  local now_epoch=0
  local marker_epoch=0

  if [[ -z "$SESSION_TIMEOUT_MARKER_PATH" || ! -f "$SESSION_TIMEOUT_MARKER_PATH" ]]; then
    return
  fi

  marker_content="$(cat "$SESSION_TIMEOUT_MARKER_PATH" 2>/dev/null || true)"
  marker_content="$(trim "$marker_content")"

  if [[ ! "$marker_content" =~ ^[0-9]+$ ]]; then
    rm -f "$SESSION_TIMEOUT_MARKER_PATH"
    return
  fi

  marker_epoch="$marker_content"
  now_epoch="$(date +%s)"
  if (( now_epoch - marker_epoch > TIMEOUT_MARKER_TTL_SECONDS )); then
    rm -f "$SESSION_TIMEOUT_MARKER_PATH"
    return
  fi

  echo "Detected prior unknown-state timeout. Waiting for transport readiness before sending a new RPC..." >&2
  if wait_for_transport_ready "$POST_TIMEOUT_RECOVERY_SECONDS"; then
    rm -f "$SESSION_TIMEOUT_MARKER_PATH"
    return
  fi

  emit_status "transport_error" "previous_timeout_unresolved"
  echo "Previous timeout remains unresolved; transport is still unavailable." >&2
  if [[ -n "$(trim "$LAST_TRANSPORT_PROBE_OUTPUT")" ]]; then
    echo "Last transport probe output:" >&2
    printf '%s\n' "$LAST_TRANSPORT_PROBE_OUTPUT" >&2
  fi
  exit 1
}

read_result_file() {
  local result_content=""

  if [[ ! -s "$OUT_PATH" ]]; then
    return 2
  fi

  result_content="$(cat "$OUT_PATH")"
  if [[ "$result_content" == __ERROR__:* ]]; then
    emit_status "runtime_error"
    echo "${result_content#__ERROR__:}" >&2
    return 1
  fi

  printf '%s\n' "$result_content"
  return 0
}

validate_identifier() {
  local value="$1"
  local label="$2"
  if [[ ! "$value" =~ ^[A-Za-z.][A-Za-z0-9._]*$ ]]; then
    echo "$label '$value' is invalid. Use a simple R identifier." >&2
    exit 2
  fi
}

validate_common_blocklist() {
  local code="$1"
  local label="$2"
  local -a blocked_patterns=(
    '<<-'
    '->>'
    '(^|[^[:alnum:]_.])(save|saveRDS|load|setwd|options|Sys\.setenv|library|require|attach|detach|sink|system|system2)[[:space:]]*\('
    '(^|[^[:alnum:]_.])(q|quit)[[:space:]]*\('
  )

  for regex in "${blocked_patterns[@]}"; do
    if contains_regex "$code" "$regex"; then
      echo "$label contains blocked pattern ($regex)." >&2
      exit 2
    fi
  done

  if contains_regex "$code" '(^|[^[:alnum:]_.])source[[:space:]]*\('; then
    if ! contains_regex "$code" 'source[[:space:]]*\([^)]*local[[:space:]]*='; then
      echo "$label uses source(...) without local= explicitly set." >&2
      exit 2
    fi
    if contains_regex "$code" 'source[[:space:]]*\([^)]*local[[:space:]]*=[[:space:]]*FALSE'; then
      echo "$label uses source(..., local = FALSE), which is not allowed." >&2
      exit 2
    fi
  fi
}

validate_assignment_free() {
  local code="$1"
  local label="$2"
  if contains_regex "$code" '<-'; then
    echo "$label cannot contain '<-' assignment." >&2
    exit 2
  fi
  if contains_regex "$code" '->'; then
    echo "$label cannot contain right-arrow assignment." >&2
    exit 2
  fi
}

validate_name_expr_spec() {
  local spec="$1"
  local capability_label="$2"
  local name_out_var="$3"
  local expr_out_var="$4"
  local name_part=""
  local expr_part=""
  local var_name=""
  local var_expr=""

  if [[ "$spec" != *"="* ]]; then
    echo "$capability_label requires '<name>=<expr>'." >&2
    exit 2
  fi

  name_part="${spec%%=*}"
  expr_part="${spec#*=}"
  var_name="$(trim "$name_part")"
  var_expr="$(trim "$expr_part")"

  if [[ -z "$var_name" || -z "$var_expr" ]]; then
    echo "$capability_label requires non-empty name and expression." >&2
    exit 2
  fi

  validate_identifier "$var_name" "$capability_label name"
  if [[ "$var_name" == "$CACHE_ENV_NAME" ]]; then
    echo "$capability_label name '$var_name' is reserved." >&2
    exit 2
  fi

  if contains_regex "$var_expr" '(<-|->|=)[[:space:]]*$'; then
    echo "$capability_label expression for '$var_name' looks incomplete." >&2
    exit 2
  fi

  validate_common_blocklist "$var_expr" "$capability_label expression '$var_name'"
  validate_assignment_free "$var_expr" "$capability_label expression '$var_name'"

  printf -v "$name_out_var" '%s' "$var_name"
  printf -v "$expr_out_var" '%s' "$var_expr"
}

validate_append_snippet() {
  local snippet="$1"
  if [[ -z "$(trim "$snippet")" ]]; then
    echo "--append-code cannot be empty." >&2
    exit 2
  fi
  validate_common_blocklist "$snippet" "Appended code"
  if contains_regex "$snippet" '(^|[^[:alnum:]_.])(\.GlobalEnv|globalenv[[:space:]]*\()'; then
    echo "Appended code cannot directly target .GlobalEnv." >&2
    exit 2
  fi
  if contains_regex "$snippet" "(^|[^[:alnum:]_.])${CACHE_ENV_NAME}([^[:alnum:]_.]|$)"; then
    echo "Appended code cannot directly target ${CACHE_ENV_NAME}. Use --cache-code." >&2
    exit 2
  fi
}

validate_result_expr() {
  local expr="$1"
  if [[ -z "$(trim "$expr")" ]]; then
    echo "--set-result-expr cannot be empty." >&2
    exit 2
  fi
  if [[ "$expr" == *$'\n'* ]]; then
    echo "--set-result-expr must be a single expression line." >&2
    exit 2
  fi
  validate_common_blocklist "$expr" "Result expression"
  validate_assignment_free "$expr" "Result expression"
}

validate_modify_global_snippet() {
  local snippet="$1"
  if [[ -z "$(trim "$snippet")" ]]; then
    echo "--modify-global-env cannot be empty." >&2
    exit 2
  fi
  validate_common_blocklist "$snippet" "Global-modify code"
}

validate_cache_code_snippet() {
  local snippet="$1"
  if [[ -z "$(trim "$snippet")" ]]; then
    echo "--cache-code cannot be empty." >&2
    exit 2
  fi

  local -a blocked_patterns=(
    '<<-'
    '->>'
    '(^|[^[:alnum:]_.])(\.GlobalEnv|globalenv[[:space:]]*\()'
    '(^|[^[:alnum:]_.])(save|saveRDS|load|setwd|options|Sys\.setenv|library|require|attach|detach|sink|system|system2)[[:space:]]*\('
    '(^|[^[:alnum:]_.])(q|quit)[[:space:]]*\('
  )
  for regex in "${blocked_patterns[@]}"; do
    if contains_regex "$snippet" "$regex"; then
      echo "Cache code contains blocked pattern ($regex)." >&2
      exit 2
    fi
  done

  if contains_regex "$snippet" '(^|[^[:alnum:]_.])source[[:space:]]*\('; then
    if ! contains_regex "$snippet" 'source[[:space:]]*\([^)]*local[[:space:]]*='; then
      echo "Cache code uses source(...) without local= explicitly set." >&2
      exit 2
    fi
    if contains_regex "$snippet" 'source[[:space:]]*\([^)]*local[[:space:]]*=[[:space:]]*FALSE'; then
      echo "Cache code uses source(..., local = FALSE), which is not allowed." >&2
      exit 2
    fi
  fi
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --append-code)
      APPEND_CODE_SNIPPETS+=("${2-}")
      shift 2
      ;;
    --set-result-expr)
      RESULT_EXPR="${2-}"
      shift 2
      ;;
    --cache-code)
      CACHE_CODE_SNIPPETS+=("${2-}")
      shift 2
      ;;
    --clear-cache)
      CLEAR_CACHE=1
      shift
      ;;
    --create-global-variable)
      CREATE_GLOBAL_SPECS+=("${2-}")
      shift 2
      ;;
    --modify-global-env)
      MODIFY_GLOBAL_SNIPPETS+=("${2-}")
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
    --out)
      OUT_PATH="${2-}"
      shift 2
      ;;
    --timeout)
      TIMEOUT_SECONDS="${2-}"
      shift 2
      ;;
    --print-code)
      PRINT_CODE=1
      shift
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

if (( ${#APPEND_CODE_SNIPPETS[@]} == 0 )) \
  && [[ -z "$RESULT_EXPR" ]] \
  && (( ${#CACHE_CODE_SNIPPETS[@]} == 0 )) \
  && [[ "$CLEAR_CACHE" == "0" ]] \
  && (( ${#CREATE_GLOBAL_SPECS[@]} == 0 )) \
  && (( ${#MODIFY_GLOBAL_SNIPPETS[@]} == 0 )); then
  echo "At least one capability is required." >&2
  exit 2
fi

if ! [[ "$REQUEST_ID" =~ ^[0-9]+$ ]]; then
  echo "--id must be an integer." >&2
  exit 2
fi

if ! [[ "$TIMEOUT_SECONDS" =~ ^[0-9]+$ ]]; then
  echo "--timeout must be an integer number of seconds." >&2
  exit 2
fi

if ! [[ "$LOCK_WAIT_SECONDS" =~ ^[0-9]+$ ]]; then
  echo "LOCK_WAIT_SECONDS must be an integer number of seconds." >&2
  exit 2
fi

if ! [[ "$POST_TIMEOUT_RECOVERY_SECONDS" =~ ^[0-9]+$ ]]; then
  echo "POST_TIMEOUT_RECOVERY_SECONDS must be an integer number of seconds." >&2
  exit 2
fi

if ! [[ "$TIMEOUT_MARKER_TTL_SECONDS" =~ ^[0-9]+$ ]]; then
  echo "TIMEOUT_MARKER_TTL_SECONDS must be an integer number of seconds." >&2
  exit 2
fi

if [[ -n "$OUT_PATH" && -z "$RESULT_EXPR" ]]; then
  echo "--out can only be used with --set-result-expr." >&2
  exit 2
fi

for snippet in "${APPEND_CODE_SNIPPETS[@]}"; do
  validate_append_snippet "$snippet"
done
for snippet in "${CACHE_CODE_SNIPPETS[@]}"; do
  validate_cache_code_snippet "$snippet"
done
for snippet in "${MODIFY_GLOBAL_SNIPPETS[@]}"; do
  validate_modify_global_snippet "$snippet"
done
if [[ -n "$RESULT_EXPR" ]]; then
  validate_result_expr "$RESULT_EXPR"
fi

resolve_session_dir
load_session_environment
setup_session_state_paths
acquire_session_lock
recover_previous_unknown_state

R_EXEC_LINES=()
R_CREATE_GLOBAL_LINES=()
R_CACHE_CODE_LINES=()
R_CLEAR_CACHE_LINES=()
R_MODIFY_GLOBAL_LINES=()
R_STATIC_ALLOWED_ADDED_LINES=()
R_STATIC_ALLOWED_REMOVED_LINES=()
HAS_RESULT_EXPR=0
RESULT_OUT_PATH_ESCAPED=""

if (( ${#CACHE_CODE_SNIPPETS[@]} > 0 )); then
  R_STATIC_ALLOWED_ADDED_LINES+=(".codex_allow_create_cache <- TRUE")
fi

if [[ "$CLEAR_CACHE" == "1" ]]; then
  R_STATIC_ALLOWED_REMOVED_LINES+=(".codex_allowed_removed <- c(.codex_allowed_removed, \"${CACHE_ENV_NAME}\")")
  R_CLEAR_CACHE_LINES+=("if (exists(\"${CACHE_ENV_NAME}\", envir = .GlobalEnv, inherits = FALSE)) { .codex_cache_to_clear <- get(\"${CACHE_ENV_NAME}\", envir = .GlobalEnv, inherits = FALSE); if (is.environment(.codex_cache_to_clear)) { .codex_cache_names <- ls(envir = .codex_cache_to_clear, all.names = TRUE); if (length(.codex_cache_names) > 0) rm(list = .codex_cache_names, envir = .codex_cache_to_clear) }; rm(list = \"${CACHE_ENV_NAME}\", envir = .GlobalEnv) }")
fi

for snippet in "${APPEND_CODE_SNIPPETS[@]}"; do
  R_EXEC_LINES+=("${snippet}")
done

if [[ -n "$RESULT_EXPR" ]]; then
  if [[ -z "$OUT_PATH" ]]; then
    OUT_PATH="$(mktemp "/tmp/codex_rstudio_capability_result_XXXXXX.txt")"
    IS_TEMP_OUT_PATH=1
  fi
  rm -f "$OUT_PATH"
  HAS_RESULT_EXPR=1
  RESULT_OUT_PATH_ESCAPED="$(escape_for_r_string "$OUT_PATH")"
  R_EXEC_LINES+=(".codex_result_out_path <- \"${RESULT_OUT_PATH_ESCAPED}\"")
  R_EXEC_LINES+=(".codex_result <- tryCatch((${RESULT_EXPR}), error = function(e) e)")
  R_EXEC_LINES+=("if (inherits(.codex_result, \"error\")) { writeLines(paste0(\"__ERROR__:\", conditionMessage(.codex_result)), .codex_result_out_path) } else { dput(.codex_result, file = .codex_result_out_path) }")
fi

declare -A seen_create_global=()
for spec in "${CREATE_GLOBAL_SPECS[@]}"; do
  global_name=""
  global_expr=""
  validate_name_expr_spec "$spec" "--create-global-variable" global_name global_expr
  if [[ -n "${seen_create_global[$global_name]+x}" ]]; then
    echo "--create-global-variable duplicates name '$global_name' in one invocation." >&2
    exit 2
  fi
  seen_create_global["$global_name"]=1
  R_STATIC_ALLOWED_ADDED_LINES+=(".codex_allowed_added <- c(.codex_allowed_added, \"${global_name}\")")
  R_CREATE_GLOBAL_LINES+=("if (exists(\"${global_name}\", envir = .GlobalEnv, inherits = FALSE)) stop(\"CREATE_NEW_GLOBAL_VARIABLE refused: '${global_name}' already exists in .GlobalEnv\")")
  R_CREATE_GLOBAL_LINES+=("${global_name} <- (${global_expr})")
  R_CREATE_GLOBAL_LINES+=("assign(\"${global_name}\", ${global_name}, envir = .GlobalEnv)")
done

for snippet in "${CACHE_CODE_SNIPPETS[@]}"; do
  escaped_snippet="$(escape_for_r_string "$snippet")"
  R_CACHE_CODE_LINES+=("if (!exists(\"${CACHE_ENV_NAME}\", envir = .GlobalEnv, inherits = FALSE)) stop(\"CACHE_CODE refused: ${CACHE_ENV_NAME} does not exist\")")
  R_CACHE_CODE_LINES+=("eval(parse(text = \"${escaped_snippet}\"), envir = get(\"${CACHE_ENV_NAME}\", envir = .GlobalEnv, inherits = FALSE))")
done

for snippet in "${MODIFY_GLOBAL_SNIPPETS[@]}"; do
  escaped_snippet="$(escape_for_r_string "$snippet")"
  R_MODIFY_GLOBAL_LINES+=("eval(parse(text = \"${escaped_snippet}\"), envir = .GlobalEnv)")
done

R_EXEC_CODE=""
if (( ${#R_EXEC_LINES[@]} > 0 )); then
  R_EXEC_CODE="$(printf '%s;\n' "${R_EXEC_LINES[@]}")"
fi

R_CREATE_GLOBAL_CODE=""
if (( ${#R_CREATE_GLOBAL_LINES[@]} > 0 )); then
  R_CREATE_GLOBAL_CODE="$(printf '%s;\n' "${R_CREATE_GLOBAL_LINES[@]}")"
fi

R_CACHE_CODE=""
if (( ${#R_CACHE_CODE_LINES[@]} > 0 )); then
  R_CACHE_CODE="$(printf '%s;\n' "${R_CACHE_CODE_LINES[@]}")"
fi

R_CLEAR_CACHE_CODE=""
if (( ${#R_CLEAR_CACHE_LINES[@]} > 0 )); then
  R_CLEAR_CACHE_CODE="$(printf '%s;\n' "${R_CLEAR_CACHE_LINES[@]}")"
fi

R_MODIFY_GLOBAL_CODE=""
if (( ${#R_MODIFY_GLOBAL_LINES[@]} > 0 )); then
  R_MODIFY_GLOBAL_CODE="$(printf '%s;\n' "${R_MODIFY_GLOBAL_LINES[@]}")"
fi

R_STATIC_ALLOWED_ADDED_CODE=""
if (( ${#R_STATIC_ALLOWED_ADDED_LINES[@]} > 0 )); then
  R_STATIC_ALLOWED_ADDED_CODE="$(printf '%s;\n' "${R_STATIC_ALLOWED_ADDED_LINES[@]}")"
fi

R_STATIC_ALLOWED_REMOVED_CODE=""
if (( ${#R_STATIC_ALLOWED_REMOVED_LINES[@]} > 0 )); then
  R_STATIC_ALLOWED_REMOVED_CODE="$(printf '%s;\n' "${R_STATIC_ALLOWED_REMOVED_LINES[@]}")"
fi

R_CODE="\
.codex_before <- ls(envir = .GlobalEnv, all.names = TRUE);\
.codex_allowed_added <- character(0);\
.codex_allowed_removed <- character(0);\
.codex_allow_create_cache <- FALSE;\
${R_STATIC_ALLOWED_ADDED_CODE};\
${R_STATIC_ALLOWED_REMOVED_CODE};\
if (.codex_allow_create_cache && !exists(\"${CACHE_ENV_NAME}\", envir = .GlobalEnv, inherits = FALSE)) {\
  assign(\"${CACHE_ENV_NAME}\", new.env(parent = .GlobalEnv), envir = .GlobalEnv);\
  .codex_allowed_added <- c(.codex_allowed_added, \"${CACHE_ENV_NAME}\")\
};\
.codex_cache_env <- if (exists(\"${CACHE_ENV_NAME}\", envir = .GlobalEnv, inherits = FALSE)) get(\"${CACHE_ENV_NAME}\", envir = .GlobalEnv, inherits = FALSE) else NULL;\
if (!is.null(.codex_cache_env) && !identical(parent.env(.codex_cache_env), .GlobalEnv)) parent.env(.codex_cache_env) <- .GlobalEnv;\
.codex_temp_env <- new.env(parent = if (!is.null(.codex_cache_env)) .codex_cache_env else .GlobalEnv);\
.codex_result_out_fallback <- \"${RESULT_OUT_PATH_ESCAPED}\";\
.codex_exec_error <- tryCatch({\
with(.codex_temp_env, {\
${R_EXEC_CODE}\
${R_CREATE_GLOBAL_CODE}\
});\
${R_CACHE_CODE}\
${R_CLEAR_CACHE_CODE}\
${R_MODIFY_GLOBAL_CODE}\
NULL\
}, error = function(e) e);\
if (!is.null(.codex_exec_error) && ${HAS_RESULT_EXPR} == 1 && nzchar(.codex_result_out_fallback) && !file.exists(.codex_result_out_fallback)) {\
  writeLines(paste0(\"__ERROR__:\", conditionMessage(.codex_exec_error)), .codex_result_out_fallback)\
};\
if (!is.null(.codex_exec_error)) stop(conditionMessage(.codex_exec_error));\
.codex_after <- ls(envir = .GlobalEnv, all.names = TRUE);\
.codex_new <- setdiff(.codex_after, .codex_before);\
.codex_removed <- setdiff(.codex_before, .codex_after);\
.codex_unexpected_new <- setdiff(.codex_new, .codex_allowed_added);\
.codex_unexpected_removed <- setdiff(.codex_removed, .codex_allowed_removed);\
if (length(.codex_unexpected_new) > 0 || length(.codex_unexpected_removed) > 0) stop(sprintf(\"Global environment leak detected (added: %s | removed: %s)\", paste(.codex_unexpected_new, collapse = \",\"), paste(.codex_unexpected_removed, collapse = \",\")))\
"

if [[ "$PRINT_CODE" == "1" ]]; then
  echo "Generated R code:" >&2
  printf '%s\n' "$R_CODE" >&2
fi

RPC_ARGS=(--code "$R_CODE" --isolate-code 1 --id "$REQUEST_ID" --session-dir "$SESSION_DIR")
if [[ -n "$RPOSTBACK_BIN" ]]; then
  RPC_ARGS+=(--rpostback-bin "$RPOSTBACK_BIN")
fi

if [[ -n "$RESULT_EXPR" ]]; then
  RPC_LOG_FILE="$(mktemp /tmp/codex_interact_with_rstudio.XXXXXX)"
  cleanup() {
    rm -f "$RPC_LOG_FILE"
    if [[ "$IS_TEMP_OUT_PATH" == "1" ]]; then
      rm -f "$OUT_PATH"
    fi
  }
  trap cleanup EXIT

  if ! bash "$RPC_SCRIPT" "${RPC_ARGS[@]}" >"$RPC_LOG_FILE" 2>&1; then
    emit_status "transport_error" "send_failed"
    cat "$RPC_LOG_FILE" >&2 || true
    echo "Failed to send RPC request." >&2
    exit 1
  fi

  DEADLINE=$((SECONDS + TIMEOUT_SECONDS))
  while (( SECONDS < DEADLINE )); do
    if read_result_file; then
      clear_timeout_marker
      exit 0
    fi

    RESULT_FILE_RC=$?
    if [[ "$RESULT_FILE_RC" == "1" ]]; then
      clear_timeout_marker
      exit 1
    fi

    sleep 0.2
  done

  mark_timeout_marker
  echo "Timed out waiting for result file: $OUT_PATH" >&2
  if [[ -s "$RPC_LOG_FILE" ]]; then
    echo "RPC transport output:" >&2
    cat "$RPC_LOG_FILE" >&2
  fi
  print_last_r_error_feedback

  if diagnostic_indicates_parse_error "$LAST_R_ERROR_FEEDBACK" && probe_transport_ready; then
    clear_timeout_marker
    emit_status "parse_error"
    echo "Detected parse error before result file materialization." >&2
    exit 1
  fi

  TRANSPORT_RECOVERED=0
  RECOVERY_DEADLINE=$((SECONDS + POST_TIMEOUT_RECOVERY_SECONDS))
  while (( SECONDS < RECOVERY_DEADLINE )); do
    if read_result_file; then
      clear_timeout_marker
      exit 0
    fi

    RESULT_FILE_RC=$?
    if [[ "$RESULT_FILE_RC" == "1" ]]; then
      clear_timeout_marker
      exit 1
    fi

    if probe_transport_ready; then
      TRANSPORT_RECOVERED=1
      break
    fi

    sleep "$POST_TIMEOUT_POLL_INTERVAL_SECONDS"
  done

  if read_result_file; then
    clear_timeout_marker
    exit 0
  fi

  RESULT_FILE_RC=$?
  if [[ "$RESULT_FILE_RC" == "1" ]]; then
    clear_timeout_marker
    exit 1
  fi

  if [[ "$TRANSPORT_RECOVERED" == "1" ]]; then
    emit_status "unknown" "timed_out_no_result_transport_ready"
    echo "Request state is unknown after timeout: transport recovered, but no result file was produced." >&2
  else
    emit_status "unknown" "timed_out_transport_unavailable"
    echo "Request state is unknown after timeout: transport remained unavailable during recovery window." >&2
    if [[ -n "$(trim "$LAST_TRANSPORT_PROBE_OUTPUT")" ]]; then
      echo "Last transport probe output:" >&2
      printf '%s\n' "$LAST_TRANSPORT_PROBE_OUTPUT" >&2
    fi
  fi

  exit 1
fi

if ! bash "$RPC_SCRIPT" "${RPC_ARGS[@]}"; then
  emit_status "transport_error" "send_failed"
  exit 1
fi

clear_timeout_marker
