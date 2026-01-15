---
task: Stream activity into `./ralph` output and show started/finished tasks
test_command: "bash -n scripts/ralph scripts/*.sh"
---

# Task: Stream Parser Output Inline + Task Start/Finish Markers

## Overview

Running `./ralph` currently feels “silent” because the rich per-tool activity is written to `.ralph/runs/<runId>/activity.log` but not streamed inline to the terminal output. Additionally, the activity log does not reliably show file changes (e.g. PATCH/EDIT), which makes it hard to tell whether the agent is actually modifying files or making commits.

Improve the UX so that when `./ralph` runs, you can see the same activity live in the same terminal (no separate `tail -f` step), and also see explicit “started task” / “finished task” markers (Beads ID + title when available).

## Requirements

### Functional Requirements

1. Inline activity streaming

   - `./ralph` should stream the activity events live to the terminal during each iteration (matching what is written to `.ralph/runs/<runId>/activity.log`).
   - The existing control-signal mechanism (`WARN`/`ROTATE`/`GUTTER`/`COMPLETE`) must keep working (don’t break FIFO-driven signal reading).

2. Started/finished task markers (Beads)

   - When Ralph claims a Beads task (via `bd update <id> --status in_progress --json`), log/stream a clear “TASK START” line including:
     - Beads task ID
     - Title (best-effort from Beads JSON; fall back gracefully if unavailable)
   - When Ralph closes a Beads task (via `bd close <id> --reason ... --json`), log/stream a clear “TASK FINISH” line with the same info.

3. Visible file-change activity
   - The activity stream should clearly show when files are modified, not only when they are read.
   - In particular: teach the parser to recognize the file-edit tool events produced by `cursor-agent` (not just `writeToolCall`) so that PATCH/EDIT/DELETE operations surface as activity lines.

### Non-Functional Requirements

- Maintainability: Keep changes localized, ideally in `scripts/stream-parser.sh` and minimal wiring changes elsewhere.
- Backwards compatibility: Do not change the meaning of signals used by `scripts/ralph-common.sh` to control loop behavior.
- Noise control: Stream activity as requested (full `activity.log`-equivalent), but keep stdout clean for control signals.

## Constraints

- Bash-based implementation (stay within existing scripting patterns).
- macOS compatibility (bash 3.x constraints already present in repo).
- Avoid new runtime dependencies beyond what is already assumed (jq is already used by `stream-parser.sh`).

## Success Criteria

The following will be converted to Beads tasks when Ralph first runs.
Progress is tracked via `bd ready`, `bd close`, etc.

1. Running `./scripts/ralph once` shows live per-tool activity inline in the terminal without needing a separate `tail -f .ralph/runs/<runId>/activity.log`.
2. `scripts/stream-parser.sh` continues to emit only control signals (`WARN`/`ROTATE`/`GUTTER`/`COMPLETE`) on stdout so `scripts/ralph-common.sh` signal handling is unchanged.
3. Activity stream/log shows explicit “TASK START” and “TASK FINISH” lines for Beads operations, including Beads ID + title when available from `--json`.
4. Activity stream/log shows file changes (PATCH/EDIT/DELETE/WRITE) for real edits produced by `cursor-agent` (not just shell commands).
5. `bash -n scripts/ralph scripts/*.sh` still passes.

## Notes

- Today, the activity is written to `.ralph/runs/<runId>/activity.log` but not streamed into the main `./ralph` output because the parser’s stdout is redirected into a FIFO for signals. A clean approach is to keep stdout for signals and print human-readable activity to stderr.
- Beads JSON parsing should be best-effort and degrade gracefully (ID-only if title cannot be extracted).

---

## Ralph Instructions

When working on this task:

1. Check `bd ready --label ralph:<runId> --json` to find the next available task
2. Claim it: `bd update <id> --status in_progress --json`
3. Work on the task
4. Close when done: `bd close <id> --reason "description" --json`
5. Sync: `bd sync`
6. Read `.ralph/runs/<runId>/progress.md` to see what's been done
7. Check `.ralph/guardrails.md` for signs to follow
8. Update `.ralph/runs/<runId>/progress.md` with your progress
9. Commit your changes with descriptive messages
10. When all tasks are closed, output: `<ralph>COMPLETE</ralph>`
11. If stuck on the same issue 3+ times, output: `<ralph>GUTTER</ralph>`
