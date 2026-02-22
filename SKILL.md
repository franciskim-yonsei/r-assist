---
name: r-assist
description: Trigger for prompts where correctness depends on user's live RStudio session state. Rather than asking the user for more context, interrogate the session yourself. Use when a prompt references concrete in-session objects/expressions and asks for current values, levels, labels, dimensions, or concrete failures.
---

# Assist with R analysis

## Overview

-   Interrogate live RStudio session via `bash SKILL_DIR/scripts/interact_with_rstudio.sh` (where `SKILL_DIR` refers to the directory containing this `SKILL.md` file).
-   Use your capabilities build a call to the wrapper script that will directly send code to the live Rstudio console.
-   Export only minimal live session state, then continue in one persistent background R terminal with short, line-by-line commands.

## Workflow

1.  Identify the minimum objects/functions needed from live RStudio.
2.  Classify the task:
    -   One-shot read/check: send code directly to the live console to avoid expensive exports.
    -   Experimentation/comparison/tuning: use `R_STATE_EXPORT` once, then continue in one persistent background R session, to minimize console pollution and accidental user-facing side effects.
3.  Choose payload shape to minimize serialization cost (fewest objects possible).
4.  Start one background R terminal and keep it open (`R --quiet --no-save`).
5.  Execute analysis incrementally in that same background R session, one short command per step.
6.  If the user expects live output, send back only final user-facing artifact(s) to live RStudio (for plots: one final `print(...)` by default).

## Capabilities

### Quick reference

| Capability | Purpose | Scope | Approval |
|------------------|------------------|------------------|------------------|
| `SET_RESULT_EXPR` (`--set-result-expr`) | Return one expression value via file transport | Temporary execution scope with global read access | Not required |
| `APPEND_CODE` (`--append-code`) | Stage helper statements for one invocation | Temporary scratch env | Not required |
| `R_STATE_EXPORT` (`--r-state-export`) | Persist one payload from live RStudio into a temp RDS file | Temporary local file path | Not required |
| `CREATE_NEW_GLOBAL_VARIABLE` (`--create-global-variable`) | Create new persistent `.GlobalEnv` binding | Global | Required |
| `MODIFY_GLOBAL_ENV` (`--modify-global-env`) | Mutate existing persistent state | Global | Required |

### Console-vs-background tradeoff

-   `APPEND_CODE` is low-cost and fast for simple checks, but it only creates temporary objects that expire after each wrapper call, which touches the live console every time.
-   `R_STATE_EXPORT` avoids repeated console calls, but costs serialization time and disk I/O.
-   Use `R_STATE_EXPORT` when:
    -   multiple follow-ups are likely on the same in-session objects,
    -   intermediate state will be reused,
    -   many intermediates are required that need not be visible to the user,
    -   repeated `APPEND_CODE` attempts would be expensive, or
    -   the task evaluates many alternatives (palettes, parameter grids, model variants, plot styles).
-   Use `APPEND_CODE` when follow-up is trivial or objects are very large and repeated exploration is unlikely.
-   RULE OF THUMB: pick your concern - choose `APPEND_CODE` to avoid expensive export; choose `R_STATE_EXPORT` to avoid console/plot clutter.

### `SET_RESULT_EXPR` (`--set-result-expr`)

Use for one final read-only expression.

-   Only one single-line expression, no assignments (`<-` prohibited!).
-   Multi-step prep goes in `APPEND_CODE`.

Example:

``` bash
bash SKILL_DIR/scripts/interact_with_rstudio.sh \
  --set-result-expr 'class(project_obj$sample_01)'
```

### `APPEND_CODE` (`--append-code`)

Use for temporary setup and single-shot probing.

-   Objects created here expire with the wrapper call.
-   Avoid repeated console interactions for iterative debugging.
-   Do not run exploratory loops that emit many plots in live RStudio by default.
-   For plot-selection tasks, reserve live `print(...)` for the final selected plot unless user explicitly requests live comparisons.
-   Prefer multiple simple `--append-code` lines rather than one complex `--append-code` expression.

