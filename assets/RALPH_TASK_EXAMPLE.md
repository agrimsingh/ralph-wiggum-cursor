---
task: Build a REST API for task management
test_command: "npm test"
completion_criteria:
  - All CRUD endpoints working and tested
  - Input validation implemented
  - Tests passing with >80% coverage
  - API documentation complete
max_iterations: 50
---

# Task: Task Management REST API

## Overview

Build a simple but production-ready REST API for managing tasks (todo items). The API should follow REST conventions and include proper error handling, validation, and documentation.

## Requirements

### Functional Requirements

1. **Create Task** - POST /tasks
   - Accept title (required), description (optional), due_date (optional)
   - Return created task with generated ID

2. **List Tasks** - GET /tasks
   - Return all tasks
   - Support filtering by status (pending/completed)
   - Support pagination (limit/offset)

3. **Get Task** - GET /tasks/:id
   - Return single task by ID
   - Return 404 if not found

4. **Update Task** - PUT /tasks/:id
   - Update any task fields
   - Return updated task
   - Return 404 if not found

5. **Delete Task** - DELETE /tasks/:id
   - Remove task
   - Return 204 on success
   - Return 404 if not found

6. **Complete Task** - PATCH /tasks/:id/complete
   - Mark task as completed
   - Set completed_at timestamp

### Non-Functional Requirements

- Response time < 100ms for all endpoints
- Proper HTTP status codes
- JSON error responses with meaningful messages
- Request logging

## Constraints

- Use TypeScript
- Use Express.js framework
- Use SQLite for storage (file-based, no external DB needed)
- Follow REST conventions
- No authentication required (keep it simple)

## Success Criteria

The task is complete when ALL of the following are true:

1. [ ] `npm start` runs the server without errors
2. [ ] POST /tasks implemented (validation + tests)
3. [ ] GET /tasks implemented (pagination/filtering + tests)
4. [ ] GET /tasks/:id implemented (404 + tests)
5. [ ] PUT /tasks/:id implemented (validation + 404 + tests)
6. [ ] PATCH /tasks/:id/complete implemented (tests)
7. [ ] DELETE /tasks/:id implemented (404 + tests)
8. [ ] Test coverage > 80% (run `npm test -- --coverage`)
9. [ ] README.md documents all endpoints with examples

## Technical Notes

Suggested project structure:
```
src/
  index.ts        # Entry point
  routes/
    tasks.ts      # Task routes
  models/
    task.ts       # Task model/schema
  db/
    sqlite.ts     # Database setup
  middleware/
    validation.ts # Input validation
tests/
  tasks.test.ts   # API tests
```

## Example Requests

```bash
# Create task
curl -X POST http://localhost:3000/tasks \
  -H "Content-Type: application/json" \
  -d '{"title": "Buy groceries", "description": "Milk, eggs, bread"}'

# List tasks
curl http://localhost:3000/tasks

# Get task
curl http://localhost:3000/tasks/1

# Update task
curl -X PUT http://localhost:3000/tasks/1 \
  -H "Content-Type: application/json" \
  -d '{"title": "Buy groceries", "description": "Milk, eggs, bread, cheese"}'

# Complete task
curl -X PATCH http://localhost:3000/tasks/1/complete

# Delete task
curl -X DELETE http://localhost:3000/tasks/1
```

---

## Ralph Instructions

When working on this task:

1. Check `.ralph/guardrails.md` for signs to follow
2. Work on the next incomplete criterion from the checklist above
3. Commit your changes with descriptive messages
4. Run tests frequently to verify progress
5. When ALL criteria are met (all `[ ]` → `[x]`), output: `<ralph>COMPLETE</ralph>`
6. If stuck on the same issue 3+ times, output: `<ralph>GUTTER</ralph>`
