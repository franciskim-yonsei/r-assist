---
name: r-assist
description: Trigger for prompts where correctness depends on user's live RStudio session state. Rather than asking the user for more context, interrogate the session yourself. Use when a prompt references concrete in-session objects/expressions and asks for current values, levels, labels, dimensions, or concrete failures.
---

# Assist with R analysis

## Overview

Interrogate live RStudio session via `python3 SKILL_DIR/scripts/interact_with_rstudio.py` (Convention in this document: `SKILL_DIR` refers to the directory containing this `SKILL.md` file).

## Workflow

1.  Decide the mode of operation: A, B, or C. Discuss with user if unsure.
2.  Use `python3 SKILL_DIR/scripts/interact_with_rstudio.py` to start an interactive command-building shell.
3.  Use your defined capabilities to build the R code.
4.  Apply appropriate options, then send the code.
5.  Inspect output and iterate.
6.  (Mode B) Open a background R session (`R --quiet --no-save`) and continue analysis.
7.  If the user expects live output, send back only final user-facing artifact(s) to live RStudio (for plots: one final `print(...)` by default).

## Step 1. Decide mode of operation

### Quick reference

| Mode | Description | Pros | Cons | Use for |
|---------------|---------------|---------------|---------------|---------------|
| A | Carry out analysis directly in the live console | Avoids expensive exports | Objects expire. May clutter or block console | One-shot reads/checks |
| B | Export once, then continue in background R session | Avoids blocking console with long costly analyses | Export may be costly | Experimentation, comparison, sweeps |
| C | Run unattended long/expensive jobs | Preserves progress and resumability for long runs | Requires stricter planning and run management | Overnight runs, large sweeps, heavy integrations |

### Primary concerns

It is imperative that you consider the following constraints:

-   Any object you create directly in the console is temporary; it expires after each send cycle.
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
3.  Use `bash SKILL_DIR/scripts/estimate_export_seconds.py '<payload>'` to estimate ETA for export.
4.  Run steps 2-4 with `benchmark` option to generate benchmarks for small pilot analyses and estimate total ETA for analysis.
5.  Evaluate the estimates. Report and discuss with user if unsure. Consider pivoting to mode C if either mode is untenable.

### Extremely expensive computations (mode C)

Use `references/long-computation.md` as the operational playbook for Mode C. It requires careful planning that involves pilot, calibration, unattended launch, checkpointing stages, as well as handoff constraints.

## Step 2. Begin command-building shell

-   Define `SKILL_DIR` as the directory containing this `SKILL.md`.
-   Always call `python3 SKILL_DIR/scripts/interact_with_rstudio.py` (expanded to absolute path); never call low-level socket helper scripts directly.
-   In Codex tool calls, run scripts with escalation (`sandbox_permissions=require_escalated`) by default; sandbox execution is a known false-failure mode for `rpostback`/local socket access.
-   For every escalated script call, always provide `prefix_rule=["python3","SKILL_DIR/scripts/interact_with_rstudio.py"]`; never include runtime flags/code in the prefix rule.
-   For interactive bridge sessions in Codex, use `tty=true` so one persistent session id can be reused with `write_stdin` polling.
-   Do not use `printf` with pipes or heredoc mode.
-   Before complex payloads, run `smoke` once to confirm bridge responsiveness and output transport.

## Step 3. Write code

### Quick reference

Once you are in the interactive command-building shell, you can exert the following capabilities to build R code. Each capability amounts to a structured input to stdin.

| Capability | Purpose | Scope | Approval |
|------------------|------------------|------------------|------------------|
| RESULT (`result:<R expression>`) | Return one expression value via file transport | Temporary execution scope with global read access | Not required |
| APPEND (`append:<R statement>`) | Stage helper statements for one invocation | Temporary scratch env | Not required |
| EXPORT (`export:<R expression>`) | Persist one payload from live RStudio into a temp RDS file | Temporary local file path | Not required |
| CREATE (`create:<name>:=<expr>`) | Create new persistent `.GlobalEnv` binding | Global | Required |
| MODIFY (`modify:<R statement>`) | Mutate existing persistent state | Global | Required |

### RESULT (`result:<R expression>`)

Use for one final read-only expression.

-   Only one single-line expression, no assignments (`<-` prohibited!).
-   Do not place multi-line blocks (`{...}`), loops, or function definitions in `result:`. Stage those in `append:` first.
-   Multi-step prep goes in APPEND.
-   Skip if `benchmark` option is on; result is automatically set to elapsed time.

Example:

```         
result:class(project_obj$sample_01)
send
```

### APPEND (`append:<R statement>`)

Use for temporary setup and single-shot probing.

-   Objects created here expire with the send-cycle.
-   Avoid repeated console interactions for iterative debugging.
-   Do not run exploratory loops that emit many plots in live RStudio by default.
-   For plot-selection tasks, reserve live `print(...)` for the final selected plot unless user explicitly requests live comparisons.
-   Keep each `append:` line short (prefer \<=120 chars); split long logic across multiple lines to reduce transport/parser fragility.

```         
append:obj <- project_obj$sample_01
append:plot_obj <- Seurat::DimPlot(obj)
result:head(plot_obj$data$colour)
send
```

