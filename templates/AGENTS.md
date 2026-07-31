## Agent skills

### Issue tracker

YouTrack, project {{PROJECT_KEY}} (`uranodev.youtrack.cloud`), via the `mcp__youtrack__*` tools — configured at user scope, so no per-repo setup. See `docs/agents/issue-tracker.md`.

Two conventions that are easy to miss: ordered subtasks need formal **`depends on`** links (this instance has no `blocked by`), and every issue hangs off an umbrella `Type: Epic` issue via `parentIssue` / `subtask of`.

### Triage labels

Five canonical triage roles mapped to a dedicated `Triage` enum custom field on {{PROJECT_KEY}}; category (bug/enhancement) uses the native `Type` field. `State` stays reserved for engineering workflow. See `docs/agents/triage-labels.md`.
