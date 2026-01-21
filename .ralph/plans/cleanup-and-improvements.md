---
name: Ralph UX cleanup
overview: Consolidate CLI surface area to the single ./ralph entrypoint, remove progress.md usage in favor of Beads-only tracking, eliminate repeated watch spam in the spinner, and add explicit activity events for git commits.
todos:
  - id: delete-wrapper-scripts
    content: Delete deprecated wrapper scripts and update docs/tests that reference them.
    status: pending
  - id: spinner-watch-removal
    content: "Remove repeated '(watch: tail -f ...)' from spinner output while keeping a single monitor hint near the top."
    status: pending
  - id: remove-progress-md-e2e
    content: Remove progress.md creation/usage from run dir initialization, prompts, docs, and installer output; rely on Beads only.
    status: pending
  - id: git-commit-activity-events
    content: "Add explicit 'GIT COMMIT: <subject>' activity events for agent shell commits (stream-parser) and loop-driven commits (ralph-common)."
    status: pending
isProject: false
---

# Ralph: single entrypoint, no progress.md, git commit events

## Decisions (based on your answers)

- Keep `./ralph` as the only user-facing command.
- Keep `scripts/ralph` subcommands (`init`, `once`, `template`) as implementation details used by `./ralph`.
- Remove deprecated wrapper scripts (`scripts/ralph-setup.sh`, `scripts/ralph-once.sh`, `scripts/ralph-loop.sh`, `scripts/init-ralph.sh`).
- Git commit streaming events should log **subject only**.

## Scope of changes

### 1) Remove non-entrypoint ralph commands (wrapper scripts)

- Delete:
- `[/Users/ryancook/workspace/tmp/ralph-wiggum-cursor-beads/scripts/ralph-setup.sh](/Users/ryancook/workspace/tmp/ralph-wiggum-cursor-beads/scripts/ralph-setup.sh)`
- `[/Users/ryancook/workspace/tmp/ralph-wiggum-cursor-beads/scripts/ralph-once.sh](/Users/ryancook/workspace/tmp/ralph-wiggum-cursor-beads/scripts/ralph-once.sh)`
- `[/Users/ryancook/workspace/tmp/ralph-wiggum-cursor-beads/scripts/ralph-loop.sh](/Users/ryancook/workspace/tmp/ralph-wiggum-cursor-beads/scripts/ralph-loop.sh)`
- `[/Users/ryancook/workspace/tmp/ralph-wiggum-cursor-beads/scripts/init-ralph.sh](/Users/ryancook/workspace/tmp/ralph-wiggum-cursor-beads/scripts/init-ralph.sh)`
- Update references/tests/docs that still mention these wrappers:
- `[/Users/ryancook/workspace/tmp/ralph-wiggum-cursor-beads/test-smoke.sh](/Users/ryancook/workspace/tmp/ralph-wiggum-cursor-beads/test-smoke.sh)`
- `[/Users/ryancook/workspace/tmp/ralph-wiggum-cursor-beads/README.md](/Users/ryancook/workspace/tmp/ralph-wiggum-cursor-beads/README.md)`
- Anywhere else `grep` found wrapper mentions.

### 2) Remove the spinner “watch: tail -f …” spam

- The spam comes from the `spinner()` function in `[/Users/ryancook/workspace/tmp/ralph-wiggum-cursor-beads/scripts/ralph-common.sh](/Users/ryancook/workspace/tmp/ralph-wiggum-cursor-beads/scripts/ralph-common.sh)`, which currently prints:
- `🐛 Agent working... <spin>  (watch: tail -f <run_dir>/activity.log)` repeatedly.
- Change `spinner()` to print only a short, stable status line (no tail hint), e.g.:
- `🐛 Agent working... <spin>`
- Keep the monitoring hint **once** near the top (already printed by `run_iteration()` as `Monitor: tail -f ...`).

