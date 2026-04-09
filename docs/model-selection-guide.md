# Model Selection Integration Guide

How to use and observe AgentEx's intentional model selection system.

## Overview

AgentEx supports two model selection modes:

- **Manual mode** (default, backward-compatible) — you pick a tier (`:primary`, `:lightweight`) and the router resolves the best healthy route from the catalog.
- **Auto mode** — the router analyses the request for complexity and required capabilities, then selects the best model based on your preference (cost or speed).

## Quick Start

### Manual Mode (Default)

```elixir
AgentEx.run(
  prompt: "Refactor the auth module",
  workspace: "/path/to/project",
  callbacks: %{llm_chat: &my_llm_chat/1},
  model_tier: :primary
)
```

### Auto Mode — Optimize for Price

```elixir
AgentEx.run(
  prompt: "Refactor the auth module",
  workspace: "/path/to/project",
  callbacks: %{llm_chat: &my_llm_chat/1},
  model_selection_mode: :auto,
  model_preference: :optimize_price
)
```

### Auto Mode — Optimize for Speed

```elixir
AgentEx.run(
  prompt: "Refactor the auth module",
  workspace: "/path/to/project",
  callbacks: %{llm_chat: &my_llm_chat/1},
  model_selection_mode: :auto,
  model_preference: :optimize_speed
)
```

## Options

| Option | Values | Default | Description |
|--------|--------|---------|-------------|
| `:model_selection_mode` | `:manual`, `:auto` | `:manual` | How models are chosen |
| `:model_preference` | `:optimize_price`, `:optimize_speed` | `:optimize_price` | Optimization goal (auto mode only) |
| `:model_tier` | `:primary`, `:lightweight`, `:any` | `:primary` | Tier constraint (manual mode only) |

Both options are also accepted by `AgentEx.resume/1`.

## Auto Mode Architecture

```
User Request
     │
     ▼
┌──────────────────────────────────┐
│  Analyzer                        │
│  ├─ LLM-based analysis (fast/   │
│  │  free model classifies the    │
│  │  request)                     │
│  └─ Heuristic fallback (keyword  │
│     matching when no LLM avail)  │
│                                  │
│  Output: complexity,             │
│    required_capabilities,        │
│    needs_vision, needs_reasoning │
└──────────────┬───────────────────┘
               │
               ▼
┌──────────────────────────────────┐
│  Preference Scorer               │
│  Scores each catalog model based │
│  on:                             │
│  ├─ Base cost/speed rating       │
│  ├─ Complexity-tier matching     │
│  ├─ Capability penalties         │
│  └─ Context window requirements  │
└──────────────┬───────────────────┘
               │
               ▼
┌──────────────────────────────────┐
│  Selector                        │
│  Ranks all candidates, returns   │
│  the best match + analysis       │
└──────────────────────────────────┘
```

## Telemetry Events

All telemetry events use the standard `[:agent_ex]` prefix. Attach handlers with `:telemetry.attach/4` or `:telemetry.attach_many/4`.

### Analysis Events

Emitted by `AgentEx.ModelRouter.Analyzer` when classifying a request.

#### `[:agent_ex, :model_router, :analysis, :start]`

Fired before analysis begins.

| Field | Type | Description |
|-------|------|-------------|
| **Measurements** | | |
| (none) | | |
| **Metadata** | | |
| `method` | `:llm` \| `:heuristic` | Which analysis method will be used |
| `session_id` | `string \| nil` | Session that triggered analysis |
| `request_length` | `integer` | Character count of the request |

#### `[:agent_ex, :model_router, :analysis, :stop]`

Fired after analysis completes.

| Field | Type | Description |
|-------|------|-------------|
| **Measurements** | | |
| `duration` | `integer` | Monotonic time elapsed |
| **Metadata** | | |
| `method` | `:llm` \| `:heuristic` | Which method was actually used |
| `session_id` | `string \| nil` | Session |
| `complexity` | `:simple` \| `:moderate` \| `:complex` | Classified complexity |
| `needs_vision` | `boolean` | Whether vision capability is required |
| `needs_audio` | `boolean` | Whether audio capability is required |
| `needs_reasoning` | `boolean` | Whether reasoning capability is required |
| `needs_large_context` | `boolean` | Whether >50k token context is needed |
| `estimated_input_tokens` | `integer` | Rough input token estimate |
| `required_capabilities` | `[atom]` | List of required capability atoms |

