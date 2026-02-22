---
name: r-assist
description: Trigger for prompts where correctness depends on user's live RStudio session state. Rather than asking the user for more context, interrogate the session yourself. Use when a prompt references concrete in-session objects/expressions and asks for current values, levels, labels, dimensions, or concrete failures.
---

# Assist with R analysis

## Overview

Interrogate live RStudio session via `bash SKILL_DIR/scripts/interact_with_rstudio.sh` (where `SKILL_DIR` refers to the directory containing this `SKILL.md` file).

## Workflow

1.  Decide the mode of operation: A vs B. Consider fast-track decision; if impossible, deliberate.
2.  Write the required R code.
3.  Use your defined capabilities to build a call to the wrapper script.
4.  Make a call to `bash SKILL_DIR/scripts/interact_with_rstudio.sh` (where `SKILL_DIR` refers to the directory containing this `SKILL.md` file).
5.  (Mode B) Open a background R session (`R --quiet --no-save`) and continue analysis.
6.  Inspect output and iterate. If the user expects live output, send back only final user-facing artifact(s) to live RStudio (for plots: one final `print(...)` by default).

## Step 1. Decide mode of operation

### Quick reference

| Mode | Description | Pros | Cons | Use for |
|---------------|---------------|---------------|---------------|---------------|
| A | Carry out analysis directly in the live console | Avoids expensive exports | Objects expire. May clutter or block user console | One-shot reads/checks |
| B | Export once, then continue in background R session | Avoids blocking console with long costly analyses | Export may be costly | Experimentation, comparison, sweeps |

### Primary concerns

It is imperative that you consider the following constraints:

-   Any object you create directly in the console is temporary; it expires after each wrapper call.
-   R functions are slow. Any function you run directly in the console blocks out the user.
-   R serialization and disk I/O are also slow. Large exports may also block out the user.

Balance the cost of blocking the console with direct analysis (track A) vs. export (track B).

### Fast-track decision

Sometimes the task clearly belongs to a certain pattern and the optimal choice is obvious. Decide quickly and move on to step 2.

-   Choose mode A when export is costlier than analysis, i.e. when:
    -   computations are trivial,
    -   objects are very large, and/or
    -   repeated exploration is unlikely.
-   Choose mode B when analysis is costlier than export, i.e. when:
    -   the task evaluates many alternatives (parameter grids, model variants, plot styles),
    -   large intermediates have to be generated,
    -   objects are very small or may be trimmed down to small subsets/fields, and/or
    -   multiple expensive follow-ups are likely.

### Deliberate and discuss

Whenever the choice is not obvious, you must take care to identify the minimum scope of analysis. Discuss the optimal approach with the user.

1.  Identify the minimum objects/functions needed from live RStudio. Build the smallest possible payload expression from live objects in one call (fewest objects possible).
2.  Default to exporting derived tables, vectors, embeddings, metadata slices, or marker results instead of entire assay objects.
3.  Proceed to following steps to probe payload size in live R (`object.size(...)`).
4.  Use that information to estimate ETA for export: `est_seconds = max(5, ceiling(0.5 * size_in_MB + 10))`.
5.  If `est_seconds > 60`, ask the user for approval before export.

## Step 2. Write code

### Hard requirements

Run these checks for every line of code you write.

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

## Step 3. Build a call

### Quick reference

| Capability | Purpose | Scope | Approval |
|------------------|------------------|------------------|------------------|
| `SET_RESULT_EXPR` (`--set-result-expr`) | Return one expression value via file transport | Temporary execution scope with global read access | Not required |
| `APPEND_CODE` (`--append-code`) | Stage helper statements for one invocation | Temporary scratch env | Not required |
| `R_STATE_EXPORT` (`--r-state-export`) | Persist one payload from live RStudio into a temp RDS file | Temporary local file path | Not required |
| `CREATE_NEW_GLOBAL_VARIABLE` (`--create-global-variable`) | Create new persistent `.GlobalEnv` binding | Global | Required |
| `MODIFY_GLOBAL_ENV` (`--modify-global-env`) | Mutate existing persistent state | Global | Required |

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

1.  Script returns a path to the exported RDS.
2.  Open one persistent background R terminal and keep it alive for the task (`R --quiet --no-save`).
3.  Load with `readRDS()` and execute follow-up commands line by line in that same session.

Example:

``` bash
bash SKILL_DIR/scripts/interact_with_rstudio.sh \
  --append-code 'snap_obj <- project_obj$sample_01' \
  --r-state-export 'list(sample_obj = snap_obj, created = Sys.time())'
```

Notes:

-   This background process has no shared memory with RStudio; load libraries explicitly as needed because attached packages in RStudio are not inherited.
-   If package namespaces mismatch, stop and ask the user before continuing.
-   Keep the same background R process alive and reuse it across follow-up commands.
-   Do not submit multi-line all-at-once background scripts unless the user explicitly requests that style.

