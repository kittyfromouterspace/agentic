# Implementation Progress

> Tracks multi-mode loop implementation. See [decisions.md](./decisions.md) for design decisions log.

## Status: V2.1 COMPLETE (266 tests, 0 failures)

- [ ] Not started
- [~] In progress
- [x] Complete
- [-] Skipped / deferred

---

## V1.0 — COMPLETE

### Phase 1: Core Infrastructure
- [x] Phase state machine (`lib/agent_ex/loop/phase.ex`)
- [x] Context fields (`lib/agent_ex/loop/context.ex`)
- [x] ModeRouter (`lib/agent_ex/loop/stages/mode_router.ex`)
- [x] PlanBuilder (`lib/agent_ex/loop/stages/plan_builder.ex`)
- [x] PlanTracker (`lib/agent_ex/loop/stages/plan_tracker.ex`)
- [x] HumanCheckpoint (`lib/agent_ex/loop/stages/human_checkpoint.ex`)
- [x] VerifyPhase (`lib/agent_ex/loop/stages/verify_phase.ex`)
- [x] WorkspaceSnapshot (`lib/agent_ex/loop/stages/workspace_snapshot.ex`)

### Phase 2: Profile & Entry Point
- [x] Profile updates (4 profiles)
- [x] Entry point updates (`run/1`, `resume/1`)

### Phase 3: Persistence
- [x] Transcript behaviour + local backend
- [x] Plan behaviour + local backend
- [x] Knowledge behaviour + local backend
- [x] Storage.Backend behaviour

### Phase 4: Cleanup
- [x] Delete StopReasonRouter
- [x] Test helper additions

---

## V1.1 — COMPLETE

### Deferred V1.0 Tests
- [x] PlanBuilder unit tests (7 tests)
- [x] PlanTracker unit tests (14 tests)
- [x] HumanCheckpoint unit tests (11 tests)
- [x] VerifyPhase unit tests (7 tests)
- [x] WorkspaceSnapshot unit tests (7 tests)
- [x] Persistence backend tests (24 tests)
- [x] agentic_planned integration test (8 tests)
- [x] turn_by_turn integration test (12 tests)

### V1.1 Enhancements
- [x] Per-tool output clipping in ToolExecutor (`read_file` → 50KB, `bash` → 1MB, `list_files` → 10KB)
- [x] File-read deduplication tracking in ToolExecutor (`ctx.file_reads`)
- [x] ContinuationDetector port from Homunculus (20 tests)
- [x] ContextCompression two-tier truncate/summarize port from Homunculus (8 tests)
- [x] LLMSemaphore bounded concurrency port from SCE (7 tests)
- [-] Mneme Knowledge backend (deferred — requires Mneme DB)

---

## V1.2 — COMPLETE

- [x] LLMCall restructured with stable/volatile message separation
- [x] `cache_control` param with `stable_hash` and `prefix_changed` sent to `llm_chat`
- [x] `stable_prefix_hash` context field (tracks when prefix changes)
- [x] Hash computed from system prompt + tool definitions
- [x] Cache awareness tests (6 tests)

---

## V1.3 — COMPLETE

- [x] TranscriptRecorder stage (`lib/agent_ex/loop/stages/transcript_recorder.ex`)
- [x] Records `llm_response` and `tool_call` events via transcript backend
- [x] No-op when no `transcript_backend` callback configured
- [x] Added to all 4 profiles (after ModeRouter)
- [x] `AgentEx.resume/1` with transcript reconstruction
- [x] Rebuilds messages, turns_used, cost, tokens, plan from JSONL events
- [x] TranscriptRecorder tests (5 tests)
- [x] Resume tests (3 tests)

---

## V2.0 — COMPLETE

- [x] Context fields: `subagent_depth`, `subagent_budget`, `parent_session_id`
- [x] `AgentEx.Subagent.Coordinator` GenServer (per-workspace, Registry-backed)
- [x] `AgentEx.Subagent.CoordinatorSupervisor` (DynamicSupervisor, lazy start)
- [x] `AgentEx.Subagent.DelegateTask` tool definition + execution
- [x] `delegate_task` tool wired into `Tools.definitions/0` and `Tools.execute/3`
- [x] Max concurrent subagents: 5 per workspace
- [x] Max subagent nesting depth: 3
- [x] Default max_turns per subagent: 20 (configurable, max 50)
- [x] Application starts Subagent Registry + CoordinatorSupervisor
- [x] Coordinator tests (3 tests)
- [x] DelegateTask tests (5 tests)

---

## V2.1 — COMPLETE

- [x] `tool_permissions` context field (`%{tool_name => :auto | :approve | :deny}`)
- [x] `:on_tool_approval` callback (`(name, input, ctx) -> :approved | :denied | {:approved_with_changes, new_input}`)
- [x] Permission check in ToolExecutor before circuit breaker
- [x] Wired `tool_permissions` option in `AgentEx.run/1`
- [x] Tool permission tests (8 tests)

---

## Future

- Mneme Knowledge backend (deferred — requires Mneme DB)
- Async subagent execution (V3.0)
- Mode switching mid-run
- Per-tool approval gating with runtime approval flow for `:turn_by_turn`
