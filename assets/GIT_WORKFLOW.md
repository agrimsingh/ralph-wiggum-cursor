# Ralph Wiggum Cursor Skill: Git Workflow for Cloud Mode

This document outlines the git branching and merging strategy when using the Ralph Wiggum Cursor Skill in **Cloud Mode**. Understanding this workflow is crucial for seamless collaboration between your local environment and the automated Cloud Agents.

## Core Concepts

-   **`main` branch**: This is the primary branch representing the stable, human-supervised state of the project. All local development and manual interventions should happen on `main`.
-   **`ralph-iteration-N` branches**: These are temporary, single-purpose branches created by the Cloud Agent Spawner. Each branch corresponds to one "fresh context" work session by a Cloud Agent.

## The Workflow Cycle

The process is a loop of local work, automated handoff, cloud-based work, and manual integration.

### 1. Local Development (on `main`)

-   You begin the task by working in your local Cursor environment on the `main` branch.
-   You use the Ralph skill, which tracks context usage via its hooks (`beforeSubmitPrompt`, `beforeReadFile`, etc.).
-   You commit your changes to `main` as you make progress.

### 2. Handoff to Cloud Agent (Automated)

-   When the `stop-hook` detects that the context limit has been reached (a "gutter" situation), it triggers the `spawn-cloud-agent.sh` script.
-   **Crucially, this script first commits any uncommitted local changes to your current branch (`main`) and force-pushes them to the remote origin.** This ensures the Cloud Agent starts with the absolute latest version of your work.
-   The script then calls the Cursor API to spawn a new Cloud Agent.
-   The new agent is instructed to:
    -   Check out the `main` branch.
    -   Create a new branch named `ralph-iteration-N` (e.g., `ralph-iteration-1`).
    -   Begin work on this new branch.

### 3. Cloud Agent Work (on `ralph-iteration-N`)

-   The Cloud Agent operates entirely on its dedicated iteration branch.
-   It reads the task definition (`RALPH_TASK.md`) and state files (`.ralph/guardrails.md`, `.ralph/errors.log`) to understand the state of the project.
-   It continues the task, committing its changes to the `ralph-iteration-N` branch.
-   The agent works until it either completes the task, gets stuck (outputs `<ralph>GUTTER</ralph>`), or hits its own context limits.

### 4. Merging Back to `main` (Manual)

-   Once the Cloud Agent has finished its work (or you decide to intervene), you need to integrate its changes back into the `main` branch.
-   This is a **manual step** that gives you full control and oversight.

-   **Recommended process:**

    1.  **Fetch the changes**: `git fetch origin`
    2.  **Check out the agent's branch**: `git checkout ralph-iteration-1`
    3.  **Review the work**: Examine the commits and the code changes made by the agent. Run tests (`npm test`) to ensure everything is working as expected.
    4.  **Switch back to `main`**: `git checkout main`
    5.  **Merge the changes**: `git merge --squash ralph-iteration-1`

        -   We strongly recommend using `--squash` to condense all of the agent's incremental commits into a single, clean commit on the `main` branch. This keeps your `main` branch history tidy and meaningful.

    6.  **Create a merge commit**: `git commit -m "feat: Integrate work from Ralph cloud iteration 1"`
    7.  **Push the merged changes**: `git push origin main`

### 5. Clean Up

-   After successfully merging, you can delete the temporary iteration branch from both your local repository and the remote.

    ```bash
    # Delete local branch
    git branch -d ralph-iteration-1

    # Delete remote branch
    git push origin --delete ralph-iteration-1
    ```

## Diagram of the Flow

```
(main)      A---B---------------------------G---H---> (local work)
             \
              \
(ralph-iter-1) ---C---D---E---F------------> (cloud agent work)
```

-   **A, B**: Your local commits on `main`.
-   **Handoff**: At commit `B`, the context limit is reached. Changes are pushed.
-   **C, D, E, F**: Automated commits by the Cloud Agent on the `ralph-iteration-1` branch.
-   **G**: You create a squash merge commit on `main` that incorporates all of the agent's work (C-F).
-   **H**: You continue your local work on `main`.

This workflow provides a robust and auditable process for autonomous development, combining the power of fresh-context AI agents with the safety of human-in-the-loop review and integration.
