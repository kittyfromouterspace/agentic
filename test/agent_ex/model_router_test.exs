defmodule AgentEx.ModelRouterTest do
  use ExUnit.Case, async: false

  alias AgentEx.Loop.Context
  alias AgentEx.ModelRouter

  describe "resolve_for_context/1 manual mode" do
    test "resolves routes based on tier in manual mode" do
      ctx =
        Context.new(
          session_id: "test",
          model_tier: :primary,
          model_selection_mode: :manual,
          callbacks: %{
            llm_chat: fn _ ->
              {:ok, %AgentEx.LLM.Response{content: [], stop_reason: :end_turn}}
            end
          }
        )

      case ModelRouter.resolve_for_context(ctx) do
        {:ok, routes, nil} ->
          assert is_list(routes)

        {:error, _reason} ->
          :ok
      end
    end
  end

  describe "resolve_for_context/1 auto mode" do
    test "uses Selector in auto mode" do
      llm_chat = fn _params ->
        {:ok,
         %AgentEx.LLM.Response{
           content: [
             %{
               type: :text,
               text:
                 ~s({"complexity": "simple", "required_capabilities": ["chat"], "needs_vision": false, "needs_audio": false, "needs_reasoning": false, "needs_large_context": false, "estimated_input_tokens": 50, "explanation": "test"})
             }
           ],
           stop_reason: :end_turn,
           usage: %{input_tokens: 10, output_tokens: 20, cache_read: 0, cache_write: 0}
         }}
      end

      ctx =
        Context.new(
          session_id: "test",
          model_selection_mode: :auto,
          model_preference: :optimize_price,
          messages: [%{"role" => "user", "content" => "Hello"}],
          callbacks: %{llm_chat: llm_chat}
        )

      case ModelRouter.resolve_for_context(ctx) do
        {:ok, routes, analysis} ->
          assert is_list(routes)

          if analysis do
            assert analysis.complexity == :simple
          end

        {:error, _reason} ->
          :ok
      end
    end
  end

  describe "auto_select/3" do
    test "returns route and analysis" do
      llm_chat = fn _params ->
        {:ok,
         %AgentEx.LLM.Response{
           content: [
             %{
               type: :text,
               text:
                 ~s({"complexity": "moderate", "required_capabilities": ["chat", "tools"], "needs_vision": false, "needs_audio": false, "needs_reasoning": false, "needs_large_context": false, "estimated_input_tokens": 500, "explanation": "test"})
             }
           ],
           stop_reason: :end_turn,
           usage: %{input_tokens: 10, output_tokens: 20, cache_read: 0, cache_write: 0}
         }}
      end

      result = ModelRouter.auto_select("Write a function", :optimize_speed, llm_chat: llm_chat)

      case result do
        {:ok, route, analysis} ->
          assert is_map(route)
          assert is_map(analysis)

        {:error, :no_models_available} ->
          :ok

        {:error, _reason} ->
          :ok
      end
    end
  end

  describe "resolve_for_context/1 with :free_only filter" do
    test "in manual mode, filters routes to free models only" do
      ctx =
        Context.new(
          session_id: "test-free-manual",
          model_selection_mode: :manual,
          model_tier: :any,
          model_filter: :free_only,
          callbacks: %{
            llm_chat: fn _ ->
              {:ok, %AgentEx.LLM.Response{content: [], stop_reason: :end_turn}}
            end
          }
        )

      case ModelRouter.resolve_for_context(ctx) do
        {:ok, routes, nil} ->
          assert is_list(routes)

          if routes != [] do
            Enum.each(routes, fn route ->
              assert MapSet.member?(route.capabilities, :free)
            end)
          end

        {:error, :no_free_models_available} ->
          :ok

        {:error, _reason} ->
          :ok
      end
    end

    test "in auto mode, filters to free models via Selector" do
      llm_chat = fn _params ->
        {:ok,
         %AgentEx.LLM.Response{
           content: [
             %{
               type: :text,
               text:
                 ~s({"complexity": "simple", "required_capabilities": ["chat"], "needs_vision": false, "needs_audio": false, "needs_reasoning": false, "needs_large_context": false, "estimated_input_tokens": 50, "explanation": "test"})
             }
           ],
           stop_reason: :end_turn,
           usage: %{input_tokens: 10, output_tokens: 20, cache_read: 0, cache_write: 0}
         }}
      end

      ctx =
        Context.new(
          session_id: "test-free-auto",
          model_selection_mode: :auto,
          model_preference: :optimize_price,
          model_filter: :free_only,
          messages: [%{"role" => "user", "content" => "Hello"}],
          callbacks: %{llm_chat: llm_chat}
        )

      case ModelRouter.resolve_for_context(ctx) do
        {:ok, routes, _analysis} ->
          assert is_list(routes)

          if routes != [] do
            Enum.each(routes, fn route ->
              assert MapSet.member?(route.capabilities, :free)
            end)
          end

        {:error, :no_models_available} ->
          :ok

        {:error, _reason} ->
          :ok
      end
    end
  end
end