#### `[:agent_ex, :model_router, :analysis, :fallback]`

Fired when LLM-based analysis fails and falls back to heuristic.

| Field | Type | Description |
|-------|------|-------------|
| **Measurements** | | |
| (none) | | |
| **Metadata** | | |
| `session_id` | `string \| nil` | Session |
| `from` | `:llm` | Method that failed |
| `to` | `:heuristic` | Fallback method |
| `reason` | `string` | Error description |

#### `[:agent_ex, :model_router, :analysis, :parse_failure]`

Fired when the LLM returns an unparseable analysis response.

### Selection Events

Emitted by `AgentEx.ModelRouter.Selector` when ranking and choosing a model.

#### `[:agent_ex, :model_router, :selection, :start]`

Fired before selection begins.

| Field | Type | Description |
|-------|------|-------------|
| **Measurements** | | |
| (none) | | |
| **Metadata** | | |
| `session_id` | `string \| nil` | Session |
| `preference` | `:optimize_price` \| `:optimize_speed` | User preference |
| `request_length` | `integer` | Character count of the request |

#### `[:agent_ex, :model_router, :selection, :stop]`

Fired after selection completes with full ranking data.

| Field | Type | Description |
|-------|------|-------------|
| **Measurements** | | |
| `duration` | `integer` | Total selection time (includes analysis) |
| `candidate_count` | `integer` | Number of models evaluated |
| `best_score` | `float` | Score of the winning model |
| **Metadata** | | |
| `session_id` | `string \| nil` | Session |
| `preference` | `atom` | User preference used |
| `complexity` | `atom` | Analysis complexity result |
| `selected_provider` | `atom` | Provider of the chosen model |
| `selected_model_id` | `string` | ID of the chosen model |
| `selected_label` | `string` | Human-readable label |
| `needs_vision` | `boolean` | Vision requirement |
| `needs_reasoning` | `boolean` | Reasoning requirement |
| `needs_large_context` | `boolean` | Large context requirement |
| `top3` | `[map]` | Top 3 candidates with scores: `[%{provider, model_id, label, score}]` |
| `error` | `atom` | Present only if selection failed |

### Route Resolution Events

Emitted by `AgentEx.ModelRouter` during route resolution.

#### `[:agent_ex, :model_router, :resolve, :start]`

| Field | Type | Description |
|-------|------|-------------|
| **Metadata** | | |
| `session_id` | `string \| nil` | Session |
| `selection_mode` | `:manual` \| `:auto` | Active selection mode |

#### `[:agent_ex, :model_router, :resolve, :stop]`

| Field | Type | Description |
|-------|------|-------------|
| **Measurements** | | |
| `duration` | `integer` | Resolution time |
| `route_count` | `integer` | Number of routes returned |
| **Metadata** | | |
| `session_id` | `string \| nil` | Session |
| `selection_mode` | `:manual` \| `:auto` | Active mode |
| `selected_provider` | `atom` | (auto) Chosen provider |
| `selected_model_id` | `string` | (auto) Chosen model |
| `complexity` | `atom` | (auto) Analysis complexity |
| `preference` | `atom` | (auto) User preference |
| `tier` | `atom` | (manual) Tier used |
| `error` | `term` | Present only on error |

### LLM Call Integration Events

The existing `[:agent_ex, :llm_call, :start]` and `[:agent_ex, :llm_call, :stop]` events now include `model_selection_mode` in their metadata.

#### `[:agent_ex, :model_router, :auto, :selected]`

Fired by `LLMCall` when auto mode successfully resolves a model. Contains the full analysis alongside the chosen route — the single best event for visualizing model selection decisions.