``` bash
bash SKILL_DIR/scripts/interact_with_rstudio.sh \
  --append-code 'obj <- project_obj$sample_01' \
  --append-code 'plot_obj <- Seurat::DimPlot(obj)' \
  --set-result-expr 'head(plot_obj$data$colour)'
```

Special example: when plots must be visible to the user, make sure to use `print(...)` around calls that return plot objects (ggplot2/patchwork/Seurat plot builders).

``` bash
bash SKILL_DIR/scripts/interact_with_rstudio.sh \
  --append-code 'obj <- otic[[4]]' \
  --append-code 'print(Seurat::DimPlot(obj, reduction = "umap.rna"))'
```

### `R_STATE_EXPORT` (one-time extraction)

Use when follow-up is likely.

1.  Build the smallest possible payload expression from live objects in one call.
2.  Double-check: whole-object exports are rarely needed. Prefer exporting a minimal payload (`list(...)`) with only the fields needed for follow-up. Avoid exporting whole Seurat/SingleCellExperiment objects unless the user explicitly asks.
3.  Estimate export time before calling `--r-state-export`:
    -   Probe payload size in live R (`object.size(...)`) with `APPEND_CODE` + `SET_RESULT_EXPR`.
    -   Use a conservative estimate for `saveRDS(..., compress = "xz")`: `est_seconds = max(5, ceiling((bytes / (20 * 1024^2)) * 2))`.
4.  If `est_seconds > 60`, ask the user for approval before export.
5.  Set timeouts from the estimate before export:
    -   `--rpc-timeout` at least `est_seconds + 30`.
    -   `--timeout` at least `est_seconds + 60`.
6.  Run `--r-state-export` once approved.
7.  Script returns a path to the exported RDS.
8.  Open one persistent background R terminal and keep it alive for the task.
9.  Load with `readRDS()` and execute follow-up commands line by line in that same session.

Live extraction pattern:

``` bash
bash SKILL_DIR/scripts/interact_with_rstudio.sh \
  --append-code 'snap_obj <- project_obj$sample_01' \
  --r-state-export 'list(sample_obj = snap_obj, created = Sys.time())'
```

Background session pattern:

``` bash
# Start once and keep this session open for the whole task.
R --quiet --no-save
```

``` r
# Then execute commands incrementally in that same live terminal session.
snapshot <- readRDS("/absolute/path/from/state-export")
dim(snapshot$pca)
table(snapshot$cluster)
# Continue step-by-step; avoid sending a large script blob.
```

Cleanup:

``` r
unlink("/absolute/path/from/state-export")
```

Notes:

-   This background process has no shared memory with RStudio; load libraries explicitly as needed because attached packages in RStudio are not inherited.
-   Export only what is needed: smaller payloads are faster, cheaper, and less likely to block the live session.
-   Default to exporting derived tables, vectors, embeddings, metadata slices, or marker results instead of entire assay objects.
-   If package namespaces mismatch, stop and ask the user before continuing.
-   Keep the same background R process alive and reuse it across follow-up commands.
-   Do not submit multi-line all-at-once background scripts unless the user explicitly requests that style.

### `CREATE_NEW_GLOBAL_VARIABLE` (`--create-global-variable`)

Use only for explicit user-requested persistent `.GlobalEnv` binding changes.

### `MODIFY_GLOBAL_ENV` (`--modify-global-env`)

Use only for explicit user-requested mutation of existing `.GlobalEnv` state.

## Guardrails

### How to call wrapper scripts

-   Define `SKILL_DIR` as the directory containing this `SKILL.md`.
-   Always call `bash SKILL_DIR/scripts/interact_with_rstudio.sh` (expanded to absolute path); never call low-level socket helper scripts directly.
-   In Codex tool calls, run wrapper invocations with escalation (`sandbox_permissions=require_escalated`) by default; sandbox execution is a known false-failure mode for `rpostback`/local socket access.
-   For every escalated wrapper call, always provide `prefix_rule=["bash","SKILL_DIR/scripts/interact_with_rstudio.sh"]`; never include runtime flags/code in the prefix rule.
-   Set both wait controls explicitly on long or uncertain calls: `--rpc-timeout` for the send step and `--timeout` for result-file wait.
-   Treat tool `yield_time_ms` as output polling only, not process cancellation. Do not stack retries while a prior wrapper call is still running.
-   Prefer live runtime env vars (`RSTUDIO_SESSION_STREAM`, `RS_PORT_TOKEN`, `RSTUDIO_SESSION_PID`) when present. Do not blindly overwrite them with `suspended-session-data/environment_vars`, which may be stale.