### `CREATE_NEW_GLOBAL_VARIABLE` (`--create-global-variable`)

Use only for explicit user-requested persistent `.GlobalEnv` binding changes.

### `MODIFY_GLOBAL_ENV` (`--modify-global-env`)

Use only for explicit user-requested mutation of existing `.GlobalEnv` state.

## Step 4. Call wrapper script

-   Define `SKILL_DIR` as the directory containing this `SKILL.md`.
-   Always call `bash SKILL_DIR/scripts/interact_with_rstudio.sh` (expanded to absolute path); never call low-level socket helper scripts directly.
-   In Codex tool calls, run wrapper invocations with escalation (`sandbox_permissions=require_escalated`) by default; sandbox execution is a known false-failure mode for `rpostback`/local socket access.
-   For every escalated wrapper call, always provide `prefix_rule=["bash","SKILL_DIR/scripts/interact_with_rstudio.sh"]`; never include runtime flags/code in the prefix rule.
-   Set both wait controls explicitly on long or uncertain calls: `--rpc-timeout` for the send step and `--timeout` for result-file wait.
-   Set timeouts using `est_seconds` computed in step 1before export:
    -   `--rpc-timeout` at least equal to `est_seconds`.
    -   `--timeout` at least `est_seconds + 90`.
-   Treat tool `yield_time_ms` as output polling only, not process cancellation. Do not stack retries while a prior wrapper call is still running.
-   Prefer live runtime env vars (`RSTUDIO_SESSION_STREAM`, `RS_PORT_TOKEN`, `RSTUDIO_SESSION_PID`) when present. Do not blindly overwrite them with `suspended-session-data/environment_vars`, which may be stale.

## Step 5. Working with background sessions

Example:

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

## Guardrails

-   Double-check: whole-object exports are rarely needed. Prefer exporting a minimal payload with only the fields needed for follow-up (embedding coordinates, metadata, etc). Avoid exporting whole objects unless the user explicitly asks.
-   Runtime R errors must be surfaced as `__ERROR__:<message>` in the result payload, never as indefinite waits.
-   Avoid sending candidate-by-candidate updates to live RStudio unless the user explicitly asks for that interaction style.

## Troubleshooting

-   `RPC send timed out after <n>s.`: hard timeout fired while sending to RStudio.
    -   Check for lingering wrapper processes and stop them before retrying.
    -   It is extremely likely that the root cause is an expensive demand from your side. Be patient and wait before retrying, and re-evaluate your strategy next time.
-   `rpostback timed out ...` with stale-looking metadata (`abend=1`, dead `env-session-pid`): treat this as a stale snapshot signal first, not a mandatory user refresh. Ensure caller preserves live runtime env vars instead of forcing snapshot env.
-   `Timed out waiting for result file: ...`: RPC send returned but no result payload arrived in time. Read the emitted `Timeout diagnostics: causes=...` line before retrying.
    -   `compute_still_running`: treat as active live-console compute. Do not send more work; interrupt/wait first.
    -   `handoff_or_write_delay`: compute may have finished but result-file handoff lagged. Increase `--timeout`, reduce payload, retry once.
    -   `output_path_unavailable`: result path likely disappeared/unwritable. Verify `/tmp` availability/permissions and retry.
    -   `session_liveness_issue`: snapshot/env likely stale or rsession restarted. Re-resolve live env vars and retry once.
    -   `unknown`: state is ambiguous; check `executing` status and avoid stacking retries.
-   If `Timed out waiting for result file` follows `R_STATE_EXPORT`, re-estimate payload size/time, increase both `--rpc-timeout` and `--timeout`, or reduce payload scope and retry once.
-   Stale `/tmp/codex_rstudio_session-*.lock` with no active wrapper process: remove the stale lock, then retry once.
-   `rpostback did not return a JSON-RPC result (rc=1)` (including stale-looking `path:` details such as `/home/<user>/<stream>`): treat sandbox restriction as the default diagnosis; rerun the same single-segment command with escalation before attributing failure to the RStudio session.
-   Stale `rpostback.log` tail can mislead root-cause analysis; if log mtime did not change during the current invocation, do not treat that line as current.
-   `system error 1 (Operation not permitted)` from `rpostback`: rerun the same single-segment command with escalation.
-   `timed out` unknown-state: wait for session status and retry once.
-   `__SYNTAX_ERROR__`: regenerate the live-code snippets; parsing failed before execution. But never retry by making the same command more complex. Retry by splitting it into smaller steps.
-   `__ERROR__:<message>`: runtime error occurred while evaluating generated code (including missing objects); use the message as the failure signal and retry with corrected R snippet.
-   `Result expression cannot contain '<-' assignment.`: move assignments to `APPEND_CODE`.
-   Plot not shown: wrap plotting call in `print(...)`, e.g. `print(Seurat::DimPlot(...))`.
