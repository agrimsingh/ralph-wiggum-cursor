---
name: ralph-wiggum
description: Implements the Ralph Wiggum autonomous iteration technique with deliberate context management. Use when building greenfield projects, iterating on well-defined tasks, or when continuous autonomous development is needed. Manages context like memory - tracks allocations, prevents redlining, and knows when to start fresh.
license: MIT
compatibility: Designed for Cursor (nightly). Requires bash, jq, git.
metadata:
  author: Based on Geoffrey Huntley's Ralph technique
  version: "1.0.0"
  original: https://ghuntley.com/ralph/
---

# Ralph Wiggum: Autonomous Iteration with Context Engineering

Ralph is a technique for autonomous AI development. In its purest form, Ralph is a loop that repeatedly feeds the same prompt to an AI agent, letting it iterate on a task until completion. The key insight is that **context is like memory** - when you `malloc()` data into the context window, it cannot be `free()`'d except by starting fresh.

## Core Philosophy

> "That's the beauty of Ralph - the technique is deterministically bad in an undeterministic world."

Ralph will make mistakes. That's expected. Each mistake is an opportunity to add a "sign" (guardrail) that prevents that mistake in the future. Like tuning a guitar, you adjust Ralph until it plays the right notes.

### The malloc/free Metaphor

- **Context is memory**: Everything loaded into the LLM's context window stays there
- **You cannot free() context**: The only way to clear context is to start a new conversation
- **One task per context**: Mixed concerns lead to autoregressive failure
- **Don't redline**: Pushing context to limits degrades performance
- **Gutter detection**: Once the bowling ball is in the gutter, start fresh

## How This Skill Works

### State Files (The Persistent Memory)

Ralph tracks state in files, NOT in context:

```
.ralph/
├── state.md           # Current iteration, task, completion criteria
├── guardrails.md      # Accumulated "signs" from observed failures  
├── context-log.md     # What's been loaded into context
├── failures.md        # Failure patterns for learning
└── progress.md        # What's been accomplished
```

### The Iteration Cycle

1. **Read state files** to understand current task and progress
2. **Check guardrails** for relevant "signs" to follow
3. **Work on the task** - implement, test, refine
4. **Update progress** in files (not just context)
5. **Commit checkpoint** via git
6. **Evaluate completion** against criteria
7. **If not complete**: Signal for next iteration
8. **If stuck**: Detect gutter, suggest fresh context

### Guardrails ("Signs")

When Ralph makes a mistake, add a sign:

```markdown
## Sign: Don't Jump Off The Slide
- **Trigger**: When implementing authentication
- **Instruction**: Always validate tokens before trusting claims
- **Added after**: Iteration 5 - security vulnerability introduced
```

Signs accumulate in `guardrails.md` and are injected into future iterations.

## Usage

### Starting a Ralph Loop

Create a `RALPH_TASK.md` file in your project root:

```markdown
---
task: Build a REST API for task management
completion_criteria:
  - All CRUD endpoints working
  - Input validation implemented
  - Tests passing with >80% coverage
  - API documentation complete
max_iterations: 50
---

## Requirements

Build a task management API with the following endpoints:
- POST /tasks - Create a task
- GET /tasks - List all tasks
- GET /tasks/:id - Get a task
- PUT /tasks/:id - Update a task
- DELETE /tasks/:id - Delete a task

## Constraints

- Use TypeScript
- Use Express.js
- Use SQLite for storage
- Follow REST conventions
```

Then tell Cursor: "Start a Ralph loop on this task"

### Monitoring Progress

Check `.ralph/progress.md` to see what's been accomplished:

```markdown
## Iteration 1
- Created project structure
- Implemented POST /tasks endpoint
- Status: Partial progress

## Iteration 2
- Added GET endpoints
- Fixed validation bug
- Status: Continuing
```

### When to Start Fresh

Ralph will detect "gutter" situations:
- Same error repeated 3+ times
- Context approaching limits
- Circular failure patterns

When detected, Ralph will suggest: "Context is polluted. Recommend starting fresh conversation."

## Best Practices

### 1. Clear Completion Criteria

❌ Bad: "Make a good API"
✅ Good: "All tests passing, coverage >80%, docs complete"

### 2. Incremental Goals

❌ Bad: "Build complete e-commerce platform"
✅ Good: Phase 1: Auth, Phase 2: Products, Phase 3: Cart

### 3. Let Failures Teach

Don't intervene too quickly. Let Ralph fail, then add signs.

### 4. Trust the Files

Progress is in files and git, not in your head or the context.

### 5. Fresh Context is Cheap

Don't hesitate to start fresh. State persists in files.

## Integration with Cursor Hooks

This skill uses Cursor hooks for:

- **beforeSubmitPrompt**: Inject guardrails and context awareness
- **beforeReadFile**: Track context allocations
- **afterFileEdit**: Update progress tracking
- **stop**: Evaluate completion, trigger next iteration or fresh start

See `scripts/` for hook implementations.

## Learn More

- Original technique: https://ghuntley.com/ralph/
- Context engineering: https://ghuntley.com/gutter/
- malloc/free metaphor: https://ghuntley.com/allocations/
