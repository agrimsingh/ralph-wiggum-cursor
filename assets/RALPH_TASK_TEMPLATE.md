---
task: [Brief description of the task]
completion_criteria:
  - [Criterion 1 - must be objectively verifiable]
  - [Criterion 2]
  - [Criterion 3]
max_iterations: 50
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

The task is complete when ALL of the following are true:

1. [ ] [Verifiable criterion 1]
2. [ ] [Verifiable criterion 2]
3. [ ] [Verifiable criterion 3]

## Notes

[Any additional context, links to documentation, etc.]

---

## Ralph Instructions

When working on this task:

1. Read `.ralph/progress.md` to see what's been done
2. Check `.ralph/guardrails.md` for signs to follow
3. Work on the next incomplete criterion
4. Update `.ralph/progress.md` with your progress
5. Commit your changes with descriptive messages
6. When ALL criteria are met, say: `RALPH_COMPLETE: All criteria satisfied`
7. If stuck on the same issue 3+ times, say: `RALPH_GUTTER: Need fresh context`
