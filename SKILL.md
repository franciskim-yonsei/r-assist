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
4.  Apply appropriate options, then run the code.
5.  Inspect output and iterate.
6.  (Mode B) Open a background R session (`R --quiet --no-save`) and continue analysis.
7.  If the user expects live output, return only final user-facing artifact(s) to live RStudio (for plots: one final `print(...)` by default).

## Step 1. Decide mode of operation

### Quick reference

| Mode | Description | Pros | Cons | Use for |
|---------------|---------------|---------------|---------------|---------------|
| A | Carry out analysis directly in the live console | Avoids expensive exports | Objects expire. May clutter or block console | One-shot reads/checks |
| B | Export once, then continue in background R session | Avoids blocking console with long costly analyses | Export may be costly | Experimentation, comparison, sweeps |
| C | Run unattended long jobs `(references/long_computation.md`) | Preserves progress and resumability for long runs | Requires stricter planning and run management | Overnight runs, large sweeps, heavy integrations |

### Primary concerns

It is imperative that you consider the following constraints:

-   Any object you create directly in the console is temporary; it expires after each run cycle.
-   R functions are slow. Any function you run directly in the console blocks out the user.
-   R serialization and disk I/O are also slow. Large exports may also block out the user.

Balance the cost of blocking the console with direct analysis (track A) vs. export (track B).

### Setup sequence (non-negotiable)

Before beginning any analysis, absolutely follow these steps:

1.  Identify the minimum objects/functions needed from live RStudio. Build the smallest possible payload expression from live objects in one call (fewest objects possible).
2.  Default to using derived tables, vectors, embeddings, metadata slices, or marker results instead of entire assay objects.
3.  Explicitly examine data dimensions and flag any large cost-determining magnitudes.
4.  Use `python3 SKILL_DIR/scripts/estimate_export_seconds.py '<payload>'` to estimate ETA for export.
5.  Expect the most expensive step of your analysis, and run a quick pilot analysis with a small subset of the data. Use `benchmark` option to gather info for estimating ETA of full analysis.

### Deliberate and discuss

Sometimes the task clearly belongs to a certain pattern and the optimal choice is obvious. Decide quickly and move on to step 2.

-   Choose mode A when analysis is OBVIOUSLY cheap.
-   Choose mode B when export is OBVIOUSLY cheap.
-   Choose mode C when BOTH analysis AND export are OBVIOUSLY extremely expensive, i.e. when even a cursory look predicts \>30min ETA. Use `references/long-computation.md` if committing to this path.

Whenever the choice is not obvious, you must take care to identify the minimum scope of analysis. Report your estimates and discuss the optimal approach with the user.

## Step 2. Begin command-building shell

-   Define `SKILL_DIR` as the directory containing this `SKILL.md`.
-   Always call `python3 SKILL_DIR/scripts/interact_with_rstudio.py` (expanded to absolute path); never call low-level socket helper scripts directly.
-   In Codex tool calls, run scripts with escalation (`sandbox_permissions=require_escalated`) by default; sandbox execution is a known false-failure mode for `rpostback`/local socket access.
-   For every escalated script call, always provide `prefix_rule=["python3","SKILL_DIR/scripts/interact_with_rstudio.py"]`; never include runtime flags/code in the prefix rule.
-   For interactive bridge sessions in Codex, use `tty=true` so one persistent session id can be reused with `write_stdin` polling.
-   Do not use `printf` with pipes or heredoc mode.
-   Before complex payloads, run `<<smoke>>` once to confirm bridge responsiveness and output transport.
-   Exit the interactive bridge with `<<quit>>`.

## Step 3. Write code

### Style guide

Here is the most important thing you should remember: DO NOT TRUST YOUR CODE.

-   Pessimistically assume every statement contains at least one syntax error.
-   The longer and nested the code, the more painful the inevitable debugging.
-   Keep each line short (prefer \<=120 chars); split long logic across multiple lines.
-   Write code like you're a conceptual expert yet a syntactical baby; avoid complexity like the plague.

### Quick reference

Once you are in the interactive command-building shell, you can exert the following capabilities to build R code. Each capability uses a leading `<<keyword>>` command prefix (except bare APPEND lines).

