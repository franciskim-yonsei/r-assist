# Long Expensive Computation (mode C)

## Overview

This mode of operation accepts the extreme cost of both export and analysis, and prompts the user to attend to other matters while the analysis runs.
- As such, user absence should be a first-class constraint.
- Avoid asking permissions or questions mid-run; that is antithetical to the purpose.
- Keep execution productive once launched; avoid idle time caused by preventable blockers.
- Keep progress observable and resumable.
- Produce reliable completion artifacts and a concise handoff.

## Workflow

### 1. Plan
- Define objective, success criteria, output paths, and completion condition.
- Identify dependencies, permissions, resource limits, and likely failure points.
- Choose execution pattern (chunked sweep, checkpointed loop, safe parallel workers).
- Define a non-destructive run layout (new run directory, separate code/logs/outputs).
- Record target unattended window (for example, 8 hours) and acceptable fidelity tradeoffs.
- Discuss whether to run in A or B style (submit job to live console vs. in background R session).
- Communicate clearly with the user. Let them know what deliverables they can expect to see by the end of the run.

### 2. Run a forcing pilot
- Run a small but representative subset through the same code path as the full run.
- Force discovery of missing libraries, environment setup, filesystem access, and permission requirements now.
- Capture pilot metrics: setup overhead, throughput per unit, memory/disk footprint, failure modes.
- If additional permissions are needed, obtain them in this phase before full launch.
- Persist pilot artifacts: command, logs, timings, and blockers found.

### 3. Calibrate and launch autonomous run
- Estimate total runtime from pilot data using setup overhead + per-unit time x total units (+ safety margin).
- Provide a concrete ETA and propose sweep size/density adjustments to match user demand and time budget.
- After calibration is accepted, launch one unattended process that can run predictably on its own.
- Prefer detached execution (`nohup`, `tmux`, scheduler job, etc.) with persistent `progress.log` and checkpoints.
- Attend to the process for a while to guard against unexpected premature termination.
- If the primary run finishes early, continue only with pre-approved extensions (for example, denser grid).

## Unattended run requirements

- Use timestamped run directories and never overwrite original data.
- Write checkpoints frequently and atomically.
- Emit periodic progress lines with elapsed time and ETA.
- Support resume from the latest valid checkpoint.
- Apply bounded retries for recoverable failures.
- On irrecoverable branch failure, skip safely and continue productive branches.

## Minimal deliverables per run

- One entrypoint command or script used for execution.
- One pilot log and timing summary.
- One runtime estimate and chosen calibration.
- One detached run identifier and `progress.log` path.
- One checkpoint path.
- One final status artifact summarizing outputs and resume/reproduce command.
