# Ralph Wiggum for Cursor

An implementation of [Geoffrey Huntley's Ralph Wiggum technique](https://ghuntley.com/ralph/) for Cursor, enabling autonomous AI development with deliberate context management.

> "That's the beauty of Ralph - the technique is deterministically bad in an undeterministic world."

## What is Ralph?

Ralph is a technique for autonomous AI development that treats LLM context like memory:

```bash
while :; do cat PROMPT.md | agent ; done
```

The same prompt is fed repeatedly to an AI agent. Progress persists in **files, git, and [Beads](https://github.com/steveyegge/beads)**, not in the LLM's context window. When context fills up, you get a fresh agent with fresh context.

### The malloc/free Problem

In traditional programming:

- `malloc()` allocates memory
- `free()` releases memory

In LLM context:

- Reading files, tool outputs, conversation = `malloc()`
- **There is no `free()`** - context cannot be selectively released
- Only way to free: start a new conversation

This creates two problems:

1. **Context pollution** - Failed attempts, unrelated code, and mixed concerns accumulate and confuse the model
2. **The gutter** - Once polluted, the model keeps referencing bad context. Like a bowling ball in the gutter, there's no saving it.

**Ralph's solution:** Deliberately rotate to fresh context before pollution builds up. State lives in files, git, and Beads — not in the LLM's memory.

## Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                         ./ralph                              │
│                           │                                  │
│              ┌────────────┴────────────┐                    │
│              ▼                         ▼                    │
│         [gum UI]                  [fallback]                │
│     Model selection            Simple prompts               │
│     Max iterations                                          │
│     Options (branch, PR)                                    │
│              │                         │                    │
│              └────────────┬────────────┘                    │
│                           ▼                                  │
│    cursor-agent -p --force --output-format stream-json       │
│                           │                                  │
│                           ▼                                  │
│                   stream-parser.sh                           │
│                      │        │                              │
│     ┌────────────────┴────────┴────────────────┐            │
│     ▼                                           ▼            │
│  Per-run state (.ralph/runs/<runId>/)       Signals          │
│  ├── activity.log  (tool calls)             ├── WARN at 70k │
│  ├── errors.log    (failures)               ├── ROTATE at 80k│
│  ├── beads.label   (task label)             ├── COMPLETE    │
│  └── beads.root_id (epic ID)                └── GUTTER      │
│                                                              │
│  Shared: .ralph/guardrails.md (lessons learned)             │
│                                                              │
│  Progress tracked via Beads (bd) not checkboxes             │
│  When ROTATE → fresh context, continue from git             │
└─────────────────────────────────────────────────────────────┘
```

**Key features:**

- **Beads-backed task tracking** - Success criteria become Beads issues, completion via `bd close`
- **Interactive setup** - Beautiful gum-based UI for model selection and options
- **Accurate token tracking** - Parser counts actual bytes from every file read/write
- **Gutter detection** - Detects when agent is stuck (same command failed 3x, file thrashing)
- **Learning from failures** - Agent updates `.ralph/guardrails.md` with lessons
- **State in git** - Commits frequently so next agent picks up from git history
- **Parallel runs** - Multiple task files can run concurrently with isolated state
- **Branch/PR workflow** - Optionally work on a branch and open PR when complete

## Prerequisites

| Requirement          | Check                | How to Set Up                                      |
| -------------------- | -------------------- | -------------------------------------------------- |
| **Git repo**         | `git status` works   | `git init`                                         |
| **bd (Beads)**       | `which bd`           | See [Beads install](#install-beads)                |
| **cursor-agent CLI** | `which cursor-agent` | `curl https://cursor.com/install -fsS \| bash`     |
| **gum** (optional)   | `which gum`          | Installer offers to install, or `brew install gum` |

### Install Beads

Ralph uses [Beads](https://github.com/steveyegge/beads) for task tracking. Install it first:

```bash
# Option 1: curl installer (recommended)
curl -fsSL https://raw.githubusercontent.com/steveyegge/beads/main/scripts/install.sh | bash

# Option 2: Homebrew (macOS/Linux)
brew install steveyegge/beads/bd

# Option 3: npm
npm install -g @beads/bd
```

Then initialize Beads in your project (the installer does this automatically):

```bash
bd init --stealth --quiet
```

## Quick Start

### 1. Install Ralph

```bash
cd your-project
curl -fsSL https://raw.githubusercontent.com/agrimsingh/ralph-wiggum-cursor/main/install.sh | bash
```

This creates:

```
your-project/
├── ralph                       # Main entry point
├── .cursor/ralph-scripts/      # Internal scripts
│   ├── ralph                   # CLI implementation
│   ├── ralph-common.sh         # Shared functions
│   └── stream-parser.sh        # Token tracking
├── .ralph/                     # State files
│   ├── guardrails.md           # Lessons learned (shared)
│   └── runs/<runId>/           # Per-run state (created on first run)
│       ├── activity.log        # Tool call log
│       ├── errors.log          # Failure log
│       ├── beads.label         # Beads label for this run
│       └── beads.root_id       # Root epic ID
└── .gitignore                  # Ignores RALPH_TASK.md (local plan doc)
```

### 2. (Optional) gum for Enhanced UI

The installer will offer to install gum automatically. You can also:

- Skip the prompt and auto-install: `curl ... | INSTALL_GUM=1 bash`
- Install manually: `brew install gum` (macOS) or see [gum installation](https://github.com/charmbracelet/gum#installation)

With gum, you get a beautiful interactive menu for selecting models and options.

### 3. Create Your Task/Plan File

Ralph uses **Beads-first task tracking**. You bring your own task/plan file — it can live anywhere:

```bash
# Get the template
./ralph --print-template > RALPH_TASK.md

# Or put it in a plans directory
mkdir -p plans
./ralph --print-template > plans/api.md
```

Edit your plan file (e.g., `plans/api.md`):

```markdown
---
task: Build a REST API
test_command: "npm test"
---

# Task: REST API

Build a REST API with user management.

## Success Criteria

The following will be converted to Beads tasks when you first run Ralph:

1. GET /health returns 200
2. POST /users creates a user
3. GET /users/:id returns user
4. All tests pass

## Context

- Use Express.js
- Store users in memory (no database needed)
```

**Key points:**

- Plan files can live anywhere (recommended: `plans/` or `tasks/` directory)
- Each plan file gets its own Beads issues and isolated run state
- `RALPH_TASK.md` is supported as a legacy fallback (gitignored by default)
- To version your plan docs, either keep them outside the root or remove `RALPH_TASK.md` from `.gitignore`

### 4. Start the Loop

```bash
# Run with default task file (RALPH_TASK.md)
./ralph

# Or with a custom plan file
./ralph --task-file plans/api.md

# Or with a custom run ID for parallel runs
./ralph --task-file plans/api.md --run-id api
```

Ralph will:

1. Bootstrap Beads issues from your Success Criteria (first run only)
2. Show interactive UI for model and options (or simple prompts if gum not installed)
3. Run `cursor-agent` with your task
4. Agent works via `bd ready` → `bd update --status in_progress` → `bd close`
5. At 70k tokens: warn agent to wrap up current work
6. At 80k tokens: rotate to fresh context
7. Repeat until all Beads tasks are closed (or max iterations reached)

**Legacy fallback:** If `RALPH_TASK.md` exists and you don't pass `--task-file`, Ralph will use it.

### 5. Monitor Progress

```bash
# See all Beads tasks for this run
bd list --label ralph:<runId> --json

# Watch activity in real-time
tail -f .ralph/runs/<runId>/activity.log

# Example output:
# [12:34:56] 🟢 READ src/index.ts (245 lines, ~24.5KB)
# [12:34:58] 🟢 WRITE src/routes/users.ts (50 lines, 2.1KB)
# [12:35:01] 🟢 SHELL npm test → exit 0
# [12:35:10] 🟢 TOKENS: 45,230 / 80,000 (56%)

# Check for failures
cat .ralph/runs/<runId>/errors.log
```

## Parallel Runs (Multi-Plan Workflows)

Ralph is designed for **multi-plan workflows**. Run multiple tasks in parallel with isolated state:

```bash
# Terminal 1: Work on API
./ralph --task-file plans/api.md --run-id api -y &

# Terminal 2: Work on UI
./ralph --task-file plans/ui.md --run-id ui -y &

# Wait for both
wait
```

Each run gets:

- Its own state directory: `.ralph/runs/<runId>/`
- Its own Beads label: `ralph:<runId>`
- Its own root epic with child tasks

**Recommended project structure:**

```
your-project/
├── plans/
│   ├── api.md          # API task definition
│   ├── ui.md           # UI task definition
│   └── refactor.md     # Refactoring task
├── .ralph/
│   └── runs/
│       ├── api/        # API run state
│       └── ui/         # UI run state
└── .cursor/ralph-scripts/
```

## Usage

```bash
./ralph [options] [workspace]

Options:
  --task-file, -f FILE   Task/plan file (default: RALPH_TASK.md)
  --run-id, -r ID        Run ID for state isolation (default: derived from task file)
  --once                 Run single iteration then stop (for testing)
  --limit N              Max iterations (default: 20)
  --model, -m MODEL      Model to use (default: opus-4.5-thinking)
  --branch NAME          Create and work on a new branch
  --pr                   Open PR when complete (requires --branch)
  --yes, -y              Skip confirmation prompts
  --print-template       Print task file template to stdout
  --init                 Initialize Ralph in current directory
  --help, -h             Show help
```

### Getting the Task Template

```bash
# Print template to stdout (pipe to file)
./ralph --print-template > RALPH_TASK.md

# Or to a plans directory
./ralph --print-template > plans/my-task.md

# Or copy to clipboard (macOS)
./ralph --print-template | pbcopy
```

### Examples

```bash
# Run with default task file (RALPH_TASK.md)
./ralph

# Run with custom plan file
./ralph --task-file plans/api.md

# Test single iteration before going AFK
./ralph --once

# Limit iterations
./ralph --limit=10

# Scripted PR workflow
./ralph --task-file plans/api.md --branch feature/api --pr -y

# Use a different model
./ralph --task-file plans/api.md --model gpt-5.2-high

# Parallel runs with different tasks
./ralph --task-file plans/api.md --run-id api -y &
./ralph --task-file plans/ui.md --run-id ui -y &
```

### Environment Variables

```bash
RALPH_MODEL=gpt-5.2-high        # Override default model
RALPH_TASK_FILE=TASK_A.md       # Override default task file
RALPH_RUN_ID=myrun              # Override run ID
MAX_ITERATIONS=50               # Override max iterations
```

## How It Works

### The Loop

```
Iteration 1                    Iteration 2                    Iteration N
┌──────────────────┐          ┌──────────────────┐          ┌──────────────────┐
│ Fresh context    │          │ Fresh context    │          │ Fresh context    │
│       │          │          │       │          │          │       │          │
│       ▼          │          │       ▼          │          │       ▼          │
│ Read task file   │          │ Read task file   │          │ Read task file   │
│ Read guardrails  │──────────│ Read guardrails  │──────────│ Read guardrails  │
│ Read progress    │  (state  │ Read progress    │  (state  │ Read progress    │
│       │          │  in git) │       │          │  in git) │       │          │
│       ▼          │          │       ▼          │          │       ▼          │
│ bd ready → work  │          │ bd ready → work  │          │ bd ready → work  │
│ bd close tasks   │          │ bd close tasks   │          │ bd close tasks   │
│ Commit to git    │          │ Commit to git    │          │ Commit to git    │
│       │          │          │       │          │          │       │          │
│       ▼          │          │       ▼          │          │       ▼          │
│ 80k tokens       │          │ 80k tokens       │          │ All tasks closed!│
│ ROTATE ──────────┼──────────┼──────────────────┼──────────┼──► COMPLETE      │
└──────────────────┘          └──────────────────┘          └──────────────────┘
```

Each iteration:

1. Reads task and state from files (not from previous context)
2. Uses `bd ready` to find next available task
3. Claims task with `bd update --status in_progress`
4. Works on the task
5. Closes task with `bd close --reason "..."`
6. Commits progress to git
7. Runs `bd sync` to persist Beads state
8. Rotates when context is full

### Beads Task Flow

```bash
# Find next task to work on
bd ready --label ralph:myrun --json

# Claim the task
bd update <task-id> --status in_progress --json

# ... do the work ...

# Mark complete
bd close <task-id> --reason "Implemented health endpoint" --json

# Sync to persist
bd sync
```

### Git Protocol

The agent is instructed to commit frequently:

```bash
# After each task
git add -A && git commit -m 'ralph: implement health endpoint'

# Push periodically
git push
```

**Commits are the agent's memory.** The next iteration picks up from git history.

### The Learning Loop (Signs)

When something fails, the agent adds a "Sign" to `.ralph/guardrails.md`:

```markdown
### Sign: Check imports before adding

- **Trigger**: Adding a new import statement
- **Instruction**: First check if import already exists in file
- **Added after**: Iteration 3 - duplicate import caused build failure
```

Future iterations read guardrails first and follow them, preventing repeated mistakes.

## Context Health Indicators

The activity log shows context health with emoji:

| Emoji | Status   | Token % | Meaning           |
| ----- | -------- | ------- | ----------------- |
| 🟢    | Healthy  | < 60%   | Plenty of room    |
| 🟡    | Warning  | 60-80%  | Approaching limit |
| 🔴    | Critical | > 80%   | Rotation imminent |

## Gutter Detection

The parser detects when the agent is stuck:

| Pattern          | Trigger                               | What Happens  |
| ---------------- | ------------------------------------- | ------------- |
| Repeated failure | Same command failed 3x                | GUTTER signal |
| File thrashing   | Same file written 5x in 10 min        | GUTTER signal |
| Agent signals    | Agent outputs `<ralph>GUTTER</ralph>` | GUTTER signal |

When gutter is detected:

1. Check `.ralph/runs/<runId>/errors.log` for the pattern
2. Fix the issue manually or add a guardrail
3. Re-run the loop

## Completion Detection

Ralph detects completion via Beads:

- **All tasks closed**: `bd list --label ralph:<runId> --status open|in_progress|blocked|deferred` returns empty
- **Agent sigil**: Agent outputs `<ralph>COMPLETE</ralph>`

Both are verified before declaring success.

## File Reference

| File                                | Purpose                               | Who Uses It                              |
| ----------------------------------- | ------------------------------------- | ---------------------------------------- |
| `ralph`                             | Main entry point                      | You run this                             |
| `RALPH_TASK.md`                     | Default task file (gitignored)        | Default if no `--task-file`              |
| `plans/*.md` (or any path)          | Task/plan files (BYO)                 | Pass via `--task-file`                   |
| `.ralph/guardrails.md`              | Lessons learned (Signs)               | Agent reads first, writes after failures |
| `.ralph/runs/<runId>/activity.log`  | Tool call log with token counts       | Parser writes, you monitor               |
| `.ralph/runs/<runId>/errors.log`    | Failures + gutter detection           | Parser writes, agent reads               |
| `.ralph/runs/<runId>/beads.label`   | Beads label for filtering             | Ralph reads/writes                       |
| `.ralph/runs/<runId>/beads.root_id` | Root epic ID                          | Ralph reads/writes                       |

## Troubleshooting

### "bd (Beads) CLI not found"

Install Beads:

```bash
curl -fsSL https://raw.githubusercontent.com/steveyegge/beads/main/scripts/install.sh | bash
bd init --stealth --quiet
```

### "cursor-agent CLI not found"

```bash
curl https://cursor.com/install -fsS | bash
```

### Agent keeps failing on same thing

Check `.ralph/runs/<runId>/errors.log` for the pattern. Either:

1. Fix the underlying issue manually
2. Add a guardrail to `.ralph/guardrails.md` explaining what to do differently

### Context rotates too frequently

The agent might be reading too many large files. Check `activity.log` for large READs and consider:

1. Adding a guardrail: "Don't read the entire file, use grep to find relevant sections"
2. Breaking the task into smaller pieces

### Task never completes

Check if criteria are too vague. Each criterion should be:

- Specific and testable
- Achievable in a single iteration
- Not dependent on manual steps

### Beads tasks not syncing

Run `bd sync` manually to force synchronization.

## Workflows

### Basic (recommended)

```bash
# Create your task file
./ralph --print-template > RALPH_TASK.md
# Edit RALPH_TASK.md...

# Run Ralph
./ralph
```

### Human-in-the-loop (recommended for new tasks)

```bash
# Test ONE iteration first
./ralph --once
# Review changes...

# Continue with full loop
./ralph
```

### Parallel tasks

```bash
# Run two different task files in parallel
./ralph --task-file plans/api.md --run-id api -y &
./ralph --task-file plans/ui.md --run-id ui -y &
wait
```

### Scripted/CI

```bash
./ralph --task-file plans/api.md --branch feature/api --pr -y
```

### Custom task file

```bash
# Create task file anywhere
./ralph --print-template > plans/my-task.md
# Edit plans/my-task.md...

# Run with custom task file
./ralph --task-file plans/my-task.md
```

## Deprecated Scripts

The following scripts are deprecated and will be removed in a future version. Use `ralph` instead:

| Deprecated Script | Replacement |
|-------------------|-------------|
| `scripts/ralph-setup.sh` | `ralph` |
| `scripts/ralph-once.sh` | `ralph once` |
| `scripts/ralph-loop.sh` | `ralph` |
| `scripts/init-ralph.sh` | `ralph init` |
| `scripts/init-ralph.sh --print-template` | `ralph template` |

These scripts now act as thin wrappers that delegate to `ralph` and print deprecation warnings. They will be removed in a future version.

## Learn More

- [Original Ralph technique](https://ghuntley.com/ralph/) - Geoffrey Huntley
- [Context as memory](https://ghuntley.com/allocations/) - The malloc/free metaphor
- [Beads issue tracker](https://github.com/steveyegge/beads) - Git-backed task tracking for agents
- [Cursor CLI docs](https://cursor.com/docs/cli/headless)
- [gum - A tool for glamorous shell scripts](https://github.com/charmbracelet/gum)

## Credits

- **Original technique**: [Geoffrey Huntley](https://ghuntley.com/ralph/) - the Ralph Wiggum methodology
- **Cursor port**: [Agrim Singh](https://x.com/agrimsingh) - this implementation
- **Beads integration**: For structured task tracking

## License

MIT