### 3) Remove `progress.md` entirely (Beads-only progress)

- Stop creating `progress.md` in `init_run_dir()` in `[scripts/ralph-common.sh](/Users/ryancook/workspace/tmp/ralph-wiggum-cursor-beads/scripts/ralph-common.sh)`.
- Remove `log_progress()` and all calls to it (it’s currently used for session start/end + loop bookkeeping).
- Update `build_prompt()` so the agent no longer reads/writes `progress.md`.
- Specifically remove the instructions that mention:
- “Read `$rel_run_dir/progress.md`”
- “Update `$rel_run_dir/progress.md`”
- Update all templates/docs that instruct reading/writing `progress.md`:
- `[/Users/ryancook/workspace/tmp/ralph-wiggum-cursor-beads/assets/RALPH_TASK_TEMPLATE.md](/Users/ryancook/workspace/tmp/ralph-wiggum-cursor-beads/assets/RALPH_TASK_TEMPLATE.md)`
- `[/Users/ryancook/workspace/tmp/ralph-wiggum-cursor-beads/assets/RALPH_TASK_EXAMPLE.md](/Users/ryancook/workspace/tmp/ralph-wiggum-cursor-beads/assets/RALPH_TASK_EXAMPLE.md)`
- `[/Users/ryancook/workspace/tmp/ralph-wiggum-cursor-beads/README.md](/Users/ryancook/workspace/tmp/ralph-wiggum-cursor-beads/README.md)`
- `[/Users/ryancook/workspace/tmp/ralph-wiggum-cursor-beads/install.sh](/Users/ryancook/workspace/tmp/ralph-wiggum-cursor-beads/install.sh)` (installer output currently lists `progress.md`)
- `[/Users/ryancook/workspace/tmp/ralph-wiggum-cursor-beads/SKILL.md](/Users/ryancook/workspace/tmp/ralph-wiggum-cursor-beads/SKILL.md)` and any other docs mentioning it.

### 4) Add streaming events for git commits

There are two sources of commits:

- **Agent commits** (via `agent` shell tool calls) — these already show up as `SHELL ...` in the activity stream because `scripts/stream-parser.sh` parses `shellToolCall` completion.
- **Loop commits** (e.g. “checkpoint before loop/single iteration”) — these are run by `scripts/ralph`/`scripts/ralph-common.sh` directly and currently **do not** emit activity events.

Plan:

- In `[/Users/ryancook/workspace/tmp/ralph-wiggum-cursor-beads/scripts/stream-parser.sh](/Users/ryancook/workspace/tmp/ralph-wiggum-cursor-beads/scripts/stream-parser.sh)`:
- Add `detect_git_commit()` invoked on successful `shellToolCall` completions.
- Parse the commit **subject** from `stdout` when possible (typical output includes `[branch sha] subject`).
- Fall back to parsing the `-m "..."` argument if stdout doesn’t match.
- Emit a single activity line like: `GIT COMMIT: <subject>`.
- In `[/Users/ryancook/workspace/tmp/ralph-wiggum-cursor-beads/scripts/ralph-common.sh](/Users/ryancook/workspace/tmp/ralph-wiggum-cursor-beads/scripts/ralph-common.sh)`:
- After loop-driven commits succeed, append an activity event to `activity.log` (and optionally echo to stderr if you want it visible even without tailing).
- Subject source: `git log -1 --pretty=%s` right after the commit.

## Validation

- Run the repo’s stated bash syntax check:
- `bash -n scripts/ralph scripts/*.sh`
- Update `test-smoke.sh` so it no longer expects wrapper scripts to exist; keep smoke coverage for `./ralph --help` and any other core flows you care about.

## Notes / small cleanup discovered while reviewing your example

- Your example run ends with: `scripts/stream-parser.sh: line 371: lds: command not found`.
- During implementation I’ll locate and remove/fix the stray `lds` invocation so the run completes cleanly.
