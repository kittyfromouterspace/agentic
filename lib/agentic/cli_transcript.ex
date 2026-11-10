defmodule Agentic.CLI.Transcript do
  @moduledoc """
  Protocol-aware summarizer for CLI event streams.

  The CLIs emit machine envelopes — opencode `--format json` events
  (`step_start` / `text` / `tool` / `step_finish` / `error`) and claude
  stream-json records (`system` / `assistant` / `user` / `result` / `error`,
  plus chatty `stream_event` deltas). Tailing those raw turns a "console"
  into a JSON wall that hides what the agent is actually doing.

  `summarize_line/2` turns one raw line into a small neutral summary that
  UI layers render as a human transcript row:

      {:text, "helo world"}                     — agent said something
      {:tool, "write — blog/test.exs"}          — tool call (name + hint)
      {:step_start, ""}                         — a turn began
      {:step_finish, "turn done · reason stop"} — a turn ended
      {:error, "provider.quota — no funds"}     — failure
      {:system, "session started"}              — lifecycle line
      {:user, "use port 4000"}                  — injected stdin turn
      :skip                                     — drop (delta noise)
      :raw                                      — not an envelope; render raw

  Everything is defensive: undecodable lines come back as `:raw`, unknown
  envelope types as `:raw`, missing fields are elided from the text.
  """

  @type summary ::
          {:text, String.t()}
          | {:tool, String.t()}
          | {:step_start, String.t()}
          | {:step_finish, String.t()}
          | {:error, String.t()}
          | {:system, String.t()}
          | {:user, String.t()}
          | :skip
          | :raw

  @spec summarize_line(atom(), binary() | String.t()) :: summary()
  def summarize_line(:opencode, line), do: summarize_opencode(line)
  def summarize_line(:claude_code, line), do: summarize_claude(line)
  def summarize_line(_kind, _line), do: :raw

  # ── opencode (--format json) ────────────────────────────────────────────

  defp summarize_opencode(line) do
    case decode(line) do
      {:ok, d} ->
        part = d["part"] || %{}

        case d["type"] do
          "step_start" ->
            {:step_start, ""}

          "text" ->
            {:text, to_text(part["text"])}

          # tool calls arrive as top-level "tool_use" (part.type "tool")
          "tool_use" ->
            {:tool, opencode_tool_text(part)}

          "tool" ->
            {:tool, opencode_tool_text(part)}

          "step_finish" ->
            {:step_finish, opencode_finish_text(part)}

          "error" ->
            {:error, error_text(d["error"])}

          _other ->
            :raw
        end

      _ ->
        :raw
    end
  end

  defp opencode_tool_text(part) do
    name = to_text(part["tool"])
    state = part["state"] || %{}
    input = state["input"] || %{}
    title = to_text(state["title"])
    status = to_text(state["status"])

    hint =
      input
      |> Enum.take(1)
      |> Enum.map_join(", ", fn {k, v} -> "#{k}: #{short_value(v)}" end)

    # opencode's state.title often echoes the tool name — keep it only when
    # it adds information.
    title = if title == name, do: "", else: title

    [name, hint, title, status]
    |> Enum.reject(&(&1 == ""))
    |> Enum.join(" — ")
  end

  defp opencode_finish_text(part) do
    reason = to_text(part["reason"])
    cost = part["cost"]
    tokens = (part["tokens"] || %{}) |> map_size()

    base =
      case reason do
        "" -> "turn done"
        reason -> "turn done · reason #{reason}"
      end

    base =
      if is_number(cost) and cost > 0,
        do: base <> " · cost $#{:erlang.float_to_binary(cost * 1.0, decimals: 4)}",
        else: base

    if tokens > 0, do: base <> " · usage reported", else: base
  end

  # ── claude (stream-json) ────────────────────────────────────────────────

  defp summarize_claude(line) do
    case decode(line) do
      {:ok, d} ->
        case d["type"] do
          "system" ->
            model = to_text(d["model"])

            text =
              case model do
                "" -> "session started"
                model -> "session started · model #{model}"
              end

            {:system, text}

          "assistant" ->
            assistant_summary(get_in(d, ["message", "content"]))

          "user" ->
            {:user, claude_user_text(get_in(d, ["message", "content"]))}

          "result" ->
            {:step_finish, claude_result_text(d)}

          "error" ->
            {:error, error_text(d["error"])}

          "stream_event" ->
            # token deltas — far too chatty for a transcript; the full
            # assistant envelope lands right after the stream ends anyway.
            :skip

          _other ->
            :raw
        end

      _ ->
        :raw
    end
  end

  defp assistant_summary(content) when is_list(content) do
    tool_uses = Enum.filter(content, &(&1["type"] == "tool_use"))
    texts = Enum.filter(content, &(&1["type"] == "text"))

    cond do
      tool_uses != [] ->
        {:tool, claude_tool_text(List.first(tool_uses) |> merge_tool_uses(tool_uses))}

      texts != [] ->
        {:text, texts |> Enum.map(&to_text(&1["text"])) |> Enum.join("\n") |> trim_text()}

      true ->
        :skip
    end
  end

  defp assistant_summary(_other), do: :raw

  defp merge_tool_uses(first, all) do
    if length(all) > 1 do
      names = Enum.map(all, &to_text(&1["name"]))
      Map.put(first, "name", Enum.join(names, " + "))
    else
      first
    end
  end

  defp claude_tool_text(tool) do
    name = to_text(tool["name"])
    input = tool["input"] || %{}

    hint =
      input
      |> Enum.take(1)
      |> Enum.map_join(", ", fn {k, v} -> "#{k}: #{short_value(v)}" end)

    case hint do
      "" -> name
      hint -> name <> " — " <> hint
    end
  end

  defp short_value(v) when is_binary(v), do: v |> String.slice(0, 60) |> trim_text()
  defp short_value(v), do: inspect(v, limit: 2) |> String.slice(0, 60)

  defp claude_user_text(content) when is_binary(content), do: trim_text(content)

  defp claude_user_text(content) when is_list(content) do
    content
    |> Enum.filter(&(&1["type"] == "text"))
    |> Enum.map(&to_text(&1["text"]))
    |> Enum.join(" ")
    |> trim_text()
  end

  defp claude_user_text(_other), do: ""

  defp claude_result_text(d) do
    turns = d["num_turns"]
    is_error = d["is_error"] == true

    base =
      if is_error do
        "turn ended with error"
      else
        "turn done"
      end

    base =
      case turns do
        n when is_integer(n) -> base <> " · #{n} turn(s)"
        _ -> base
      end

    case d["usage"] do
      %{"total_cost_usd" => cost} when is_number(cost) and cost > 0 ->
        base <> " · cost $#{:erlang.float_to_binary(cost * 1.0, decimals: 4)}"

      _ ->
        base
    end
  end

  # ── Shared helpers ──────────────────────────────────────────────────────

  defp error_text(err) when is_map(err) do
    type = to_text(err["type"])
    message = to_text(err["message"])

    [type, message]
    |> Enum.reject(&(&1 == ""))
    |> Enum.join(" — ")
  end

  defp error_text(err), do: to_text(err)

  defp to_text(nil), do: ""
  defp to_text(v) when is_binary(v), do: String.trim(v)
  defp to_text(v), do: String.trim(Kernel.inspect(v, limit: 3))

  defp trim_text(text) do
    text = String.trim(text)
    if String.length(text) > 600, do: String.slice(text, 0, 600) <> "…", else: text
  end

  defp decode(line) do
    case String.trim(line) do
      "" -> :error
      trimmed -> Jason.decode(trimmed)
    end
  end
end