| Capability | Purpose | Scope | Approval |
|------------------|------------------|------------------|------------------|
| PREVIEW (`<<preview>>EXPR`) | Return a conservative, short summary for one expression | Temporary execution scope with global read access | Not required |
| RESULT (`<<result>>EXPR`) | Set one expression value that will be returned this run | Temporary execution scope with global read access | Not required |
| APPEND (bare R statement without command prefix) | Stage helper statements. Primary vehicle for adding code | Temporary scratch env | Not required |
| EXPORT (`<<export>>EXPR`) | Persist one payload from live RStudio into a temp RDS file | Temporary local file path | Not required |
| CREATE (`<<create>>NAME:=EXPR`) | Create new persistent `.GlobalEnv` binding | Global | Required |
| MODIFY (`<<modify>>STMT`) | Mutate existing persistent state | Global | Required |

### PREVIEW (`<<preview>>EXPR`)

Default to this capability for read-only inspection. `<<preview>>` is conservative by design: it returns compact metadata plus a bounded text preview (for example from `show(...)` for formal/S4 objects or `str(..., max.level = 1)` for other objects), with explicit truncation limits.

-   Use `<<preview>>` first unless exact value transport is truly necessary.
-   `<<preview>>` is strict: exactly one physical line with one complete expression; no assignments (`<-` prohibited).
-   Keep prep in APPEND and reserve `<<preview>>` for one final object/expression.
-   `<<preview>>` cannot be combined with `<<result>>` or `<<export>>` in the same run.

Example:

```         
obj <- cca
<<preview>>Assays(obj)
<<run>>
```

### RESULT (`<<result>>EXPR`)

Use for one final read-only expression when precision matters and preview is insufficient. Each run includes at most one `<<run>>`.

Critical warning: `<<result>>` currently serializes payloads with `dput(...)`. For large or complex objects (especially formal/S4 objects like Seurat internals), this can behave like full structural serialization and may block the live console unexpectedly.

-   `<<result>>` is strict: exactly one physical line with one complete expression; no assignments (`<-` prohibited).
-   Do not place multi-line blocks (`{...}`), loops, or function definitions in `<<result>>`. Stage those with APPEND first.
-   Do not split a `<<result>>...` expression across multiple input lines. Any later lines are treated as APPEND and will break intent.
-   If `<<result>>` ends with an operator/comma/open delimiter (for example `<<result>>list(`), the bridge rejects it as incomplete before `<<run>>`.
-   Multi-step prep goes in APPEND.
-   Skip if `benchmark` option is on; result is automatically set to elapsed time.
-   Before requesting `<<result>>`, explicitly probe:
    `class(x)`, `isS4(x)`, `dim(x)`/`length(x)`, and `object.size(x)`.
-   If object is formal/S4, high-dimensional, or large, do not `<<result>>` the raw object.
    Manually construct a safe representation first (for example `str(x, max.level = 1)`, `head(...)`, selected vectors/tables).

Example:

```         
res <- class(project_obj$sample_01)
<<result>>res
<<run>>
```

Anti-pattern (invalid):

```         
<<result>>list(
a = sapply(
    vec,
    \(i) i + 1
  )
)
<<run>>
```

Anti-pattern (valid, but strongly discouraged):

```         
<<result>>list(a = sapply(vec, my_func))
```

Preferred pattern:

```         
tmp <- vec
tmp2 <- sapply(tmp, my_func)
<<result>>tmp2
<<run>>
```

### APPEND (bare R statement without command prefix)

Main workhorse for building code; type plain R statements with no command prefix.

-   Objects created here expire with the run-cycle.
-   Avoid repeated console interactions for iterative debugging.
-   Do not run exploratory loops that emit many plots in live RStudio by default.
-   For plot-selection tasks, reserve live `print(...)` for the final selected plot unless user explicitly requests live comparisons.

```         
obj <- project_obj$sample_01
plot_obj <- Seurat::DimPlot(obj)
res <- head(plot_obj$data$colour)
<<result>>res
<<run>>
```

Special example: when plots must be visible to the user, make sure to use `print(...)` around calls that return plot objects (ggplot2/patchwork/Seurat plot builders).

```         
obj <- project_obj$sample_01
print(Seurat::DimPlot(obj))
<<run>>
```

### EXPORT (`<<export>>EXPR`)

Use when follow-up is likely. Script returns a path to the exported RDS.

Example:

