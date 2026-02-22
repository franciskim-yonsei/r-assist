#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage:
  interact_with_rstudio.sh [options]
    [--append-code '<R statement>']...
    [--set-result-expr '<R expression>']
    [--r-state-export '<R expression>']
    [--create-global-variable '<name>=<expr>']...
    [--modify-global-env '<R statement>']

Options:
  --session-dir <dir>           Override active RStudio session directory
  --id <jsonrpc-id>             JSON-RPC request id (default: 1)
  --rpostback-bin <path>        Override rpostback binary path
  --out <path>                  Output file for result transport (optional)
  --timeout <seconds>           Wait timeout for result file (default: 8)
  --rpc-timeout <seconds>       Hard timeout for RPC send step (default: 12)
  --print-code                  Print generated R snippet to stderr
  -h, --help                    Show this help

Capabilities:
  --append-code '<R statement>'
      Append R statement in temporary scratch environment (assignment allowed).
  --set-result-expr '<R expression>'
      Evaluate expression and return value via dput result file transport.
  --r-state-export '<R expression>'
      Serialize expression with saveRDS to temp file and return path.
  --create-global-variable '<name>=<expr>'
      Create a new variable in .GlobalEnv (fails if name already exists).
  --modify-global-env '<R statement>'
      Modify existing global state via explicit global-eval statement.

Examples:
  bash scripts/interact_with_rstudio.sh \
    --set-result-expr 'class(project_obj$sample_01)'
  bash scripts/interact_with_rstudio.sh \
    --append-code 'obj <- project_obj$sample_01' \
    --append-code 'plot_obj <- Seurat::DimPlot(obj)' \
    --set-result-expr 'head(plot_obj$data$colour)'
  bash scripts/interact_with_rstudio.sh \
    --append-code 'snap_obj <- project_obj$sample_01' \
    --r-state-export 'list(sample_obj = snap_obj, created = Sys.time())'
USAGE
}

APPEND_CODE_SNIPPETS=()
RESULT_EXPR=""
STATE_EXPORT_EXPR=""
CREATE_GLOBAL_SPECS=()
MODIFY_GLOBAL_SNIPPETS=()

SESSION_DIR=""
REQUEST_ID="1"
RPOSTBACK_BIN=""
OUT_PATH=""
TIMEOUT_SECONDS="8"
RPC_TIMEOUT_SECONDS="12"
IS_TEMP_OUT_PATH=0
EXPECT_RESULT=0
PRINT_CODE=0
STATE_EXPORT_PATH=""

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RPC_SCRIPT="$SCRIPT_DIR/communicate_with_rstudio_console_with_rpc_low_level.sh"

cleanup_temp_files() {
  local exit_code=$?
  if [[ "$IS_TEMP_OUT_PATH" == "1" && -n "$OUT_PATH" ]]; then
    rm -f "$OUT_PATH"
  fi
  if [[ "$exit_code" -ne 0 && -n "$STATE_EXPORT_PATH" ]]; then
    rm -f "$STATE_EXPORT_PATH"
  fi
}

trap cleanup_temp_files EXIT

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

