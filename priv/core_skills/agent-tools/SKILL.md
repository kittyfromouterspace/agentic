---
name: agent-tools
description: Workflow guidance for using agent tools effectively — memory, skills, credentials, integrations, collaboration
core: true
loading: always
type: skill
version: "2.0.0"
model_tier: any
---

## Tool Usage Guide

Your tools are self-describing — call them by name and check their schemas for parameters.
This guide covers workflows and patterns that aren't obvious from the schemas alone.

### Memory Workflow

Use `memory_note` to track intermediate results during a task (fast, session-scoped).
Use `memory_recall` to retrieve recent context from the current session.
Use `memory_query` with a search query at the start of complex tasks to pull cross-session context.
Use `memory_write` to persist important decisions or discoveries for future sessions.

### Skill Workflow

When a task matches an installed skill, use `skill_read` to load its full instructions.
Before installing a skill, always check with `skill_info` first to preview what it does.

### Credential Workflow

Use `get_credential` with the service name to trigger the proper OAuth flow.
Never ask the user to paste tokens manually. Authenticated API calls are proxied through
the frontend which injects credentials on your behalf — the secret value is never sent
to your environment.

### Integration Workflow

1. `integration_list()` — see enabled integrations
2. `integration_search(query: "what you need")` — find operations
3. `integration_skill(integration: slug)` — get detailed usage guide for complex integrations
4. `integration_schema(integration: slug, operation: op)` — check args
5. `integration_execute(integration: slug, operation: op, arguments: {...})` — call with auto-injected auth

For complex integrations (LinkedIn, GitHub, Slack), always load the skill guide first with
`integration_skill` — it contains best practices, example calls, and important constraints.

To connect a new API: `setup_integration(name: "myapi", spec_url: "https://...", auth_type: "bearer")`.
Auth is handled automatically — do NOT call `get_credential` separately.

### External Tools (MCP / Gateway)

Use `search_tools` to discover external tools, `get_tool_schema` to check args,
`use_tool` for one-off calls, `activate_tool` for repeated use. See tool-discovery skill.

### Sub-agents

Delegate parallel tasks with `spawn_sub_agent`. Sub-agents run autonomously and report back.
Use `target_workspace` for cross-workspace tasks, `skill` to load specific skill instructions.
Max 5 concurrent. Poll with `check_sub_agent` or `list_sub_agents`.

### Status Reporting

Call `report_status` at natural checkpoints: when you complete a step, find key results,
hit a blocker, or finish your task. This keeps the user and personal agent informed.
