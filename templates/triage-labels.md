# Triage Labels

The skills speak in terms of five canonical triage roles, plus two category roles. This repo's tracker is YouTrack, which has no free-form label field. Triage roles are recorded via a dedicated custom field, **`Triage`** (single-value enum), set/read through `mcp__youtrack__update_issue` / `mcp__youtrack__get_issue` `customFields` — kept separate from `State`, which continues to track real engineering workflow (`Open`, `In Progress`, `Fixed`, etc.).

| Role in mattpocock/skills | Representation in YouTrack ({{PROJECT_KEY}}) | Meaning                                  |
| -------------------------- | --------------------------------------------- | ----------------------------------------- |
| `needs-triage`              | `Triage: needs-triage`                        | Maintainer needs to evaluate this issue   |
| `needs-info`                | `Triage: needs-info`                          | Waiting on reporter for more information  |
| `ready-for-agent`           | `Triage: ready-for-agent`                     | Fully specified, ready for an AFK agent   |
| `ready-for-human`           | `Triage: ready-for-human`                     | Requires human implementation             |
| `wontfix`                   | `Triage: wontfix`                             | Will not be actioned                      |
| `bug` (category)            | `Type: Bug`                                   | Something is broken                       |
| `enhancement` (category)    | `Type: Feature`                               | New feature or improvement                |

When a skill mentions a state role (e.g. "apply the AFK-ready triage label"), set `Triage` to the corresponding value via `mcp__youtrack__update_issue` (`customFields: {"Triage": "ready-for-agent"}`). For category, use the native `Type` custom field (`Bug`/`Feature`/etc.) — YouTrack already models this natively, so there's no separate category tag.

Exactly one `Triage` value (and ideally one `Type`) should be present per triaged issue. Filter with `mcp__youtrack__search_issues` using `Triage: <value>` (e.g. `project: {{PROJECT_KEY}} Triage: ready-for-agent`).

**Note:** the `Triage` field and its five values already exist on {{PROJECT_KEY}} — same convention as every other project on this instance. Creating custom fields or bundle values is not possible through MCP; that needs the YouTrack UI (Project Settings → Custom Fields), or the `youtrack-new-project` skill, which does it over the REST API. Each project gets its **own** enum bundle when the shared field is attached to it (`{{PROJECT_NAME}}: Triage` here), so values added to one project do not appear in the others.