join_lines() {
  local line
  local out=""
  for line in "$@"; do
    out+="${line}"$'\n'
  done
  printf '%s' "$out"
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

validate_append_file_restrictions() {
  local code="$1"
  local -a blocked_patterns=(
    '(^|[^[:alnum:]_.])(write|writeLines|write\.csv|write\.csv2|write\.delim|write\.delim2|write\.table|fwrite|cat|saveRDS|save|load|file\.create|dir\.create|unlink|file\.remove|file\.rename|file\.copy|file\.append|download\.file|png|jpeg|svg|bmp|tiff|pdf|postscript|quartz|x11)[[:space:]]*\('
  )

  for regex in "${blocked_patterns[@]}"; do
    if contains_regex "$code" "$regex"; then
      echo "APPEND_CODE may not write files." >&2
      exit 2
    fi
  done
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

validate_identifier() {
  local value="$1"
  local label="$2"
  if [[ ! "$value" =~ ^[A-Za-z.][A-Za-z0-9._]*$ ]]; then
    echo "$label '$value' is not a valid identifier." >&2
    exit 2
  fi
}

validate_name_expr_spec() {
  local spec="$1"
  local capability_label="$2"
  local name_out_var="$3"
  local expr_out_var="$4"

  if [[ "$spec" != *"="* ]]; then
    echo "$capability_label requires '<name>=<expr>'." >&2
    exit 2
  fi

  local name_part="${spec%%=*}"
  local expr_part="${spec#*=}"
  local var_name="$(trim "$name_part")"
  local var_expr="$(trim "$expr_part")"

  if [[ -z "$var_name" || -z "$var_expr" ]]; then
    echo "$capability_label requires non-empty name and expression." >&2
    exit 2
  fi

  validate_identifier "$var_name" "$capability_label name"
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
  validate_append_file_restrictions "$snippet"
}

validate_result_expr() {
  local expr="$1"
  if [[ -z "$(trim "$expr")" ]]; then
    echo "--set-result-expr cannot be empty." >&2
    exit 2
  fi
  if [[ "$expr" == *$'\n'* ]]; then
    echo "--set-result-expr must be one line." >&2
    exit 2
  fi
  validate_common_blocklist "$expr" "Result expression"
  validate_assignment_free "$expr" "Result expression"
}

validate_state_export_expr() {
  local expr="$1"
  if [[ -z "$(trim "$expr")" ]]; then
    echo "--r-state-export cannot be empty." >&2
    exit 2
  fi
  if [[ "$expr" == *$'\n'* ]]; then
    echo "--r-state-export must be one line." >&2
    exit 2
  fi
  validate_common_blocklist "$expr" "R_STATE_EXPORT expression"
  validate_assignment_free "$expr" "R_STATE_EXPORT expression"
}

validate_modify_global_snippet() {
  local snippet="$1"
  if [[ -z "$(trim "$snippet")" ]]; then
    echo "--modify-global-env cannot be empty." >&2
    exit 2
  fi
  validate_common_blocklist "$snippet" "Global-modify code"
}

extract_state_value() {
  local file="$1"
  local key="$2"
  sed -n "s/^${key}=\"\\(.*\\)\"/\\1/p" "$file" | head -n1
}

extract_env_value() {
  local file="$1"
  local key="$2"
  sed -n "s/^${key}=\"\\(.*\\)\"/\\1/p" "$file" | head -n1
}

session_pid_is_alive() {
  local pid="$1"
  if [[ -z "$pid" || ! "$pid" =~ ^[0-9]+$ ]]; then
    return 1
  fi
  if ! ps -p "$pid" >/dev/null 2>&1; then
    return 1
  fi
  if ps -p "$pid" -o args= 2>/dev/null | grep -q '/usr/lib/rstudio-server/bin/rsession'; then
    return 0
  fi
  return 1
}

infer_stream_from_pid() {
  local pid="$1"
  local pid_file=""
  local candidate_pid=""

  if [[ -z "$pid" || ! "$pid" =~ ^[0-9]+$ ]]; then
    return 1
  fi

  for pid_file in /var/run/rstudio-server/rstudio-rsession/*.pid; do
    [[ -e "$pid_file" ]] || continue
    candidate_pid="$(cat "$pid_file" 2>/dev/null || true)"
    if [[ "$candidate_pid" == "$pid" ]]; then
      basename "$pid_file" .pid
      return 0
    fi
  done

  return 1
}

resolve_session_dir() {
  local candidate=""
  local state_file=""
  local env_file=""
  local env_pid=""
  local current_pid="${RSTUDIO_SESSION_PID-}"

  if [[ -n "$SESSION_DIR" ]]; then
    if [[ ! -f "$SESSION_DIR/session-persistent-state" ]]; then
      echo "Specified --session-dir is missing session-persistent-state: $SESSION_DIR" >&2
      exit 1
    fi
    return
  fi

  # Prefer the session directory that matches the currently running session PID.
  if session_pid_is_alive "$current_pid"; then
    while IFS= read -r candidate; do
      [[ -n "$candidate" ]] || continue
      state_file="$candidate/session-persistent-state"
      env_file="$candidate/suspended-session-data/environment_vars"
      [[ -f "$state_file" ]] || continue
      [[ -f "$env_file" ]] || continue
      env_pid="$(extract_env_value "$env_file" "RSTUDIO_SESSION_PID")"
      if [[ "$env_pid" == "$current_pid" ]]; then
        SESSION_DIR="$candidate"
        break
      fi
    done < <(ls -dt "$HOME"/.local/share/rstudio/sessions/active/session-* 2>/dev/null || true)
  fi

  # Fallback to newest session with a state file.
  if [[ -z "$SESSION_DIR" ]]; then
    while IFS= read -r candidate; do
      [[ -n "$candidate" ]] || continue
      state_file="$candidate/session-persistent-state"
      if [[ -f "$state_file" ]]; then
        SESSION_DIR="$candidate"
        break
      fi
    done < <(ls -dt "$HOME"/.local/share/rstudio/sessions/active/session-* 2>/dev/null || true)
  fi

  if [[ -z "$SESSION_DIR" ]]; then
    echo "Unable to locate an active RStudio session state file." >&2
    exit 1
  fi
}

load_session_environment() {
  local env_file="$SESSION_DIR/suspended-session-data/environment_vars"
  local current_stream="${RSTUDIO_SESSION_STREAM-}"
  local current_token="${RS_PORT_TOKEN-}"
  local current_pid="${RSTUDIO_SESSION_PID-}"
  local file_pid=""
  local inferred_stream=""

  # Prefer live env from the terminal when it already points to a running rsession.
  if [[ -n "$current_stream" && -n "$current_token" ]] && session_pid_is_alive "$current_pid"; then
    return
  fi

  # Otherwise use session snapshot env only when it points to a live rsession.
  if [[ -f "$env_file" ]]; then
    file_pid="$(extract_env_value "$env_file" "RSTUDIO_SESSION_PID")"
    if session_pid_is_alive "$file_pid"; then
      set -a
      source "$env_file"
      set +a
    fi
  fi

  # Last-resort fallback to snapshot env when still missing.
  if [[ (-z "${RSTUDIO_SESSION_STREAM-}" || -z "${RS_PORT_TOKEN-}") && -f "$env_file" ]]; then
    set -a
    source "$env_file"
    set +a
  fi

  # Derive stream from pid mapping when stream is missing but pid is known/alive.
  if [[ -z "${RSTUDIO_SESSION_STREAM-}" ]] && session_pid_is_alive "${RSTUDIO_SESSION_PID-}"; then
    inferred_stream="$(infer_stream_from_pid "${RSTUDIO_SESSION_PID-}" || true)"
    if [[ -n "$inferred_stream" ]]; then
      export RSTUDIO_SESSION_STREAM="$inferred_stream"
    fi
  fi
}

get_session_property_file() {
  local key="$1"
  local path_typo="$SESSION_DIR/properites/$key"
  local path_fixed="$SESSION_DIR/properties/$key"

  if [[ -f "$path_typo" ]]; then
    printf "%s" "$path_typo"
    return 0
  fi

  if [[ -f "$path_fixed" ]]; then
    printf "%s" "$path_fixed"
    return 0
  fi

  return 1
}

check_session_busy_before_rpc() {
  local executing_file=""
  local executing_value=""

  executing_file="$(get_session_property_file executing || true)"

  if [[ -n "$executing_file" ]]; then
    executing_value="$(tr -d "[:space:]" < "$executing_file" 2>/dev/null || true)"
  fi

  if [[ "$executing_value" == "1" ]]; then
    echo "RStudio session appears busy (executing=1)." >&2
    echo "Finish or interrupt the current console task, then retry." >&2
    return 1
  fi

  return 0
}

get_executing_flag_value() {
  local executing_file=""
  local executing_value=""

  executing_file="$(get_session_property_file executing || true)"
  if [[ -n "$executing_file" ]]; then
    executing_value="$(tr -d "[:space:]" < "$executing_file" 2>/dev/null || true)"
  fi

  if [[ -z "$executing_value" ]]; then
    echo "<missing>"
  else
    echo "$executing_value"
  fi
}

result_file_size_bytes() {
  local path="$1"
  if [[ ! -e "$path" ]]; then
    echo "0"
    return 0
  fi
  wc -c < "$path" 2>/dev/null | tr -d '[:space:]'
}

diagnose_result_wait_timeout() {
  local out_path="$1"
  local executing_value=""
  local out_exists="0"
  local out_size="0"
  local pid_value="${RSTUDIO_SESSION_PID-}"
  local pid_state="<missing>"
  local state_file="$SESSION_DIR/session-persistent-state"
  local abend_value=""
  local -a causes=()
  local causes_csv=""

  executing_value="$(get_executing_flag_value)"

  if [[ -e "$out_path" ]]; then
    out_exists="1"
  fi
  out_size="$(result_file_size_bytes "$out_path")"
  if [[ -z "$out_size" || ! "$out_size" =~ ^[0-9]+$ ]]; then
    out_size="0"
  fi

  if [[ -n "$pid_value" ]]; then
    if session_pid_is_alive "$pid_value"; then
      pid_state="alive"
    elif [[ "$pid_value" =~ ^[0-9]+$ ]]; then
      pid_state="dead_or_not_rsession"
    else
      pid_state="invalid"
    fi
  fi

  if [[ -f "$state_file" ]]; then
    abend_value="$(extract_state_value "$state_file" "abend")"
  fi
  if [[ -z "$abend_value" ]]; then
    abend_value="<missing>"
  fi

  if [[ "$executing_value" == "1" ]]; then
    causes+=("compute_still_running")
  fi
  if [[ "$out_exists" == "1" && "$out_size" == "0" && "$executing_value" != "1" ]]; then
    causes+=("handoff_or_write_delay")
  fi
  if [[ "$out_exists" == "0" ]]; then
    causes+=("output_path_unavailable")
  fi
  if [[ "$pid_state" == "dead_or_not_rsession" || "$pid_state" == "invalid" || "$abend_value" == "1" ]]; then
    causes+=("session_liveness_issue")
  fi
  if (( ${#causes[@]} == 0 )); then
    causes+=("unknown")
  fi

  causes_csv="$(IFS=,; echo "${causes[*]}")"
  echo "Timeout diagnostics: causes=${causes_csv}" >&2
  echo "Timeout diagnostics: executing=${executing_value} output_exists=${out_exists} output_size_bytes=${out_size} session_pid=${pid_value:-<missing>}(${pid_state}) abend=${abend_value}" >&2

  if [[ "$executing_value" == "1" ]]; then
    echo "Likely cause: R code is still running in the live console." >&2
    echo "Action: interrupt or wait for the current console task before retrying." >&2
  fi
  if [[ "$out_exists" == "1" && "$out_size" == "0" && "$executing_value" != "1" ]]; then
    echo "Possible cause: compute finished but result handoff/file write lagged." >&2
    echo "Action: increase --timeout, reduce payload size, and retry once." >&2
  fi
  if [[ "$out_exists" == "0" ]]; then
    echo "Possible cause: output file was removed or inaccessible while waiting." >&2
    echo "Action: verify /tmp availability and file permissions, then retry." >&2
  fi
  if [[ "$pid_state" == "dead_or_not_rsession" || "$pid_state" == "invalid" || "$abend_value" == "1" ]]; then
    echo "Possible cause: session snapshot points to a dead/restarted rsession." >&2
    echo "Action: re-resolve live runtime env vars and retry once." >&2
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
    --r-state-export)
      if [[ -n "$STATE_EXPORT_EXPR" ]]; then
        echo "Only one --r-state-export is allowed." >&2
        exit 2
      fi
      STATE_EXPORT_EXPR="${2-}"
      shift 2
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
    --rpc-timeout)
      RPC_TIMEOUT_SECONDS="${2-}"
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
  && [[ -z "$STATE_EXPORT_EXPR" ]] \
  && (( ${#CREATE_GLOBAL_SPECS[@]} == 0 )) \
  && (( ${#MODIFY_GLOBAL_SNIPPETS[@]} == 0 )); then
  echo "At least one capability is required." >&2
  exit 2
fi

if [[ -n "$STATE_EXPORT_EXPR" ]]; then
  if [[ -n "$RESULT_EXPR" ]] || (( ${#CREATE_GLOBAL_SPECS[@]} > 0 )) || (( ${#MODIFY_GLOBAL_SNIPPETS[@]} > 0 )); then
    echo "--r-state-export cannot be combined with --set-result-expr, --create-global-variable, or --modify-global-env." >&2
    exit 2
  fi
fi

if [[ ! "$REQUEST_ID" =~ ^[0-9]+$ ]]; then
  echo "--id must be an integer." >&2
  exit 2
fi

if [[ ! "$TIMEOUT_SECONDS" =~ ^[0-9]+$ ]]; then
  echo "--timeout must be an integer number of seconds." >&2
  exit 2
fi

if [[ ! "$RPC_TIMEOUT_SECONDS" =~ ^[0-9]+$ ]]; then
  echo "--rpc-timeout must be an integer number of seconds." >&2
  exit 2
fi

for snippet in "${APPEND_CODE_SNIPPETS[@]}"; do
  validate_append_snippet "$snippet"
done

if [[ -n "$RESULT_EXPR" ]]; then
  validate_result_expr "$RESULT_EXPR"
fi

if [[ -n "$STATE_EXPORT_EXPR" ]]; then
  validate_state_export_expr "$STATE_EXPORT_EXPR"
fi

for snippet in "${CREATE_GLOBAL_SPECS[@]}"; do
  global_name=""
  global_expr=""
  validate_name_expr_spec "$snippet" "--create-global-variable" global_name global_expr
  if [[ -z "$global_name" || -z "$global_expr" ]]; then
    exit 2
  fi
done

for snippet in "${MODIFY_GLOBAL_SNIPPETS[@]}"; do
  validate_modify_global_snippet "$snippet"
done

if [[ -n "$RESULT_EXPR" || -n "$STATE_EXPORT_EXPR" ]]; then
  EXPECT_RESULT=1
fi

if [[ "$EXPECT_RESULT" == "1" && -z "$OUT_PATH" ]]; then
  OUT_PATH="$(mktemp '/tmp/codex_rstudio_capability_result_XXXXXX.txt')"
  IS_TEMP_OUT_PATH=1
fi

if [[ -n "$STATE_EXPORT_EXPR" ]]; then
  STATE_EXPORT_PATH="$(mktemp '/tmp/codex_rstudio_state_XXXXXX.rds')"
fi

resolve_session_dir
load_session_environment

R_EXEC_LINES=()
R_CREATE_LINES=()
R_MODIFY_LINES=()
R_CREATE_NAMES=()

for snippet in "${APPEND_CODE_SNIPPETS[@]}"; do
  R_EXEC_LINES+=("$snippet")
done

if [[ -n "$RESULT_EXPR" ]]; then
  R_EXEC_LINES+=(".codex_result_expr <- tryCatch((${RESULT_EXPR}), error = function(e) e)")
fi

if [[ -n "$STATE_EXPORT_EXPR" ]]; then
  STATE_EXPORT_PATH_ESCAPED="$(escape_for_r_string "$STATE_EXPORT_PATH")"
  R_EXEC_LINES+=(".codex_state_export_path <- \"${STATE_EXPORT_PATH_ESCAPED}\"")
  R_EXEC_LINES+=(".codex_state_payload <- (${STATE_EXPORT_EXPR})")
  R_EXEC_LINES+=("saveRDS(.codex_state_payload, file = .codex_state_export_path, compress = \"xz\")")
  R_EXEC_LINES+=("rm(.codex_state_payload)")
  R_EXEC_LINES+=("if (!file.exists(.codex_state_export_path)) stop(\"State export file was not created\")")
  R_EXEC_LINES+=(".codex_result_expr <- .codex_state_export_path")
fi

for spec in "${CREATE_GLOBAL_SPECS[@]}"; do
  global_name=""
  global_expr=""
  validate_name_expr_spec "$spec" "--create-global-variable" global_name global_expr
  if (( ${#R_CREATE_NAMES[@]} > 0 )) && printf '%s\n' "${R_CREATE_NAMES[@]}" | grep -Fxq "$global_name"; then
    echo "--create-global-variable duplicates name '$global_name' in one invocation." >&2
    exit 2
  fi
  R_CREATE_NAMES+=("$global_name")
  R_CREATE_LINES+=("if (exists(\"$global_name\", envir = .GlobalEnv, inherits = FALSE)) stop(\"CREATE_NEW_GLOBAL_VARIABLE refused: '$global_name' already exists in .GlobalEnv\")")
  R_CREATE_LINES+=("$global_name <- (${global_expr})")
  R_CREATE_LINES+=("assign(\"$global_name\", $global_name, envir = .GlobalEnv)")
done

for snippet in "${MODIFY_GLOBAL_SNIPPETS[@]}"; do
  escaped_snippet="$(escape_for_r_string "$snippet")"
  R_MODIFY_LINES+=("eval(parse(text = \"${escaped_snippet}\"), envir = .GlobalEnv)")
done

R_ALLOWED_ADDED=""
if (( ${#R_CREATE_NAMES[@]} > 0 )); then
  R_ALLOWED_ADDED="$(printf '"%s",' "${R_CREATE_NAMES[@]}")"
  R_ALLOWED_ADDED="${R_ALLOWED_ADDED%,}"
fi

R_EXEC_BLOCK="$(join_lines "${R_EXEC_LINES[@]}")"
R_CREATE_BLOCK="$(join_lines "${R_CREATE_LINES[@]}")"
R_MODIFY_BLOCK="$(join_lines "${R_MODIFY_LINES[@]}")"
OUT_PATH_ESCAPED=""

if [[ "$EXPECT_RESULT" == "1" ]]; then
  OUT_PATH_ESCAPED="$(escape_for_r_string "$OUT_PATH")"
fi

R_CODE=".codex_before <- ls(envir = .GlobalEnv, all.names = TRUE)\n"
R_CODE+=".codex_allowed_added <- c(${R_ALLOWED_ADDED})\n"
R_CODE+=".codex_result_out_path <- \"${OUT_PATH_ESCAPED}\"\\n"
R_CODE+=".codex_result_written <- FALSE\\n"
R_CODE+=".codex_exec_result <- NULL\\n"
R_CODE+=".codex_exec_error <- tryCatch({\n"
R_CODE+="  .codex_exec_result <- with(new.env(parent = .GlobalEnv), {\n${R_EXEC_BLOCK}  })\n"
R_CODE+="  NULL\n"
if [[ -n "$R_CREATE_BLOCK" ]]; then
  R_CODE+="${R_CREATE_BLOCK}"
fi
if [[ -n "$R_MODIFY_BLOCK" ]]; then
  R_CODE+="${R_MODIFY_BLOCK}"
fi
R_CODE+="}, error = function(e) e)\n"
if [[ "$EXPECT_RESULT" == "1" ]]; then
  R_CODE+="if (!is.null(.codex_exec_error)) {\n"
  R_CODE+="  writeLines(paste0('__ERROR__:', conditionMessage(.codex_exec_error)), .codex_result_out_path)\n"
  R_CODE+="  .codex_result_written <- TRUE\n"
  R_CODE+="}\n"
  R_CODE+="if (is.null(.codex_exec_error) && is.null(.codex_exec_result)) {\n"
  R_CODE+="  writeLines('__ERROR__: no result produced', .codex_result_out_path)\n"
  R_CODE+="  .codex_result_written <- TRUE\n"
  R_CODE+="}\n"
  R_CODE+="if (is.null(.codex_exec_error) && inherits(.codex_exec_result, \"error\")) {\n"
  R_CODE+="  writeLines(paste0('__ERROR__:', conditionMessage(.codex_exec_result)), .codex_result_out_path)\n"
  R_CODE+="  .codex_result_written <- TRUE\n"
  R_CODE+="}\n"
  R_CODE+="if (is.null(.codex_exec_error) && !inherits(.codex_exec_result, \"error\") && !is.null(.codex_exec_result)) {\n"
  R_CODE+="  dput(.codex_exec_result, file = .codex_result_out_path)\n"
  R_CODE+="  .codex_result_written <- TRUE\n"
  R_CODE+="}\n"
fi
R_CODE+="if (!is.null(.codex_exec_error)) {\n"
R_CODE+="  stop(conditionMessage(.codex_exec_error))\n"
R_CODE+="}\n"
R_CODE+=".codex_after <- ls(envir = .GlobalEnv, all.names = TRUE)\n"
R_CODE+=".codex_new <- setdiff(.codex_after, .codex_before)\n"
R_CODE+=".codex_removed <- setdiff(.codex_before, .codex_after)\n"
R_CODE+=".codex_unexpected_new <- setdiff(.codex_new, .codex_allowed_added)\n"
R_CODE+=".codex_unexpected_removed <- setdiff(.codex_removed, character(0))\n"
R_CODE+="if (length(.codex_unexpected_new) > 0 || length(.codex_unexpected_removed) > 0) {\n"
R_CODE+="  stop(\"Global environment leak detected\")\n"
R_CODE+="}\n"
R_CODE="$(printf '%b' "$R_CODE")"

CODE_CHECK_PATH="$(mktemp '/tmp/codex_rstudio_check_XXXXXX.R')"
PARSE_LOG_PATH="$(mktemp '/tmp/codex_rstudio_check_parse_XXXXXX.txt')"
printf '%s' "$R_CODE" > "$CODE_CHECK_PATH"
if ! Rscript -e "parse(file = '${CODE_CHECK_PATH}')" >"$PARSE_LOG_PATH" 2>&1; then
  PARSE_OUT="$(cat "$PARSE_LOG_PATH")"
  rm -f "$CODE_CHECK_PATH" "$PARSE_LOG_PATH"
  echo "__SYNTAX_ERROR__" >&2
  echo "$PARSE_OUT" >&2
  if [[ "$EXPECT_RESULT" == "1" ]]; then
    {
      echo "__SYNTAX_ERROR__"
      echo "$PARSE_OUT"
    } > "$OUT_PATH"
  fi
  exit 2
fi
rm -f "$CODE_CHECK_PATH" "$PARSE_LOG_PATH"

if [[ "$PRINT_CODE" == "1" ]]; then
  echo "Generated R code:" >&2
  printf '%s\n' "$R_CODE" >&2
fi

RPC_ARGS=(--code "$R_CODE" --isolate-code 1 --id "$REQUEST_ID" --rpc-timeout "$RPC_TIMEOUT_SECONDS")
if [[ -n "$SESSION_DIR" ]]; then
  RPC_ARGS+=(--session-dir "$SESSION_DIR")
fi
if [[ -n "$RPOSTBACK_BIN" ]]; then
  RPC_ARGS+=(--rpostback-bin "$RPOSTBACK_BIN")
fi

if [[ "$EXPECT_RESULT" == "1" ]]; then
  if ! : > "$OUT_PATH"; then
    echo "Unable to clear output file: $OUT_PATH" >&2
    exit 1
  fi
fi

rpc_send() {
  local suppress_stdout="$1"
  local -a cmd=(bash "$RPC_SCRIPT" "${RPC_ARGS[@]}")

  if command -v timeout >/dev/null 2>&1; then
    if [[ "$suppress_stdout" == "1" ]]; then
      timeout --foreground --signal=TERM --kill-after=2 "${RPC_TIMEOUT_SECONDS}s" "${cmd[@]}" >/dev/null
    else
      timeout --foreground --signal=TERM --kill-after=2 "${RPC_TIMEOUT_SECONDS}s" "${cmd[@]}"
    fi
    local timeout_rc=$?
    if [[ "$timeout_rc" -eq 124 || "$timeout_rc" -eq 137 ]]; then
      echo "RPC send timed out after ${RPC_TIMEOUT_SECONDS}s." >&2
      return 124
    fi
    return "$timeout_rc"
  fi

  if [[ "$suppress_stdout" == "1" ]]; then
    "${cmd[@]}" >/dev/null
  else
    "${cmd[@]}"
  fi
}

if ! check_session_busy_before_rpc; then
  exit 1
fi

if [[ "$EXPECT_RESULT" == "1" ]]; then
  if ! rpc_send 1; then
    echo "Failed to send RPC request." >&2
    exit 1
  fi
else
  if ! rpc_send 0; then
    echo "Failed to send RPC request." >&2
    exit 1
  fi
fi

if [[ "$EXPECT_RESULT" == "1" ]]; then
  DEADLINE=$((SECONDS + TIMEOUT_SECONDS))
  while (( SECONDS < DEADLINE )); do
    if [[ -s "$OUT_PATH" ]]; then
      cat "$OUT_PATH"
      break
    fi
    sleep 0.2
  done

  if [[ ! -s "$OUT_PATH" ]]; then
    echo "Timed out waiting for result file: $OUT_PATH" >&2
    diagnose_result_wait_timeout "$OUT_PATH"
    exit 1
  fi
fi
