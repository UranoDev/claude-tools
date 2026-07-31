# Issue tracker: YouTrack

Issues and specs (PRDs) for this repo live as YouTrack issues in the **{{PROJECT_KEY}}** project ("{{PROJECT_NAME}}") on `uranodev.youtrack.cloud`. Use the `mcp__youtrack__*` tools for all operations — there is no CLI.

The MCP server is configured at **user scope** (`~/.claude.json` → `mcpServers.youtrack`), so it is available in every session on this machine; the `mcp__youtrack__*` permissions are likewise pre-approved in `~/.claude/settings.json`. Nothing has to be set up per repo. If the tools report "requires re-authorization" or are missing entirely, the session was started before that config existed (or before the token was rotated) — restart the session, MCP servers only connect at startup.

## Conventions

- **Create an issue**: `mcp__youtrack__create_issue` with `project: "{{PROJECT_KEY}}"`, a `summary`, and `description` (Markdown is fine). Set `customFields` for `Type`, `Priority` and `Triage` where known — none are required at creation. Use `parentIssue` to link a ticket under an Epic/spec issue.
- **Read an issue**: `mcp__youtrack__get_issue` with the issue ID (e.g. `{{PROJECT_KEY}}-4`) — returns summary, description, custom fields, and recent comments. Use `mcp__youtrack__get_issue_comments` for the full comment history.
- **List / search issues**: `mcp__youtrack__search_issues` with a query like `project: {{PROJECT_KEY}} State: Open` or `project: {{PROJECT_KEY}} for: me`.
- **Comment on an issue**: `mcp__youtrack__add_issue_comment`.
- **Change state / triage fields**: `mcp__youtrack__update_issue`, setting `customFields.State` (engineering workflow) or `customFields.Triage` (triage role — see `docs/agents/triage-labels.md`).
- **Assign**: `mcp__youtrack__change_issue_assignee`.
- **Close**: `mcp__youtrack__update_issue` setting `customFields.State` to `Fixed` (or `Won't fix`/`Obsolete` as appropriate).

## Fields available on {{PROJECT_KEY}}

| Field | Values |
| --- | --- |
| `Type` | `Bug`, `Cosmetics`, `Exception`, `Feature`, `Task`, `Usability Problem`, `Performance Problem`, `Epic` |
| `State` | `Submitted`, `Open`, `In Progress`, `To be discussed`, `Reopened`, `Can't Reproduce`, `Duplicate`, `Fixed`, `Won't fix`, `Incomplete`, `Obsolete`, `Verified` |
| `Priority` | `Show-stopper`, `Critical`, `Major`, `Normal`, `Minor` |
| `Triage` | `needs-triage`, `needs-info`, `ready-for-agent`, `ready-for-human`, `wontfix` |
| `Cost` | float — accumulated USD spent on the issue |
| others | `Subsystem`, `Fix versions`, `Affected versions`, `Fixed in build`, `Assignee` |

> Verify this table against the live project with `mcp__youtrack__get_issue_fields_schema` (`projectKey: "{{PROJECT_KEY}}"`) and delete any row the project does not actually have. Custom fields and enum values cannot be created through MCP — that needs the YouTrack UI (Project Settings → Custom Fields).

`Triage` carries the triage roles the skills ask for — see `docs/agents/triage-labels.md`. `State` stays reserved for engineering workflow.

`Cost` is a float meant to accumulate what an issue cost to build (the pattern `ralph.ps1` uses in the nvavista repo: it adds each loop cycle's USD to the field and comments the cycle cost on the issue).

## Linking issues

Use `mcp__youtrack__link_issues`. The link types configured on this instance are exactly:

| Type | Forward | Reverse |
| --- | --- | --- |
| `Relates` | `relates to` | (same) |
| `Depend` | `is required for` | `depends on` |
| `Duplicate` | `is duplicated by` | `duplicates` |
| `Subtask` | `parent for` | `subtask of` |

There is **no `blocked by`** link type. Represent a "blocked by" edge with `depends on`:

```json
{ "targetIssueId": "<blocked>", "linkType": "depends on", "issueToLinkId": "<blocker>" }
```

Three rules that are easy to skip and matter:

1. **Ordered subtasks get formal `depends on` links** — not just a sentence in the description saying "after {{PROJECT_KEY}}-5". If step 2 cannot start until step 1 lands, that edge must exist as a link, so the order survives outside the description.
2. **Every issue hangs off its umbrella.** Break work down as an Epic (`Type: Epic`) plus subtasks linked to it. Pass `parentIssue` **in the create call** — `subtask of` afterwards is the repair, not the routine: an issue born loose stays loose if anything interrupts before you get back to it. Umbrella issues are excluded from changelog generation by their `Type: Epic`.
3. **New issues carry `Triage: ready-for-agent`**, set in that same create call. Two exceptions: the project must actually have the `Triage` field, and an issue created *already resolved* — the retroactive record of work that is already done — takes no `Triage` at all, because there is nothing left to pick up.

None of this is enforced by a YouTrack workflow. Nothing fails when it is skipped, which is exactly why it gets skipped: the issue looks correct on its own, and only the Epic's subtask list — which nobody opens while writing a ticket — shows what is missing.

## When a skill says "publish to the issue tracker"

Create a YouTrack issue in `{{PROJECT_KEY}}` via `mcp__youtrack__create_issue`.

## When a skill says "fetch the relevant ticket"

Call `mcp__youtrack__get_issue` with the referenced issue ID. The user will normally pass the ID (e.g. `{{PROJECT_KEY}}-7`) or a link to `uranodev.youtrack.cloud`.