### Hard code requirements

Run these checks before every invocation.

-   Reject `<<-`, `->>`, global `assign(...)`, global `rm/remove(...)`, and `source(..., local = FALSE)`.
-   Reject `save`, `saveRDS`, `load`, and file-creation calls in live-session calls.
-   Reject `setwd`, `options`, `Sys.setenv`, `attach`, `detach`, `sink`, `system`, `system2`, `q`, `quit`.
-   Keep `library()`/`require()` out of live-session calls unless explicitly requested by user intent.
-   For graphical commands in live-session calls, enforce `print(...)` around rendering expressions.

### Highly recommended: keep it simple.

-   Avoid complex one-liner construction like giant `list(...)` or heavy inline indexing in one command.
-   Avoid semicolon-separated multi-statement lines and deeply nested expressions.
-   Strongly prefer explicit intermediate variables and short commands that are easy to debug.
-   Keep one action per line in both `--append-code` and background R commands.
-   If a line fails, inspect with simple probes (`class(...)`, `names(...)`, `dim(...)`, `head(...)`) before continuing.
-   Never retry by making the same command more complex. Retry by splitting it into smaller steps.

### Other rules

-   Clean exported files when no longer needed.
-   Runtime R errors must be surfaced as `__ERROR__:<message>` in the result payload, never as indefinite waits.
-   Prefer one live wrapper call to capture state and one live wrapper call to render final result for experimentation tasks.
-   Avoid sending candidate-by-candidate updates to live RStudio unless the user explicitly asks for that interaction style.

## Troubleshooting

-   `RPC send timed out after <n>s.`: hard timeout fired while sending to RStudio. Check for lingering wrapper processes and stop them before retrying.
-   For `RPC send timed out` cases, check whether the live session is busy before retrying:
    -   Read `"$SESSION_DIR"/properites/executing` (busy when value is `1`).
    -   Read `"$SESSION_DIR"/properites/blocking_suspend` (lists blockers such as `Waiting for event: console_input` or `A child process is running`).
    -   Report this busy state to the user explicitly and ask them to finish/interrupt the running console task before retrying wrapper calls.
-   `rpostback timed out ...` with stale-looking metadata (`abend=1`, dead `env-session-pid`): treat this as a stale snapshot signal first, not a mandatory user refresh. Ensure caller preserves live runtime env vars instead of forcing snapshot env.
-   `Timed out waiting for result file: ...`: RPC send returned but no result payload arrived in time. Retry once with smaller payload or higher `--timeout`.
-   If `Timed out waiting for result file` follows `R_STATE_EXPORT`, re-estimate payload size/time, increase both `--rpc-timeout` and `--timeout`, or reduce payload scope and retry once.
-   Stale `/tmp/codex_rstudio_session-*.lock` with no active wrapper process: remove the stale lock, then retry once.
-   `rpostback did not return a JSON-RPC result (rc=1)` (including stale-looking `path:` details such as `/home/<user>/<stream>`): treat sandbox restriction as the default diagnosis; rerun the same single-segment command with escalation before attributing failure to the RStudio session.
-   Stale `rpostback.log` tail can mislead root-cause analysis; if log mtime did not change during the current invocation, do not treat that line as current.
-   `system error 1 (Operation not permitted)` from `rpostback`: rerun the same single-segment command with escalation.
-   `timed out` unknown-state: wait for session status and retry once.
-   `__SYNTAX_ERROR__`: regenerate the live-code snippets; parsing failed before execution.
-   `__ERROR__:<message>`: runtime error occurred while evaluating generated code (including missing objects); use the message as the failure signal and retry with corrected R snippet.
-   `Result expression cannot contain '<-' assignment.`: move assignments to `APPEND_CODE`.
-   Plot not shown: wrap plotting call in `print(...)`, e.g. `print(Seurat::DimPlot(...))`.
