Analyze the following user request and return a JSON object describing its requirements.

Evaluate the request for:
1. **complexity** — how demanding the reasoning/generation task is
2. **required_capabilities** — which model features are needed
3. **estimated_input_tokens** — rough token count of the request context

Return ONLY valid JSON with this schema:
```json
{
  "complexity": "simple | moderate | complex",
  "required_capabilities": ["chat", "tools"],
  "needs_vision": false,
  "needs_audio": false,
  "needs_reasoning": false,
  "needs_large_context": false,
  "estimated_input_tokens": 500,
  "explanation": "Brief explanation of the classification"
}
```

## Classification Guide

- **simple**: Short factual questions, basic formatting, simple lookups, greetings
- **moderate**: Multi-step tasks, moderate-length generation, single-file edits, analysis requiring some reasoning
- **complex**: Multi-file refactors, architectural decisions, long-form generation, deep analysis, tasks requiring sustained reasoning chains

- **needs_vision**: true if request references images, screenshots, diagrams, or visual content
- **needs_audio**: true if request references audio, speech, or sound content
- **needs_reasoning**: true if request requires complex logic, math, or multi-step deduction
- **needs_large_context**: true if request likely needs >50k tokens of context (e.g., analyzing many files)

## User Request

{request}

## Available Context

{context_summary}
