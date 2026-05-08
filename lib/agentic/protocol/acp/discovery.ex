defmodule Agentic.Protocol.ACP.Discovery do
  @moduledoc """
  Auto-discovery of ACP-compatible agents on the system.

  Probes the filesystem for known ACP-capable CLIs and registers
  discovered agents in the protocol registry.

  The known agents database is derived from the acpx project
  (https://github.com/openclaw/acpx) and covers 15+ agents.

  ## Discovery Sources

  1. Built-in known agents database (this module)
  2. `config :agentic, :acp_agents` (user overrides)
  3. `ACP_AGENTS` environment variable (comma-separated)
  4. `:discover_callback` in acp config (programmatic)
  """

  alias Agentic.Protocol.ACP

  require Logger

  @table :agentic_acp_discovery

  @doc "Returns the ETS table name (for testing)."
  def table_name, do: @table

  @type os_directories :: %{
          config: [String.t()],
          logs: [String.t()],
          cache: [String.t()]
        }

  @type agent_entry :: %{
          name: atom(),
          command: String.t(),
          args: [String.t()],
          display: String.t(),
          aliases: [atom()],
          cache_dirs: [String.t()],
          directories: %{
            linux: os_directories(),
            macos: os_directories(),
            windows: os_directories()
          },
          notes: String.t() | nil
        }

  # --- Known Agents Database ---
  # Derived from https://github.com/openclaw/acpx/blob/main/src/agent-registry.ts
  # Each entry maps a normalized name to the shell command used to launch it in ACP mode.

  @known_agents [
    %{
      name: :kimi,
      command: "kimi",
      args: ["acp"],
      display: "Kimi Code",
      aliases: [],
      cache_dirs: [],
      directories: %{
        linux: %{config: ["~/.config/kimi"], logs: ["~/.local/share/kimi/logs"], cache: []},
        macos: %{
          config: ["~/Library/Application Support/Kimi"],
          logs: ["~/Library/Logs/Kimi"],
          cache: ["~/Library/Caches/Kimi"]
        },
        windows: %{
          config: ["#{LOCALAPPDATA}/Kimi"],
          logs: ["#{LOCALAPPDATA}/Kimi/logs"],
          cache: ["#{LOCALAPPDATA}/Kimi/Cache"]
        }
      }
    },
    %{
      name: :claude,
      command: "claude",
      args: ["acp"],
      display: "Claude Code",
      aliases: [:claude_code],
      cache_dirs: ["~/.claude/projects"],
      skill_path: "~/.claude/skills",
      memory_path: "~/.claude/memory",
      memory_file: "~/.claude/memory/MEMORY.md",
      directories: %{
        linux: %{config: ["~/.claude"], logs: ["~/.claude/logs"], cache: ["~/.claude/projects"]},
        macos: %{
          config: ["~/.claude", "~/Library/Application Support/Claude"],
          logs: ["~/Library/Logs/Claude"],
          cache: ["~/Library/Caches/com.anthropic.claude"]
        },
        windows: %{
          config: ["#{LOCALAPPDATA}/AnthropicClaude"],
          logs: ["#{LOCALAPPDATA}/AnthropicClaude/logs"],
          cache: ["#{LOCALAPPDATA}/AnthropicClaude/cache"]
        }
      },
      notes: "Requires @agentclientprotocol/claude-agent-acp package or claude binary"
    },
    %{
      name: :codex,
      command: "codex",
      args: ["acp"],
      display: "Codex CLI",
      aliases: [],
      cache_dirs: ["~/.codex"],
      skill_path: "~/.codex/skills",
      memory_path: "~/.codex/memory",
      directories: %{
        linux: %{config: ["~/.codex"], logs: ["~/.codex/logs"], cache: ["~/.codex/cache"]},
        macos: %{
          config: ["~/.codex"],
          logs: ["~/Library/Logs/Codex"],
          cache: ["~/Library/Caches/Codex"]
        },
        windows: %{
          config: ["#{LOCALAPPDATA}/Codex"],
          logs: ["#{LOCALAPPDATA}/Codex/logs"],
          cache: ["#{LOCALAPPDATA}/Codex/cache"]
        }
      },
      notes: "Or via npx @zed-industries/codex-acp"
    },
    %{
      name: :cursor,
      command: "cursor-agent",
      args: ["acp"],
      display: "Cursor",
      aliases: [],
      cache_dirs: [],
      directories: %{
        linux: %{config: ["~/.cursor"], logs: ["~/.cursor/logs"], cache: []},
        macos: %{
          config: ["~/.cursor", "~/Library/Application Support/Cursor"],
          logs: ["~/Library/Logs/Cursor"],
          cache: []
        },
        windows: %{
          config: ["#{LOCALAPPDATA}/Cursor"],
          logs: ["#{LOCALAPPDATA}/Cursor/logs"],
          cache: []
        }
      }
    },
    %{
      name: :gemini,
      command: "gemini",
      args: ["--acp"],
      display: "Gemini CLI",
      aliases: [],
      cache_dirs: ["~/.gemini"],
      directories: %{
        linux: %{config: ["~/.gemini"], logs: ["~/.gemini/logs"], cache: ["~/.gemini/cache"]},
        macos: %{
          config: ["~/.gemini"],
          logs: ["~/Library/Logs/Gemini"],
          cache: ["~/Library/Caches/Gemini"]
        },
        windows: %{
          config: ["#{LOCALAPPDATA}/Gemini"],
          logs: ["#{LOCALAPPDATA}/Gemini/logs"],
          cache: ["#{LOCALAPPDATA}/Gemini/cache"]
        }
      },
      notes: "Gemini < 0.33.0 needs --experimental-acp"
    },
    %{
      name: :copilot,
      command: "copilot",
      args: ["--acp", "--stdio"],
      display: "GitHub Copilot",
      aliases: [],
      cache_dirs: [],
      directories: %{
        linux: %{config: ["~/.config/github-copilot"], logs: [], cache: []},
        macos: %{config: ["~/.config/github-copilot"], logs: [], cache: []},
        windows: %{config: ["#{LOCALAPPDATA}/GitHub/Copilot"], logs: [], cache: []}
      },
      notes: "Pre-flight --help check for ACP support"
    },
    %{
      name: :opencode,
      command: "opencode",
      args: ["acp"],
      display: "OpenCode",
      aliases: [],
      cache_dirs: ["~/.local/share/opencode"],
      skill_path: "~/.opencode/skills",
      memory_path: "~/.opencode/memory",
      directories: %{
        linux: %{
          config: ["~/.config/opencode"],
          logs: ["~/.local/share/opencode/logs"],
          cache: ["~/.local/share/opencode"]
        },
        macos: %{
          config: ["~/.opencode", "~/Library/Application Support/OpenCode"],
          logs: ["~/Library/Logs/OpenCode"],
          cache: ["~/Library/Caches/OpenCode"]
        },
        windows: %{
          config: ["#{LOCALAPPDATA}/OpenCode"],
          logs: ["#{LOCALAPPDATA}/OpenCode/logs"],
          cache: ["#{LOCALAPPDATA}/OpenCode/cache"]
        }
      },
      notes: "Or via npx -y opencode-ai acp"
    },
    %{
      name: :goose,
      command: "goose",
      args: ["acp"],
      display: "Goose",
      aliases: [],
      cache_dirs: ["~/.config/goose"],
      directories: %{
        linux: %{
          config: ["~/.config/goose"],
          logs: ["~/.config/goose/logs"],
          cache: ["~/.config/goose/cache"]
        },
        macos: %{
          config: ["~/.config/goose", "~/Library/Application Support/Goose"],
          logs: ["~/Library/Logs/Goose"],
          cache: ["~/Library/Caches/Goose"]
        },
        windows: %{
          config: ["#{LOCALAPPDATA}/Goose"],
          logs: ["#{LOCALAPPDATA}/Goose/logs"],
          cache: ["#{LOCALAPPDATA}/Goose/cache"]
        }
      }
    },
    %{
      name: :kiro,
      command: "kiro-cli-chat",
      args: ["acp"],
      display: "Kiro CLI",
      aliases: [],
      cache_dirs: [],
      directories: %{
        linux: %{config: ["~/.config/kiro"], logs: [], cache: []},
        macos: %{config: ["~/Library/Application Support/Kiro"], logs: [], cache: []},
        windows: %{config: ["#{LOCALAPPDATA}/Kiro"], logs: [], cache: []}
      }
    },
    %{
      name: :qwen,
      command: "qwen",
      args: ["--acp"],
      display: "Qwen Code",
      aliases: [],
      cache_dirs: [],
      directories: %{
        linux: %{config: ["~/.config/qwen"], logs: [], cache: []},
        macos: %{config: ["~/Library/Application Support/Qwen"], logs: [], cache: []},
        windows: %{config: ["#{LOCALAPPDATA}/Qwen"], logs: [], cache: []}
      }
    },
    %{
      name: :qoder,
      command: "qodercli",
      args: ["--acp"],
      display: "Qoder CLI",
      aliases: [],
      cache_dirs: [],
      directories: %{
        linux: %{config: ["~/.config/qoder"], logs: [], cache: []},
        macos: %{config: ["~/Library/Application Support/Qoder"], logs: [], cache: []},
        windows: %{config: ["#{LOCALAPPDATA}/Qoder"], logs: [], cache: []}
      },
      notes: "Supports --max-turns and --allowed-tools args"
    },
    %{
      name: :droid,
      command: "droid",
      args: ["exec", "--output-format", "acp"],
      display: "Factory Droid",
      aliases: [:factory_droid, :factorydroid],
      cache_dirs: [],
      directories: %{
        linux: %{config: ["~/.config/droid"], logs: [], cache: []},
        macos: %{config: ["~/Library/Application Support/Droid"], logs: [], cache: []},
        windows: %{config: ["#{LOCALAPPDATA}/Droid"], logs: [], cache: []}
      }
    },
    %{
      name: :openclaw,
      command: "openclaw",
      args: ["acp"],
      display: "OpenClaw",
      aliases: [],
      cache_dirs: [],
      directories: %{
        linux: %{config: ["~/.config/openclaw"], logs: [], cache: []},
        macos: %{config: ["~/Library/Application Support/OpenClaw"], logs: [], cache: []},
        windows: %{config: ["#{LOCALAPPDATA}/OpenClaw"], logs: [], cache: []}
      }
    },
    %{
      name: :pi,
      command: "pi",
      args: ["acp"],
      display: "Pi",
      aliases: [],
      cache_dirs: [],
      directories: %{
        linux: %{config: ["~/.config/pi"], logs: [], cache: []},
        macos: %{config: ["~/Library/Application Support/Pi"], logs: [], cache: []},
        windows: %{config: ["#{LOCALAPPDATA}/Pi"], logs: [], cache: []}
      },
      notes: "Or via npx pi-acp"
    },
    %{
      name: :trae,
      command: "traecli",
      args: ["acp", "serve"],
      display: "Trae",
      aliases: [],
      cache_dirs: [],
      directories: %{
        linux: %{config: ["~/.config/trae"], logs: [], cache: []},
        macos: %{config: ["~/Library/Application Support/Trae"], logs: [], cache: []},
        windows: %{config: ["#{LOCALAPPDATA}/Trae"], logs: [], cache: []}
      }
    },
    %{
      name: :iflow,
      command: "iflow",
      args: ["--experimental-acp"],
      display: "iFlow",
      aliases: [],
      cache_dirs: [],
      directories: %{
        linux: %{config: ["~/.config/iflow"], logs: [], cache: []},
        macos: %{config: ["~/Library/Application Support/iFlow"], logs: [], cache: []},
        windows: %{config: ["#{LOCALAPPDATA}/iFlow"], logs: [], cache: []}
      },
      notes: "Experimental ACP support"
    }
  ]

  # --- Public API ---

  @doc "Initialize the ETS table for discovery cache."
  @spec init() :: :ok
  def init do
    if :ets.whereis(@table) == :undefined do
      :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])
    end

    :ok
  end

  @doc "Return all known agent entries (before probing)."
  @spec known_agents() :: [agent_entry()]
  def known_agents, do: @known_agents

  @doc "Look up an agent in the built-in database by name or alias (no ETS required)."
  @spec lookup_known(atom()) :: agent_entry() | nil
  def lookup_known(name) do
    Enum.find(@known_agents, fn entry ->
      entry.name == name or name in Map.get(entry, :aliases, [])
    end)
  end

  @doc """
  Return the resolved directories for an agent on the current OS.

  Returns a map with `config`, `logs`, and `cache` keys containing
  expanded absolute paths. Returns `nil` if the agent is unknown.
  """
  @spec agent_directories(atom()) :: os_directories() | nil
  def agent_directories(name) do
    case lookup_known(name) do
      nil -> nil
      entry -> resolve_os_directories(entry.directories)
    end
  end

  @doc """
  Discover all available ACP agents on the system.

  Probes each known agent's command for filesystem presence,
  merges with user-configured agents, and caches results.
  """
  @spec discover_all() :: [agent_entry()]
  def discover_all do
    init()

    configured = configured_agents()

    built_in =
      @known_agents
      |> Enum.filter(fn entry -> probe_command(entry.command) end)
      |> Enum.reject(fn entry ->
        Enum.any?(configured, fn c -> c.name == entry.name end)
      end)

    extra =
      Enum.filter(configured, fn entry -> probe_command(entry.command) end)

    discovered = built_in ++ extra

    cache_results(discovered)

    discovered
  end

  @doc "Discover agents and register them in the Protocol.Registry."
  @spec discover_and_register() :: [atom()]
  def discover_and_register do
    discovered = discover_all()

    Enum.each(discovered, fn entry ->
      name = {:acp, entry.name}

      if not registered?(name) do
        try do
          Agentic.Protocol.Registry.register(name, ACP)
          Logger.debug("ACP agent discovered and registered: #{entry.display}")
        rescue
          _ -> :ok
        end
      end

      Enum.each(entry.aliases, fn alias_name ->
        alias_key = {:acp, alias_name}

        if not registered?(alias_key) do
          try do
            Agentic.Protocol.Registry.register(alias_key, ACP)
          rescue
            _ -> :ok
          end
        end
      end)
    end)

    Enum.map(discovered, & &1.name)
  end

  @doc "Check if a specific agent is available."
  @spec available?(atom()) :: boolean()
  def available?(name) do
    case lookup(name) do
      nil -> false
      entry -> probe_command(entry.command)
    end
  end

  @doc "Look up an agent entry by name."
  @spec lookup(atom()) :: agent_entry() | nil
  def lookup(name) do
    case :ets.lookup(@table, {:agent, name}) do
      [{_, entry}] -> entry
      [] -> nil
    end
  end

  @doc "Get the launch command and args for a named agent."
  @spec launch_command(atom()) :: {String.t(), [String.t()]} | nil
  def launch_command(name) do
    case lookup(name) do
      nil -> nil
      entry -> {entry.command, entry.args}
    end
  end

  @doc "Get backend config for a named agent."
  @spec backend_config(atom(), keyword()) :: map()
  def backend_config(name, opts \\ []) do
    case lookup(name) do
      nil ->
        %{}

      entry ->
        %{
          command: entry.command,
          args: entry.args,
          workspace: Keyword.get(opts, :workspace, File.cwd!()),
          permission_policy: Keyword.get(opts, :permission_policy, :ask),
          mcp_servers: Keyword.get(opts, :mcp_servers, []),
          env: Keyword.get(opts, :env, %{})
        }
    end
  end

  @doc "Clear the discovery cache."
  @spec clear_cache() :: :ok
  def clear_cache do
    init()
    :ets.delete_all_objects(@table)
    :ok
  end

  # --- Private ---

  defp probe_command(command) do
    System.find_executable(command) != nil
  end

  defp registered?(name) do
    case Agentic.Protocol.Registry.lookup(name) do
      {:ok, _} -> true
      _ -> false
    end
  rescue
    _ -> false
  end

  @doc "Parse configured agents from app config and ACP_AGENTS env var."
  @spec configured_agents() :: [agent_entry()]
  def configured_agents do
    app_config = Application.get_env(:agentic, :acp_agents, [])

    env_config =
      case System.get_env("ACP_AGENTS") do
        nil ->
          []

        agents_str ->
          agents_str
          |> String.split(",")
          |> Enum.map(&String.trim/1)
          |> Enum.filter(&(&1 != ""))
          |> Enum.map(fn agent_str ->
            [name | rest] = String.split(agent_str, ~r/\s+/, parts: 2)

            %{
              name: String.to_atom(name),
              command: name,
              args: if(rest == [], do: ["acp"], else: String.split(hd(rest), ~r/\s+/)),
              display: name,
              aliases: [],
              cache_dirs: [],
              directories: %{
                linux: %{config: [], logs: [], cache: []},
                macos: %{config: [], logs: [], cache: []},
                windows: %{config: [], logs: [], cache: []}
              }
            }
          end)
      end

    (app_config ++ env_config)
    |> Enum.map(fn
      entry when is_map(entry) ->
        dirs =
          entry[:directories] || entry["directories"] ||
            %{
              linux: %{config: [], logs: [], cache: []},
              macos: %{config: [], logs: [], cache: []},
              windows: %{config: [], logs: [], cache: []}
            }

        %{
          name: entry[:name] || entry["name"] || :unknown,
          command: entry[:command] || entry["command"] || "unknown",
          args: entry[:args] || entry["args"] || ["acp"],
          display:
            entry[:display] || entry["display"] || to_string(entry[:name] || entry["name"]),
          aliases: entry[:aliases] || entry["aliases"] || [],
          cache_dirs: entry[:cache_dirs] || entry["cache_dirs"] || [],
          directories: dirs
        }

      _ ->
        nil
    end)
    |> Enum.reject(&is_nil/1)
  end

  defp cache_results(entries) do
    Enum.each(entries, fn entry ->
      :ets.insert(@table, {{:agent, entry.name}, entry})

      Enum.each(entry.aliases, fn alias_name ->
        :ets.insert(@table, {{:agent, alias_name}, entry})
      end)
    end)
  end

  @spec resolve_os_directories(%{
          linux: os_directories(),
          macos: os_directories(),
          windows: os_directories()
        }) :: os_directories()
  defp resolve_os_directories(directories) do
    os_key =
      case :os.type() do
        {:unix, :darwin} -> :macos
        {:win32, _} -> :windows
        {:unix, _} -> :linux
      end

    dirs = Map.get(directories, os_key, %{config: [], logs: [], cache: []})

    Map.new(dirs, fn {kind, paths} ->
      {kind, Enum.flat_map(paths, &expand_env_vars/1)}
    end)
  end

  defp expand_env_vars(<<?#, ?{, rest::binary>>) do
    case String.split(rest, "}", parts: 2) do
      [var, suffix] ->
        value = System.get_env(var) || ""
        expanded = value <> suffix
        if expanded == "", do: [], else: [expanded]

      _ ->
        []
    end
  end

  defp expand_env_vars(path) do
    expanded = Path.expand(path)
    if expanded == "", do: [], else: [expanded]
  end
end
