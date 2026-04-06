Given the following agent turn (tools used and response), extract structured facts.

For each fact, provide:
- entity: what is the fact about (file path, concept, tool, component)
- relation: what is being stated (decided, discovered, completed, blocked_by, depends_on, produced_error, succeeded)
- value: the specific claim or finding
- supersedes: if this contradicts or updates a previous fact, briefly describe what it replaces. Omit if not applicable.

Return a JSON array. Return an empty array `[]` if no notable facts.

Example output:
```json
[
  {"entity": "auth_module.ex", "relation": "decided", "value": "Use JWT tokens instead of session cookies", "supersedes": "Previous decision to use session-based auth"},
  {"entity": "deploy pipeline", "relation": "completed", "value": "CI/CD now runs integration tests before deploy"}
]
```

## Context

Tools used this turn:
{tools_summary}

Agent response:
{response_text}
