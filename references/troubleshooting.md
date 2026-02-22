# Troubleshooting

Use this reference when `interact_with_rstudio.sh` or its RPC helper fails.

## Timeout Triage

1.  Read the first timeout/error line.
2.  If it says `Timed out waiting for result file`, read the `Timeout diagnostics: causes=...` line.
3.  Treat `compute_still_running` as highest priority: stop stacking new calls until the live console is idle.
4.  Retry at most once after applying the relevant fix.

## Common Failures

### `RPC send timed out after <n>s.`

Hard timeout fired while sending to RStudio.

1.  Check for lingering wrapper processes and stop them before retrying.
2.  Assume the call was too heavy unless proven otherwise.
3.  Retry once with simpler code and appropriate timeout values.

### `rpostback timed out ...` with stale-looking metadata (`abend=1`, dead `env-session-pid`)

Treat this as a stale snapshot signal first, not mandatory user refresh.

1.  Preserve live runtime env vars (`RSTUDIO_SESSION_STREAM`, `RS_PORT_TOKEN`, `RSTUDIO_SESSION_PID`) when present.
2.  Avoid forcing snapshot env values from `suspended-session-data/environment_vars`.
3.  Retry once.

### `Timed out waiting for result file: ...`

RPC send returned, but no result payload arrived before `--timeout`.

1.  Read `Timeout diagnostics: causes=...`.
2.  Apply cause-specific action
    -   `compute_still_running`: active live-console compute. Interrupt or wait before retrying.
    -   `handoff_or_write_delay`: compute may have finished, but result handoff/file write lagged. Increase `--timeout`, reduce payload, retry once.
    -   `output_path_unavailable`: output file path disappeared or is inaccessible. Verify `/tmp` availability and permissions, then retry once.
    -   `session_liveness_issue`: session snapshot/env may be stale or rsession restarted. Re-resolve live runtime env vars, then retry once.
    -   `unknown`: ambiguous state. Check `executing` status and avoid stacking retries.
3.  If this follows `R_STATE_EXPORT`, re-estimate payload size and raise both `--rpc-timeout` and `--timeout`.

### Stale `/tmp/codex_rstudio_session-*.lock` with no active wrapper process

Remove the stale lock and retry once.

### `rpostback did not return a JSON-RPC result (rc=1)`

Treat sandbox restriction as default diagnosis before blaming RStudio.

1.  Rerun the same single-segment command with escalation.
2.  Do not over-interpret stale `path:` details (for example `/home/<user>/<stream>`) unless log mtime changed during this invocation.

### `system error 1 (Operation not permitted)` from `rpostback`

Rerun the same single-segment command with escalation.

### `__SYNTAX_ERROR__`

-   Generated live R snippet failed to parse.

-   Regenerate the snippet by breaking it into smaller, explicit steps.

-   Do not retry by making the same command more complex.

### `__ERROR__:<message>`

-   Runtime error occurred while evaluating generated code (including missing objects).

-   Regenerate the snippet by breaking it into smaller, explicit steps.

-   Do not retry by making the same command more complex.

-   If the message is `no applicable method for 'conditionMessage' applied to an object of class "character"`, the bridge is seeing a non-condition error payload.

-   Retry with `print-code:on` and `capture-output:on` once, then patch the interactive code path with a helper that coalesces condition messages with `as.character` for non-condition objects.

### `Result expression cannot contain '<-' assignment.`

Move assignments to `APPEND_CODE`.