| Field | Type | Description |
|-------|------|-------------|
| **Measurements** | | |
| (none) | | |
| **Metadata** | | |
| `session_id` | `string` | Session |
| `complexity` | `atom` | Request complexity |
| `needs_vision` | `boolean` | Vision requirement |
| `needs_audio` | `boolean` | Audio requirement |
| `needs_reasoning` | `boolean` | Reasoning requirement |
| `needs_large_context` | `boolean` | Large context requirement |
| `estimated_input_tokens` | `integer` | Token estimate |
| `preference` | `atom` | User preference |
| `selected_model` | `string` | Chosen model ID |
| `selected_provider` | `string` | Chosen provider |

#### `[:agent_ex, :model_router, :auto, :fallback]`

Fired when auto mode fails and falls back to manual tier-based routing.

| Field | Type | Description |
|-------|------|-------------|
| **Metadata** | | |
| `session_id` | `string` | Session |
| `reason` | `string` | Why auto mode failed |

## Listening to Events

### Example: Log All Model Selections

```elixir
:telemetry.attach(
  "model-selection-logger",
  [:agent_ex, :model_router, :auto, :selected],
  fn _event, _measurements, metadata, _config ->
    IO.puts("""
    [Model Selected] #{metadata[:selected_provider]}/#{metadata[:selected_model]}
      Complexity: #{metadata[:complexity]}
      Preference: #{metadata[:preference]}
      Vision: #{metadata[:needs_vision]}
      Reasoning: #{metadata[:needs_reasoning]}
    """)
  end,
  nil
)
```

### Example: Collect Analysis Data for Visualization

```elixir
:telemetry.attach_many(
  "model-analysis-collector",
  [
    [:agent_ex, :model_router, :analysis, :stop],
    [:agent_ex, :model_router, :selection, :stop],
    [:agent_ex, :model_router, :auto, :selected]
  ],
  fn event, measurements, metadata, _config ->
    # Send to your observability backend
    :ok = MyOtelExporter.export_model_decision(event, measurements, metadata)
  end,
  nil
)
```

### Example: Dashboard Query Patterns

For a model selection dashboard, the most useful events are:

| Dashboard Panel | Event | Key Fields |
|----------------|-------|------------|
| Model distribution pie chart | `[:auto, :selected]` | `selected_model`, `selected_provider` |
| Complexity distribution | `[:analysis, :stop]` | `complexity` |
| Cost savings from auto mode | `[:selection, :stop]` | `top3` (compare best vs. would-be-primary) |
| Analysis method breakdown | `[:analysis, :stop]` | `method` |
| Fallback rate | `[:auto, :fallback]` | count / total |
| Analysis latency histogram | `[:analysis, :stop]` | `duration` |
| Selection latency histogram | `[:selection, :stop]` | `duration` |
| Vision/reasoning demand | `[:analysis, :stop]` | `needs_vision`, `needs_reasoning` |

## Programmatic API

### Direct Analysis (No LLM Call)

```elixir
{:ok, analysis} = AgentEx.ModelRouter.Analyzer.analyze_heuristic("Read config.json and fix the bug")
# => %{complexity: :moderate, needs_vision: false, needs_reasoning: false, ...}
```

### Direct Selection

```elixir
{:ok, route, analysis} = AgentEx.ModelRouter.auto_select(
  "Explain quantum computing",
  :optimize_price,
  llm_chat: &my_llm/1,
  context_summary: "User is in a physics tutoring context"
)
# route => %{model_id: "gpt-4o-mini", provider_name: "openai", ...}
# analysis => %{complexity: :moderate, ...}
```

### Ranking Without Selection

```elixir
analysis = %{complexity: :complex, needs_vision: false, needs_reasoning: true, ...}
ranked = AgentEx.ModelRouter.Selector.rank(analysis, :optimize_speed)
# => [{%Model{provider: :anthropic, id: "claude-sonnet-4"}, -1.5}, ...]
```

### Preference Parsing

```elixir
{:ok, pref} = AgentEx.ModelRouter.Preference.parse("price")
# => {:ok, :optimize_price}
```
