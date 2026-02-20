---
name: rstudio-talk
description: Trigger for R prompts where correctness depends on inspecting the user's live RStudio session state. Use when a prompt references concrete in-session objects/expressions and asks what currently exists (values, levels, labels, fields, dimensions), what a concrete expression currently returns, or why a concrete runtime call fails (including plotting/debugging issues such as Seurat::DimPlot behavior). Treat R-domain cues (syntax, operators, package/function names) as supporting evidence, not sufficient alone. Prefer false positives over false negatives when uncertain. Skip only conceptual/stateless R questions or meta discussion about this skill.
---

# Talk to Rstudio

## Overview

Utilize a defined set of capabilities to build a call to `interact_with_rstudio.sh` and communicate with the live Rstudio session.

## Trigger Policy

Use this skill when correctness depends on live RStudio session state.

-   Trigger when prompts reference concrete in-session objects/expressions and ask for current values, levels, fields, dimensions, labels, runtime behavior, or concrete failures.
-   Trigger when state-dependent intent is clear and R-domain evidence exists (syntax/operators/package names/RStudio context).
-   Treat R-domain cues as supporting evidence, not sufficient evidence by themselves.
-   Prefer false positives over false negatives when uncertain.
-   Skip only conceptual/stateless R questions and meta discussion about this skill.

Strong state-dependent signals:

-   Runtime symptom phrasing tied to concrete objects/expressions: `returns NULL`, `error`, `unexpected output`, `why this result`, `won't work`.
-   Plot/debug prompts where behavior depends on live object internals (for example Seurat `DimPlot` behavior).

## Workflow

Follow this sequence for every task:

1.  Translate user intent into the smallest R code you need to communicate to the Rstudio session.
2.  Determine capabilities to exert in order to chain the code together.
3.  Apply approval gate immediately before any global-side-effect capability.
4.  Run code-generation checks before sending RPC.
5.  Send one finalized snippet through `interact_with_rstudio.sh`.
6.  Inspect output and iterate only if needed.

## Capabilities

### Quick reference

Your capabilities each pertain to different scopes. Objects created/living in different scopes have different lifetimes:

-   The Temporary scratch env exists only for the current wrapper call. Objects created within this scope will not persist the next time you invoke the wrapper call.
-   The Cache environment (`codex_cache` env in `.GlobalEnv`) persists across wrapper calls until `CLEAR_CACHE` or R session restart. Use this environment to store computationally expensive intermediates during complex reasoning involving multiple rounds of back-and-forth.
-   The Global environment (`.GlobalEnv`) is read-only unless given explicit instruction. It is extremely dangerous to create anything within this scope, more so to modify existing elements.

| Capability | Purpose | Scope | Approval |
|------------------|------------------|------------------|------------------|
| `SET_RESULT_EXPR` (`--set-result-expr`) | Return one expression value through file transport | Temporary execution scope with read access to Cache/Global environments | Not required |
| `APPEND_CODE` (`--append-code`) | Stage helper statements for one invocation | Temporary scratch environment | Not required |
| `CACHE_CODE` (`--cache-code`) | Create/update/delete reusable working state entries | Cache environment | Not required |
| `CLEAR_CACHE` (`--clear-cache`) | Clear cache contents and remove cache container | Cache environment | Not required |
| `CREATE_NEW_GLOBAL_VARIABLE` (`--create-global-variable`) | Create new persistent `.GlobalEnv` binding | Global environment | Required (explicit) |
| `MODIFY_GLOBAL_ENV` (`--modify-global-env`) | Mutate existing persistent session state | Global environment | Required per statement (explicit, stricter) |

### `SET_RESULT_EXPR` (`--set-result-expr`)

Use for one final expression whose value must be returned.

-   Emit value by `dput` to an internal temp file.
-   Return `__ERROR__:<message>` on evaluation error.
-   Do not rely on `console_input` payload for expression values.
-   Accept only one single-line expression (no newline, no statement chaining).
-   Keep expression assignment-free (`<-`, `->` blocked).
-   Put all multi-line setup, helper assignments, and preprocessing in `--append-code`.
-   Treat `--set-result-expr` as read-only final retrieval from objects prepared earlier in the same invocation.

Read-only example:

