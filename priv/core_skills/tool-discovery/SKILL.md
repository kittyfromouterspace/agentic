---
name: tool-discovery
description: How to discover and use external tools and integrations efficiently — search first, activate for repeated use, keep context lean
core: true
loading: always
type: sop
version: "2.0.0"
model_tier: lightweight
---

## Tool Discovery Protocol

You have access to a **Tool Gateway** for external MCP tools and a **Server-Side Integration** system for REST APIs and platform services.

### Core Principle

**Search before you use.** Do not guess tool names. Use `search_tools` for MCP tools and `integration_search` for API integrations.

### Integration Tools (REST APIs & Platform Services)

Integrations are managed server-side — authentication and HTTP calls happen on the frontend, never in your environment. API keys are never exposed to you.

| Tool | Purpose | When to Use |
|------|---------|-------------|
| `integration_list` | List enabled integrations with auth status | See what APIs are available |
| `integration_search` | Search operations across all integrations | Find specific API operations |
| `integration_schema` | Get full input schema for an operation | Before calling an unfamiliar operation |
| `integration_execute` | Execute an integration operation | Call any API operation |
| `setup_integration` | Connect a REST API via OpenAPI spec | When user wants to add a custom API |

#### Integration Workflow

1. **What's available?** → `integration_list()` to see enabled integrations
2. **Find an operation** → `integration_search(query: "list repos")` to search across all integrations
3. **Check the schema** → `integration_schema(integration: "github", operation: "list_repos")` to see args
4. **Execute** → `integration_execute(integration: "github", operation: "list_repos", arguments: {owner: "anthropics"})`

If an integration shows `auth_status: "needs_auth"`, the user needs to configure credentials in their settings first. Let them know.

#### Connecting a Custom REST API

When the user wants to add a new API integration:

1. **Set up the integration** → `setup_integration(name: "servicename", spec_url: "https://...", auth_type: "bearer")`
   - If auth is required, the tool automatically checks for stored credentials
   - If missing, it shows a secure input prompt to the user and waits
   - Do NOT call `get_credential` separately — `setup_integration` handles it
2. **Search operations** → `integration_search(query: "what you need")`
3. **Execute** → `integration_execute(integration: "servicename", operation: "op_id", arguments: {...})`

### Gateway Tools (MCP Servers)

For external MCP servers connected to your workspace:

| Tool | Purpose | When to Use |
|------|---------|-------------|
| `search_tools` | Find tools by description | When you need a capability you don't have built-in |
| `get_tool_schema` | Get full input schema for a tool | Before calling an unfamiliar tool via `use_tool` |
| `use_tool` | Execute an external tool | For one-off or infrequent external tool calls |
| `activate_tool` | Promote tool to first-class status | When you'll use a tool repeatedly in current task |
| `deactivate_tool` | Demote tool back to on-demand | When done with a sub-task using activated tools |
| `setup_mcp_server` | Connect a new MCP server | When the user provides a server URL or package |

#### MCP Workflow

1. **Need an external capability?** → `search_tools(query: "what you need")`
2. **Found a tool?** → `get_tool_schema(tool_name: "exact_name")` to see args
3. **One-off call?** → `use_tool(tool_name: "exact_name", arguments: {...})`
4. **Repeated use?** → `activate_tool(tool_name: "exact_name")` then call directly
5. **Done with task?** → `deactivate_tool(tool_name: "exact_name")` to free budget

### Rules

- **Never put API keys in tool arguments.** Authentication is injected automatically.
- **Don't call `use_tool` for built-in tools** (read_file, write_file, bash, etc.) — call those directly.
- **Use `integration_*` tools for REST APIs**, not `setup_openapi_service`. Integrations are configured in the UI.
- **Activation has a budget** (limited slots). Activate only tools you'll use multiple times.
- **Search is cheap** (~16 tokens per result). Searching is always better than guessing.