Special example: when plots must be visible to the user, make sure to use `print(...)` around calls that return plot objects (ggplot2/patchwork/Seurat plot builders).

```         
append:obj <- project_obj$sample_01
append:print(Seurat::DimPlot(obj))
send
```

### EXPORT (`export:<R expression>`)

Use when follow-up is likely. Script returns a path to the exported RDS.

Example:

```         
append:snap_obj <- project_obj$sample_01
export:list(sample_obj = snap_obj, created = Sys.time())
send
```

### CREATE (`create:<name>:=<expr>`)

Use only for explicit user-requested persistent `.GlobalEnv` binding changes.

### MODIFY (`modify:<R statement>`)

Use only for explicit user-requested mutation of existing `.GlobalEnv` state.

## Step 4. Apply options

Options are also set interactively using stdin. Use `<option-name>:<value>.`

-   Timeout-related options: set both explicitly on long or uncertain calls. Ttilize `est_seconds` = ETA computed in step 1 if in mode B.
    -   `timeout:<seconds>`: pertains to result-file wait. Should be at least `est_seconds + 90`.
    -   `rpc-timeout:<seconds>`: pertains to send step. Should be at least `est_seconds`.
-   Connection-related options: do not manually overwrite `RSTUDIO_SESSION_STREAM`, `RS_PORT_TOKEN`, or `RSTUDIO_SESSION_PID` during normal operation. `interact_with_rstudio.py` already prefers valid live runtime env vars and only falls back to `suspended-session-data/environment_vars` when needed.
    -   `session-dir:<dir>`: Override auto session discovery and target one explicit RStudio session directory.
    -   `id:<int>`: Set JSON-RPC request id (mainly for tracing/debugging); default is `1`.
    -   `rpostback-bin:<path>`: Override `rpostback` binary path for troubleshooting custom/runtime layouts.
-   `out:<path>`: Use a fixed result file path instead of an auto-generated temp file when `result:` or `export:` is set.
-   `benchmark:<on|off>`: Benchmark mode for `result:`; returns elapsed time (not the expression value).
-   `benchmark-unit:<seconds|ms>`: Unit for benchmark output.
-   `print-code:<on|off>`: Print generated R snippet to stderr before RPC send.

Finally, `send` the finished R-code.

-   Critical: `append:`, `result:`, `export:`, `create:`, and `modify` are only stage capabilities. Nothing executes until `send`.

-   After every `send` attempt (success or failure), the bridge clears staged capabilities. Re-stage lines explicitly for the next batch.

-   Treat tool `yield_time_ms` as output polling only, not cancellation. Keep a single live `interact_with_rstudio.py` exec session per run, poll that same session while `send` is in flight, and do not start another `send`/process until the prior one returns.

## Step 5. Interpret output

Bridge output interpretation:

-   Success returns a structured payload with `result`, `stdout`, and `stderr`.
-   `append:`-only sends are treated as success with implicit `result = NULL` plus captured `stdout`/`stderr`.
-   Failure returns a structured payload with `error`, `stdout`, and `stderr`.
-   `stdout` can be noisy and non-empty on successful runs (for example from `print(...)`).
-   Treat parse failures (`__SYNTAX_ERROR__`), RPC failures, and explicit `error` payloads as actual failures.

## Step 6. Working with background sessions (mode B)

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

### Hard code requirements

Run these checks for every line of code you write.

-   Reject `<<-`, `->>`, global `assign(...)`, global `rm/remove(...)`, and `source(..., local = FALSE)`.
-   Reject `save`, `saveRDS`, `load`, and file-creation calls in live-session calls.
-   Reject `setwd`, `options`, `Sys.setenv`, `attach`, `detach`, `sink`, `system`, `system2`, `q`, `quit`.
-   Keep `library()`/`require()` out of live-session calls unless explicitly requested by user intent.
-   For graphical commands in live-session calls, enforce `print(...)` around rendering expressions.

### Highly recommended: keep code simple.

-   Avoid complex one-liner construction like giant `list(...)` or heavy inline indexing in one command.
-   Avoid semicolon-separated multi-statement lines and deeply nested expressions.
-   Strongly prefer explicit intermediate variables and short commands that are easy to debug.
-   Keep one action per line in both `append:` and background R commands.
-   If a line fails, inspect with simple probes (`class(...)`, `names(...)`, `dim(...)`, `head(...)`) before continuing.
-   If a `send` unexpectedly fails, run `smoke`, then use `show` to verify staged capabilities before retrying.

### Important reminder

-   Whole-object exports are rarely needed. Prefer exporting a minimal payload with only the fields needed for follow-up (embedding coordinates, metadata, etc). Avoid exporting whole objects unless the user explicitly asks.
-   R functions are slow. Estimate ETA conservatively. Discuss with the user before beginning expensive computations in the live console.

## Troubleshooting

Use [`references/troubleshooting.md`](references/troubleshooting.md) for timeout/error triage and recovery steps. Open it whenever output contains timeout messages, `rpostback` failures, `__SYNTAX_ERROR__`, `__ERROR__`, or plotting visibility issues.
