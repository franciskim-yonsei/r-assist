---
name: r-assist
description: Trigger for prompts where correctness depends on user's live RStudio session state. Rather than asking the user for more context, interrogate the session yourself. Use when a prompt references concrete in-session objects/expressions and asks for current values, levels, labels, dimensions, or concrete failures.
---

# Assist with R analysis

## Overview

Interrogate live RStudio session via `bash SKILL_DIR/scripts/interact_with_rstudio.sh` (Convention in this document: `SKILL_DIR` refers to the directory containing this `SKILL.md` file).

## Workflow

1.  Decide the mode of operation: A, B, or C. Discuss with user if unsure.
2.  Write the required R code.
3.  Use your defined capabilities to build a call to the wrapper script.
4.  Make a call to `bash SKILL_DIR/scripts/interact_with_rstudio.sh`.
5.  (Mode B) Open a background R session (`R --quiet --no-save`) and continue analysis.
6.  Inspect output and iterate. If the user expects live output, send back only final user-facing artifact(s) to live RStudio (for plots: one final `print(...)` by default).

## Step 1. Decide mode of operation

### Quick reference

| Mode | Description | Pros | Cons | Use for |
|---------------|---------------|---------------|---------------|---------------|
| A | Carry out analysis directly in the live console | Avoids expensive exports | Objects expire. May clutter or block console | One-shot reads/checks |
| B | Export once, then continue in background R session | Avoids blocking console with long costly analyses | Export may be costly | Experimentation, comparison, sweeps |
| C | Run unattended long/expensive jobs | Preserves progress and resumability for long runs | Requires stricter planning and run management | Overnight runs, large sweeps, heavy integrations |

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
-   Choose mode C when extremely expensive computations must run unattended, i.e. when even a cursory look predicts \>30min ETA. Use `references/long-computation.md` if committing to this path.

### Deliberate and discuss

Whenever the choice is not obvious, you must take care to identify the minimum scope of analysis. Discuss the optimal approach with the user. Following are some general recommendations:

1.  Identify the minimum objects/functions needed from live RStudio. Build the smallest possible payload expression from live objects in one call (fewest objects possible).
2.  Default to exporting derived tables, vectors, embeddings, metadata slices, or marker results instead of entire assay objects.
3.  Use `bash SKILL_DIR/scripts/estimate_export_seconds.sh '<payload>'` to estimate ETA for export.
4.  Run steps 2-4 with `--benchmark` flag (with optional `--benchmark-unit seconds|ms`) when calling wrapper script to generate benchmarks for small pilot analyses and estimate total ETA for analysis.
5.  Evaluate the estimates. Report and discuss with user if unsure. Consider pivoting to mode C if either mode is untenable.

### Extremely expensive computations (mode C)

Use `references/long-computation.md` as the operational playbook for Mode C. It requires careful planning that involves pilot, calibration, unattended launch, checkpointing stages, as well as handoff constraints.

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
-   Skip if `--benchmark` flag is present; result is automatically set to elapsed time.

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
  --append-code 'obj <- project_obj$sample_01' \
  --append-code 'print(Seurat::DimPlot(obj))'
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
-   Set timeouts before export; utilize `est_seconds` = ETA for export if computed in step 1:
    -   `--rpc-timeout` at least equal to `est_seconds`.
    -   `--timeout` at least `est_seconds + 90`.
-   Treat tool `yield_time_ms` as output polling only, not process cancellation. Do not stack retries while a prior wrapper call is still running.
-   Prefer live runtime env vars (`RSTUDIO_SESSION_STREAM`, `RS_PORT_TOKEN`, `RSTUDIO_SESSION_PID`) when present. Do not blindly overwrite them with `suspended-session-data/environment_vars`, which may be stale.

## Step 5. Working with background sessions (mode B)

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

Use [`references/troubleshooting.md`](references/troubleshooting.md) for timeout/error triage and recovery steps. Open it whenever wrapper output contains timeout messages, `rpostback` failures, `__SYNTAX_ERROR__`, `__ERROR__`, or plotting visibility issues.