``` bash
bash scripts/interact_with_rstudio.sh \
  --set-result-expr 'class(project_obj$sample_01)'
```

This capability itself does not allow multi-step evaluation involving assignment. Consult the next section for such workflows.

### `APPEND_CODE` (`--append-code`)

Use for temporary helper creation and staged probing inside one invocation. Objects created with `APPEND_CODE` are not available in later calls; expecting them later causes `object '<name>' not found`.

-   Allow assignment in temporary scope.
-   Reject direct `.GlobalEnv` / `globalenv()` targeting.
-   Reject direct `codex_cache` targeting; use `CACHE_CODE` instead.
-   Temporary scratch env is recreated every call and dropped automatically.

Multi-step workflow example:

``` bash
bash scripts/interact_with_rstudio.sh \
  --append-code 'obj <- project_obj$sample_01' \
  --append-code 'plot_obj <- Seurat::DimPlot(obj)' \
  --set-result-expr 'head(plot_obj$data$colour)'
```

### `CACHE_CODE` (`--cache-code`)

Use for reusable cross-invocation working state. Consider exerting this capability if the setup is complex so you expect multiple rounds of communication with Rstudio, and re-computing intermediate variables is expected to be costly.

Behavior:

-   Execute statements in `codex_cache` environment.
-   Auto-create `codex_cache` in `.GlobalEnv` when first needed.
-   Preserve cache across invocations until `CLEAR_CACHE` or R session restart.
-   Use for cache create/update/delete of entries only.

Creation or modification of cached variables do not require explicit side-effect approval. Treat cache as your working state. But since it does create a persistent object visible to the user, you are advised to explain to the user what changed, why, and how to inspect/teardown it. You may want to suggest some follow-up actions:

-   List cached names: `ls(envir = codex_cache, all.names = TRUE)`
-   Read value: `codex_cache$<name>`
-   Delete one value: `rm(list = "<name>", envir = codex_cache)`
-   Full teardown: `rm(codex_cache)`

But don't be too pedantic if the user seems knowledgeable and the focus of discussion lies elsewhere.

Examples:

Reusable expensive helper:

``` bash
bash scripts/interact_with_rstudio.sh \
  --cache-code 'counts <- GetAssayData(project_obj$sample_01, slot = "counts")'
```

Modify cache mid-reasoning:

``` bash
bash scripts/interact_with_rstudio.sh \
  --cache-code 'rm(list = "counts")'
```

Discussion-end cleanup:

-   At satisfactory endpoint, run `--clear-cache` by default unless retention is useful for likely follow-up.
-   If user opts out while still interactive, run `--clear-cache` and report cleanup.
-   If user quits abruptly, cache remains until manual removal or R restart.

### `CLEAR_CACHE` (`--clear-cache`)

Use for explicit cache teardown when working state is no longer needed.

-   Clear all objects in `codex_cache` (if present).
-   Remove `codex_cache` binding from `.GlobalEnv`.
-   No-op when `codex_cache` does not exist.
-   Do not require explicit side-effect approval (cache is agent working state).

Example:

``` bash
bash scripts/interact_with_rstudio.sh \
  --clear-cache
```

### `CREATE_NEW_GLOBAL_VARIABLE` (`--create-global-variable`)

Use only for explicit user-requested persistent state creation.

-   Create new `.GlobalEnv` binding from `name=<expr>`.
-   Fail if `name` already exists in `.GlobalEnv`.
-   Reject reserved name `codex_cache`.
-   Require explicit approval immediately before invocation.

Example:

``` bash
bash scripts/interact_with_rstudio.sh \
  --create-global-variable 'debug_plot=Seurat::DimPlot(project_obj$sample_01)'
```

### `MODIFY_GLOBAL_ENV` (`--modify-global-env`)

Use only for explicit user-requested mutation of existing session state.

-   Evaluate explicit statement in `.GlobalEnv`.
-   Require explicit approval for each invocation.
-   Treat as higher risk than `CREATE_NEW_GLOBAL_VARIABLE`.
-   Restate exact statement and expected effect before running.

Example:

``` bash
bash scripts/interact_with_rstudio.sh \
  --modify-global-env 'project_obj$sample_01 <- subset(project_obj$sample_01, idents = "A")'
```

