---
task: [Brief description of the task]
test_command: "npm test"
---

# Task: [Task Name]

## Overview

[Describe what needs to be built/fixed/improved]

## Requirements

### Functional Requirements

1. [Requirement 1]
2. [Requirement 2]
3. [Requirement 3]

### Non-Functional Requirements

- [Performance, security, etc.]

## Constraints

- [Technology constraints]
- [Time constraints]
- [Other limitations]

## Success Criteria

The following will be converted to Beads tasks when Ralph first runs.
Progress is tracked via `bd ready`, `bd close`, etc.

1. [Verifiable criterion 1]
2. [Verifiable criterion 2]
3. [Verifiable criterion 3]

## Notes

[Any additional context, links to documentation, etc.]

---

## Ralph Instructions

When working on this task:

1. Check `bd ready --label ralph:<runId> --json` to find the next available task
2. Claim it: `bd update <id> --status in_progress --json`
3. Work on the task
4. Close when done: `bd close <id> --reason "description" --json`
5. Sync: `bd sync`
6. Check `.ralph/guardrails.md` for signs to follow
7. Commit your changes with descriptive messages
8. When all tasks are closed, output: `<ralph>COMPLETE</ralph>`
9. If stuck on the same issue 3+ times, output: `<ralph>GUTTER</ralph>`
