# Ralph Wiggum for Cursor

An implementation of [Geoffrey Huntley's Ralph Wiggum technique](https://ghuntley.com/ralph/) for Cursor, enabling autonomous AI development with deliberate context management.

> "That's the beauty of Ralph - the technique is deterministically bad in an undeterministic world."

## What is Ralph?

Ralph is a technique for autonomous AI development that treats LLM context like memory:

```bash
while :; do cat PROMPT.md | agent ; done
```

The same prompt is fed repeatedly to an AI agent. Progress persists in **files and git**, not in the LLM's context window. When context fills up, you get a fresh agent with fresh context.

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

**Ralph's solution:** Deliberately rotate to fresh context before pollution builds up. State lives in files and git, not in the LLM's memory.

## Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                      ralph-setup.sh                          │
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
│  .ralph/                                    Signals          │
│  ├── activity.log  (tool calls)            ├── WARN at 70k  │
│  ├── errors.log    (failures)              ├── ROTATE at 80k│
│  ├── progress.md   (agent writes)          ├── COMPLETE     │
│  └── guardrails.md (lessons learned)       └── GUTTER       │
│                                                              │
│  When ROTATE → fresh context, continue from git             │
└─────────────────────────────────────────────────────────────┘
```

**Key features:**

- **Interactive setup** - Beautiful gum-based UI for model selection and options
- **Accurate token tracking** - Parser counts actual bytes from every file read/write
- **Gutter detection** - Detects when agent is stuck (same command failed 3x, file thrashing)
- **Learning from failures** - Agent updates `.ralph/guardrails.md` with lessons
- **State in git** - Commits frequently so next agent picks up from git history
- **Branch/PR workflow** - Optionally work on a branch and open PR when complete

## Prerequisites

| Requirement          | Check                | How to Set Up                                      |
| -------------------- | -------------------- | -------------------------------------------------- |
| **Git repo**         | `git status` works   | `git init`                                         |
| **cursor-agent CLI** | `which cursor-agent` | `curl https://cursor.com/install -fsS \| bash`     |
| **gum** (optional)   | `which gum`          | Installer offers to install, or `brew install gum` |

## Quick Start

### 1. Install Ralph

```bash
cd your-project
curl -fsSL https://raw.githubusercontent.com/agrimsingh/ralph-wiggum-cursor/main/install.sh | bash
```

This creates:

```
your-project/
├── .cursor/ralph-scripts/      # Ralph scripts
│   ├── ralph-setup.sh          # Main entry point (interactive)
│   ├── ralph-loop.sh           # CLI mode (for scripting)
│   ├── ralph-once.sh           # Single iteration (testing)
│   ├── stream-parser.sh        # Token tracking
│   ├── ralph-common.sh         # Shared functions
│   └── init-ralph.sh           # Re-initialize if needed
├── .ralph/                     # State files (tracked in git)
│   ├── progress.md             # Agent updates: what's done
│   ├── guardrails.md           # Lessons learned (Signs)
│   ├── activity.log            # Tool call log (parser writes)
│   └── errors.log              # Failure log (parser writes)
└── RALPH_TASK.md               # Your task definition
```

### 2. (Optional) gum for Enhanced UI

The installer will offer to install gum automatically. You can also:

- Skip the prompt and auto-install: `curl ... | INSTALL_GUM=1 bash`
- Install manually: `brew install gum` (macOS) or see [gum installation](https://github.com/charmbracelet/gum#installation)

With gum, you get a beautiful interactive menu for selecting models and options:

```
? Select model:
  ◉ opus-4.5-thinking
  ◯ sonnet-4.5-thinking
  ◯ gpt-5.2-high
  ◯ composer-1
  ◯ Custom...

? Max iterations: 20

? Options:
  ◯ Commit to current branch
  ◯ Run single iteration first
  ◯ Work on new branch
  ◯ Open PR when complete
```

Without gum, Ralph falls back to simple numbered prompts.

### 3. Define Your Task

Edit `RALPH_TASK.md` (or create a custom task file and use `-f` flag):

```markdown
---
task: Build a REST API
test_command: "npm test"
---

# Task: REST API

Build a REST API with user management.

## Success Criteria

1. [ ] GET /health returns 200
2. [ ] POST /users creates a user
3. [ ] GET /users/:id returns user
4. [ ] All tests pass

## Context

- Use Express.js
- Store users in memory (no database needed)
```

**Important:** Use `[ ]` checkboxes. Ralph tracks completion by counting unchecked boxes.

### 4. Start the Loop

```bash
./.cursor/ralph-scripts/ralph-setup.sh
```

Ralph will:

1. Show interactive UI for model and options (or simple prompts if gum not installed)
2. Run `cursor-agent` with your task
3. Parse output in real-time, tracking token usage
4. At 70k tokens: warn agent to wrap up current work
5. At 80k tokens: rotate to fresh context
6. Repeat until all `[ ]` are `[x]` (or max iterations reached)

### 5. Monitor Progress

```bash
# Watch activity in real-time
tail -f .ralph/activity.log

# Example output:
# [12:34:56] 🟢 READ src/index.ts (245 lines, ~24.5KB)
# [12:34:58] 🟢 WRITE src/routes/users.ts (50 lines, 2.1KB)
# [12:35:01] 🟢 SHELL npm test → exit 0
# [12:35:10] 🟢 TOKENS: 45,230 / 80,000 (56%) [read:30KB write:5KB assist:10KB shell:0KB]

# Check for failures
cat .ralph/errors.log
```

## Commands

| Command          | Description                                |
| ---------------- | ------------------------------------------ |
| `ralph-setup.sh` | **Primary** - Interactive setup + run loop |
| `ralph-once.sh`  | Test single iteration before going AFK     |
| `ralph-loop.sh`  | CLI mode for scripting (see flags below)   |
| `init-ralph.sh`  | Re-initialize Ralph state                  |

### ralph-loop.sh Flags (for scripting/CI)

```bash
./ralph-loop.sh [options] [workspace]

Options:
  -n, --iterations N     Max iterations (default: 20)
  -m, --model MODEL      Model to use (default: opus-4.5-thinking)
  -f, --file FILE        Task file to use (default: RALPH_TASK.md)
  --branch NAME          Create and work on a new branch
  --pr                   Open PR when complete (requires --branch)
  -y, --yes              Skip confirmation prompt
```

**Examples:**

```bash
# Scripted PR workflow
./ralph-loop.sh --branch feature/api --pr -y

# Use a different model with more iterations
./ralph-loop.sh -n 50 -m gpt-5.2-high

# Use a custom task file
./ralph-loop.sh -f tasks/api-task.md

# Combine options: custom task file with branch workflow
./ralph-loop.sh -f MY_TASK.md --branch feature/api --pr -y
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
│ Work on criteria │          │ Work on criteria │          │ Work on criteria │
│ Commit to git    │          │ Commit to git    │          │ Commit to git    │
│       │          │          │       │          │          │       │          │
│       ▼          │          │       ▼          │          │       ▼          │
│ 80k tokens       │          │ 80k tokens       │          │ All [x] done!    │
│ ROTATE ──────────┼──────────┼──────────────────┼──────────┼──► COMPLETE      │
└──────────────────┘          └──────────────────┘          └──────────────────┘
```

Each iteration:

1. Reads task and state from files (not from previous context)
2. Works on unchecked criteria
3. Commits progress to git
4. Updates `.ralph/progress.md` and `.ralph/guardrails.md`
5. Rotates when context is full

### Git Protocol

The agent is instructed to commit frequently:

```bash
# After each criterion
git add -A && git commit -m 'ralph: [criterion] - description'

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

```
Error occurs → errors.log → Agent analyzes → Updates guardrails.md → Future agents follow
```

## Context Health Indicators

The activity log shows context health with emoji:

| Emoji | Status   | Token % | Meaning           |
| ----- | -------- | ------- | ----------------- |
| 🟢    | Healthy  | < 60%   | Plenty of room    |
| 🟡    | Warning  | 60-80%  | Approaching limit |
| 🔴    | Critical | > 80%   | Rotation imminent |

Example:

```
[12:34:56] 🟢 READ src/index.ts (245 lines, ~24.5KB)
[12:40:22] 🟡 TOKENS: 58,000 / 80,000 (72%) - approaching limit [read:40KB write:8KB assist:10KB shell:0KB]
[12:45:33] 🔴 TOKENS: 72,500 / 80,000 (90%) - rotation imminent
```

## Gutter Detection

The parser detects when the agent is stuck:

| Pattern          | Trigger                               | What Happens  |
| ---------------- | ------------------------------------- | ------------- |
| Repeated failure | Same command failed 3x                | GUTTER signal |
| File thrashing   | Same file written 5x in 10 min        | GUTTER signal |
| Agent signals    | Agent outputs `<ralph>GUTTER</ralph>` | GUTTER signal |

When gutter is detected:

1. Check `.ralph/errors.log` for the pattern
2. Fix the issue manually or add a guardrail
3. Re-run the loop

## Completion Detection

Ralph detects completion in two ways:

1. **Checkbox check**: All `[ ]` in the task file changed to `[x]`
2. **Agent sigil**: Agent outputs `<ralph>COMPLETE</ralph>`

Both are verified before declaring success.

## File Reference

| File                   | Purpose                                                                  | Who Uses It                              |
| ---------------------- | ------------------------------------------------------------------------ | ---------------------------------------- |
| `RALPH_TASK.md`        | Task definition + success criteria (default, customizable via `-f` flag) | You define, agent reads                  |
| `.ralph/progress.md`   | What's been accomplished                                                 | Agent writes after work                  |
| `.ralph/guardrails.md` | Lessons learned (Signs)                                                  | Agent reads first, writes after failures |
| `.ralph/activity.log`  | Tool call log with token counts                                          | Parser writes, you monitor               |
| `.ralph/errors.log`    | Failures + gutter detection                                              | Parser writes, agent reads               |
| `.ralph/.iteration`    | Current iteration number                                                 | Parser reads/writes                      |

## Configuration

Configuration is set via command-line flags or environment variables:

```bash
# Via flags (recommended)
./ralph-loop.sh -n 50 -m gpt-5.2-high -f tasks/my-task.md

# Via environment
RALPH_MODEL=gpt-5.2-high MAX_ITERATIONS=50 TASK_FILE=tasks/my-task.md ./ralph-loop.sh
```

| Flag               | Environment Variable | Default             | Description                    |
| ------------------ | -------------------- | ------------------- | ------------------------------ |
| `-n, --iterations` | `MAX_ITERATIONS`     | `20`                | Max rotations before giving up |
| `-m, --model`      | `RALPH_MODEL`        | `opus-4.5-thinking` | Model to use                   |
| `-f, --file`       | `TASK_FILE`          | `RALPH_TASK.md`     | Task definition file           |

Default thresholds in `ralph-common.sh`:

```bash
MAX_ITERATIONS=20       # Max rotations before giving up
WARN_THRESHOLD=70000    # Tokens: send wrapup warning
ROTATE_THRESHOLD=80000  # Tokens: force rotation
```

## Troubleshooting

### "cursor-agent CLI not found"

```bash
curl https://cursor.com/install -fsS | bash
```

### Agent keeps failing on same thing

Check `.ralph/errors.log` for the pattern. Either:

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

## Workflows

### Basic (default)

```bash
./ralph-setup.sh  # Interactive setup → runs loop → done
```

### Human-in-the-loop (recommended for new tasks)

```bash
./ralph-once.sh   # Run ONE iteration
# Review changes...
./ralph-setup.sh  # Continue with full loop
```

### Custom Task File

Use the `-f` flag to specify a different task file:

```bash
# Useful for multiple tasks in the same repo
./ralph-loop.sh -f tasks/backend-api.md
./ralph-loop.sh -f tasks/frontend-ui.md

# Or via environment variable
TASK_FILE=MY_TASK.md ./ralph-loop.sh
```

### Scripted/CI

```bash
./ralph-loop.sh --branch feature/foo --pr -y

# With custom task file
./ralph-loop.sh -f tasks/ci-task.md --branch feature/foo --pr -y
```

## Learn More

- [Original Ralph technique](https://ghuntley.com/ralph/) - Geoffrey Huntley
- [Context as memory](https://ghuntley.com/allocations/) - The malloc/free metaphor
- [Cursor CLI docs](https://cursor.com/docs/cli/headless)
- [gum - A tool for glamorous shell scripts](https://github.com/charmbracelet/gum)

## Credits

- **Original technique**: [Geoffrey Huntley](https://ghuntley.com/ralph/) - the Ralph Wiggum methodology
- **Cursor port**: [Agrim Singh](https://x.com/agrimsingh) - this implementation

## License

MIT