## Rules

### Which wrapper script to call

-   Always use `bash scripts/interact_with_rstudio.sh` as primary entrypoint wrapper.
-   Never use `communicate_with_rstudio_console_with_rpc_low_level.sh`, even as fallback or upon user request. It is only intended as a helper script for the primary wrapper. Guards are absent, hence invocation may cause unintended effects!

### Permissions and escalation

-   Skip initial sandbox try for RPC: local socket access is known blocked in sandbox.
-   Run one escalated RPC call directly when execution is needed.
-   Keep wrapper invocation single-segment.
-   Include `prefix_rule` only when the wrapper prefix is not already approved.
-   When `prefix_rule` is needed, use wrapper-only prefixes: `["bash", "scripts/interact_with_rstudio.sh"]`
-   Never include dynamic flags/values (`--code`, `--expr`, object names, ids) in `prefix_rule`.

### Timeout

-   Treat timeout as `unknown-state` by default. Do not assume "still running" or "definitely failed" unless later evidence confirms one state.
-   Choose `--timeout` based on expected workload complexity and data volume. Use higher budgets for broader scans/comparisons, lower budgets for lightweight probes.
-   Avoid rapid fire retries after unknown-state timeout; let the wrapper's recovery/probe flow finish before issuing another call.

### Managing object lifecycles

-   Keep dependent temporary setup and final readout in the same invocation.
-   If follow-up calls need the same intermediate object, store it in `codex_cache` via `--cache-code`.
-   Default to `APPEND_CODE` for one-shot probes; promote to cache only when reuse is likely or setup is expensive.
-   Run `--clear-cache` when done unless user-visible reuse is still needed.

### Code-Generation Checks

Apply checks before every RPC call:

-   Reject `<<-`, `->>`, global `assign(...)`, global `rm/remove(...)`, and `source(..., local = FALSE)`.
-   Require `source(...)` to include explicit `local=`.
-   Reject risky process/session operations (`save`, `saveRDS`, `load`, `setwd`, `options`, `Sys.setenv`, `library`, `require`, `attach`, `detach`, `sink`, `system`, `system2`, `q`, `quit`).
-   Keep `APPEND_CODE` scoped to temporary scratch env.
-   Keep `CACHE_CODE` scoped to `codex_cache`; use `CLEAR_CACHE` for teardown.
-   Enforce add-only semantics for `CREATE_NEW_GLOBAL_VARIABLE`.
-   Enforce global leak detection: unexpected added/removed bindings fail invocation.
-   Avoid run-level side-effect toggles; allow side effects only through explicit side-effect capabilities.
-   Files can only generated for temporary use unless the user requests explicitly.

## Troubleshooting

-   `system error 1 (Operation not permitted)` in `~/.local/share/rstudio/log/rpostback.log`: local socket access is blocked in sandbox; rerun that single-segment RPC command with escalated permissions.
-   `rpostback` returns no JSON-RPC `result` envelope: treat as failed RPC and rerun once with escalation if needed.
-   `Timed out waiting for result file ...` with `RPC transport output: {"result":null}`: treat this as unknown-state. The call may still be executing, may have failed before writing the result file, or may have hit a transport fault. Use wrapper-emitted status lines plus `R session feedback after timeout` to disambiguate.
    -   `INTERACT_STATUS:parse_error`: generated code failed to parse before result file materialization. Fix code generation and rerun.
    -   `INTERACT_STATUS:unknown:timed_out_no_result_transport_ready`: transport recovered but no result file appeared; prior call outcome is unknown.
    -   `INTERACT_STATUS:unknown:timed_out_transport_unavailable`: transport was still unavailable after recovery wait; prior call outcome is unknown.
    -   `INTERACT_STATUS:transport_error:previous_timeout_unresolved`: previous unknown-state timeout is still unresolved. Wait and retry instead of forcing overlapping RPC calls.
-   Live-session checks cannot run: report the limitation and ask whether to continue with elevated session access.
-   `Result expression cannot contain '<-' assignment.`: move assignments to `--append-code`; keep `--set-result-expr` as one single-line read-only expression.
-   `object '<name>' not found` after a previous successful call: object was created in temporary scratch scope and expired; recreate it in the same invocation or persist it with `--cache-code`.
