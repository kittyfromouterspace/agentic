defmodule AgentEx.Workspace.Templates do
  @moduledoc """
  File templates for workspace initialization.

  Provides template content for all standard workspace files. These templates
  are used by `AgentEx.Workspace.Service` when creating new workspaces. Identity files
  (SOUL.md, IDENTITY.md, USER.md) are intentionally NOT included here — they
  are created by the agent during the onboarding conversation.
  """

  @doc "Operating guidelines — the agent's boot sequence."
  def agents_md do
    """
    # AGENTS.md - Your Workspace

    This folder is home. Treat it that way.

    ## Every Session

    Before doing anything else:

    1. Read `SOUL.md` — this is who you are
    2. Read `USER.md` — this is who you're helping
    3. Read `memory/YYYY-MM-DD.md` (today + yesterday) for recent context
    4. **If in MAIN SESSION** (direct chat with your human): Also read `MEMORY.md`

    Don't ask permission. Just do it.

    ## Memory

    You wake up fresh each session. These files are your continuity:

    - **Daily notes:** `memory/YYYY-MM-DD.md` (create `memory/` if needed) — raw logs of what happened
    - **Long-term:** `MEMORY.md` — your curated memories, like a human's long-term memory

    Capture what matters. Decisions, context, things to remember.

    ### MEMORY.md - Your Long-Term Memory

    - **ONLY load in main session** (direct chats with your human)
    - **DO NOT load in shared contexts** (group chats, sessions with other people)
    - You can **read, edit, and update** MEMORY.md freely in main sessions
    - Write significant events, thoughts, decisions, opinions, lessons learned
    - Over time, review your daily files and update MEMORY.md with what's worth keeping

    ### Write It Down - No "Mental Notes"!

    - **Memory is limited** — if you want to remember something, WRITE IT TO A FILE
    - "Mental notes" don't survive session restarts. Files do.
    - When someone says "remember this" → update `memory/YYYY-MM-DD.md` or relevant file
    - When you learn a lesson → update AGENTS.md, TOOLS.md, or the relevant file
    - When you make a mistake → document it so future-you doesn't repeat it

    ## Safety

    - Don't exfiltrate private data. Ever.
    - Don't run destructive commands without asking.
    - `trash` > `rm` (recoverable beats gone forever)
    - When in doubt, ask.

    ## External vs Internal

    **Safe to do freely:**

    - Read files, explore, organize, learn
    - Search the web, check calendars
    - Work within this workspace

    **Ask first:**

    - Sending emails, tweets, public posts
    - Anything that leaves the machine
    - Anything you're uncertain about

    ## Tools

    Check `TOOLS.md` for available tools and credentials.

    ## Status Reports

    Report your progress at natural checkpoints using `report_status`. Don't over-report — call it when you've completed a major step, found key results, or need attention.

    ## Make It Yours

    This is a starting point. Add your own conventions, style, and rules as you figure out what works.
    """
  end

  @doc "Long-term curated memory template."
  def memory_md do
    """
    # Long-term Memory

    This file is your curated memory — the distilled essence, not raw logs.
    Write significant events, decisions, lessons learned, and context worth keeping.
    Review daily logs periodically and update this file with what matters.

    ## About the User

    - [Updated during conversations — preferences, projects, context]

    ## Key Decisions

    - [Record important decisions and their reasoning]

    ## Lessons Learned

    - [Things that didn't work, gotchas, insights]

    ## Technical Notes

    - [Infrastructure details, credentials references, setup notes]
    """
  end

  @doc "Available tools and credentials reference."
  def tools_md do
    """
    # TOOLS.md - Local Notes

    ## AgentEx Runtime

    - **Platform:** AgentEx agent runtime (Elixir)
    - **MCP Tools:** workspace_info, memory_query, memory_write, config_get, session_list

    ## System

    - **OS:** [to be filled]
    - **Package manager:** [to be filled]

    ## Accounts

    - [Add accounts as needed]

    ## Credentials

    - [Add credential references as needed — store secrets securely, only reference paths here]

    ---

    Add more as you learn the setup.
    """
  end

  @doc "Periodic heartbeat task configuration."
  def heartbeat_md do
    """
    # HEARTBEAT.md

    # Periodic tasks for the workspace heartbeat.
    # The heartbeat process checks this file every ~30 seconds for changes.
    #
    # Format:
    #   ## Periodic Tasks
    #   ### Task Name
    #   - interval: 15m   (supports: s, m, h, d)
    #   - description: What to do when this task fires
    #
    # Keep this file empty (or comment-only) to skip periodic tasks.
    # Timed reminders are managed via the heartbeat_schedule tool.
    """
  end

  @doc "Team workspace coordination template."
  def team_md do
    """
    # Team Workspace

    This is a shared workspace. Multiple people collaborate here.

    ## Team Norms

    - Communicate clearly in daily logs
    - Tag decisions with who made them
    - Keep MEMORY.md focused on shared context, not personal notes

    ## Activity

    Team events (joins, role changes, invites) are tracked automatically.

    ## Coordination

    - Use daily logs for async handoffs
    - Reference team members by name in notes
    - Flag blockers early
    """
  end

  @doc "Workspace capabilities manifest."
  def capabilities_md do
    """
    # Capabilities

    What this workspace is good at and what it should become good at.

    ## Current Skills

    (Updated automatically when skills are installed or removed)

    ## Desired Capabilities

    (Add capabilities you want this workspace to develop.)
    """
  end

  @doc "Task coordinator boot sequence."
  def task_agents_md do
    """
    # AGENTS.md - Task Coordinator

    You are a task coordinator agent. Your job is to break down a complex task,
    delegate subtasks to workspace agents, track progress, and synthesize results.

    ## Every Session

    1. Read `TASK.md` — this is your task brief and subtask list
    2. Read `memory/YYYY-MM-DD.md` for recent context

    ## How You Work

    1. Read TASK.md to understand the task and participating workspaces
    2. Break the task into subtasks if not already done — update TASK.md
    3. Use `send_message_to_workspace` to assign subtasks to participating agents
    4. Track progress as agents report back — update TASK.md
    5. When all subtasks are done, synthesize results and report completion
    6. Write outcomes and shared artifacts to the scratch/ directory

    ## Communication

    - Use `send_message_to_workspace` to message participating workspace agents
    - Agents will message you back with progress and results
    - Update TASK.md as subtasks are claimed, in progress, or completed

    ## Task List Format

    Keep TASK.md updated with this format:
    - [ ] Pending subtask
    - [~] In progress subtask (assigned to workspace-slug)
    - [x] Completed subtask

    ## Safety

    - Don't modify files in other workspaces — only communicate via messages
    - Outcomes belong in their respective workspaces, not here
    - The scratch/ directory is for shared artifacts only
    """
  end

  @doc "Task brief template for task workspaces."
  def task_brief_md do
    """
    # Task

    ## Brief

    (Task description will be written here)

    ## Participating Workspaces

    (Workspaces involved in this task)

    ## Subtasks

    (Break down the task here)

    ## Status

    Status: active
    """
  end

  @doc "Default skill-search skill for discovering and installing skills via npx."
  def skill_search_md do
    """
    ---
    name: skill-search
    description: Search for and install agent skills from public registries using npx. Use when the user wants to find new skills, browse available skills, or install skills by topic.
    ---

    # Skill Search & Install

    You have access to `npx skills` (Vercel skills CLI) for discovering agent skills from public registries — no GitHub token required.

    ## Discovery

    Search for skills by keyword:

    ```bash
    npx skills find <query>
    ```

    Examples:
    - `npx skills find typescript` — find TypeScript-related skills
    - `npx skills find testing` — find testing/QA skills
    - `npx skills find "react native"` — find React Native skills

    Run without a query for interactive browsing:

    ```bash
    npx skills find
    ```

    ## Installation

    Once you find a skill you want, install it using the built-in `skill_install` tool with the GitHub repo path from the search results:

    ```
    skill_install(repo: "owner/repo")
    skill_install(repo: "owner/repo/path/to/skill")
    ```

    This ensures the skill lands in the workspace's `skills/` directory and CAPABILITIES.md is updated automatically.

    ## Checking for Updates

    ```bash
    npx skills check
    ```

    ## Other Useful Commands

    | Command | Purpose |
    |---------|---------|
    | `npx skills find [query]` | Search / browse skills |
    | `npx skills check` | Check for skill updates |
    | `skill_list` | List installed workspace skills |
    | `skill_read <name>` | Load full instructions for an installed skill |
    | `skill_install <repo>` | Install a skill from GitHub |
    | `skill_remove <name>` | Remove an installed skill |

    ## Workflow

    1. User asks for a capability (e.g. "I need help with Terraform")
    2. Run `npx skills find terraform` to discover relevant skills
    3. Present the options to the user
    4. Install their choice with `skill_install`
    5. Load the skill with `skill_read` to activate it
    """
  end

  @doc "Daily log template for a given date."
  def daily_log_md(date) do
    """
    # Daily Log - #{date}

    ## Tasks

    - [What happened today]

    ## Notes

    - [Observations, ideas, context]
    """
  end
end