```         
snap_obj <- project_obj$sample_01
res <- list(sample_obj = snap_obj, created = Sys.time())
<<export>>res
<<run>>
```

### CREATE (`<<create>>NAME:=EXPR`)

Use only for explicit user-requested persistent `.GlobalEnv` binding changes.

Example:

```         
obj <- project_obj$sample_01
res1 <- FindNeighbors(obj)
res2 <- RunUMAP(obj)
<<create>>sample_01_processed:=res2
<<run>>
```

### MODIFY (`<<modify>>STMT`)

Use only for explicit user-requested mutation of existing `.GlobalEnv` state.

## Step 4. Apply options

Options are also set interactively using stdin. Use `<<option-name>>VALUE`.

-   Timeout-related options: set both explicitly on long or uncertain calls. Ttilize `est_seconds` = ETA computed in step 1 if in mode B.
    -   `<<timeout>>SECONDS`: pertains to result-file wait. Should be at least `est_seconds + 90`.
    -   `<<rpc-timeout>>SECONDS`: pertains to run step. Should be at least `est_seconds`.
-   Connection-related options: do not manually overwrite `RSTUDIO_SESSION_STREAM`, `RS_PORT_TOKEN`, or `RSTUDIO_SESSION_PID` during normal operation. `interact_with_rstudio.py` already prefers valid live runtime env vars and only falls back to `suspended-session-data/environment_vars` when needed.
    -   `<<session-dir>>DIR`: Override auto session discovery and target one explicit RStudio session directory.
    -   `<<id>>INT`: Set JSON-RPC request id (mainly for tracing/debugging); default is `1`.
    -   `<<rpostback-bin>>PATH`: Override `rpostback` binary path for troubleshooting custom/runtime layouts.
-   `<<out>>PATH`: Use a fixed result file path instead of an auto-generated temp file when `<<preview>>`, `<<result>>`, or `<<export>>` is set.
-   `<<benchmark>>ON|OFF`: Benchmark mode for `<<result>>`; returns elapsed time (not the expression value).
-   `<<benchmark-unit>>SECONDS|MS`: Unit for benchmark output.
-   `<<print-code>>ON|OFF`: Print generated R snippet to stderr before RPC run.

Finally, `<<run>>` the finished R-code.

-   Critical: APPEND, PREVIEW, RESULT, EXPORT, CREATE, and MODIFY are only stage capabilities. Nothing executes until `<<run>>`.

-   After every `<<run>>` attempt (success or failure), the bridge clears staged capabilities. Re-stage lines explicitly for the next batch.

-   Treat tool `yield_time_ms` as output polling only, not cancellation. Keep a single live `interact_with_rstudio.py` exec session per run, poll that same session while `<<run>>` is in flight, and do not start another `<<run>>`/process until the prior one returns.

## Step 5. Interpret output

Bridge output interpretation:

-   Success returns a structured payload with `result`, `stdout`, and `stderr`.
-   `<<preview>>` success returns a compact preview payload (metadata + truncated preview lines), not a full-fidelity object dump.
-   APPEND-only runs are treated as success with implicit `result = NULL` plus captured `stdout`/`stderr`.
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
-   Prefer `<<preview>>` as the first probe. Escalate to `<<result>>` only when exact values are required.
-   Before any `<<result>>`, run explicit probes for class/category (`class`, `isS4`), shape (`dim` or `length`), and size (`object.size`).
-   Keep one action per line in both append and background R commands.
-   If a line fails, inspect with simple probes (`class(...)`, `names(...)`, `dim(...)`, `head(...)`) before continuing.
-   If `<<run>>` unexpectedly fails, run `<<smoke>>`, then use `<<show>>` to verify staged capabilities before retrying.

### Important reminder

-   Whole-object exports are rarely needed. Prefer exporting a minimal payload with only the fields needed for follow-up (embedding coordinates, metadata, etc). Avoid exporting whole objects unless the user explicitly asks.
-   R functions are slow. Estimate ETA conservatively. Discuss with the user before beginning expensive computations in the live console.

## Troubleshooting

Use [`references/troubleshooting.md`](references/troubleshooting.md) for timeout/error triage and recovery steps. Open it whenever output contains timeout messages, `rpostback` failures, `__SYNTAX_ERROR__`, `__ERROR__`, or plotting visibility issues.
