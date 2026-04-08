defmodule AgentEx.LLM.Provider.OllamaTest do
  use ExUnit.Case, async: true

  alias AgentEx.LLM.Model
  alias AgentEx.LLM.Provider.Ollama

  describe "metadata" do
    test "id and label" do
      assert Ollama.id() == :ollama
      assert Ollama.label() == "Ollama"
    end

    test "transport is the Ollama transport" do
      assert Ollama.transport() == AgentEx.LLM.Transport.Ollama
    end

    test "supports chat, embeddings, and tools" do
      supports = Ollama.supports()
      assert MapSet.member?(supports, :chat)
      assert MapSet.member?(supports, :embeddings)
      assert MapSet.member?(supports, :tools)
    end

    test "env_vars is OLLAMA_HOST only" do
      assert Ollama.env_vars() == ["OLLAMA_HOST"]
    end

    test "request_headers is empty" do
      assert Ollama.request_headers(%AgentEx.LLM.Credentials{}) == []
    end
  end

  describe "default_models/0" do
    test "includes a chat and an embedding model" do
      models = Ollama.default_models()
      assert length(models) >= 2

      chat = Enum.find(models, &(MapSet.member?(&1.capabilities, :chat) && !MapSet.member?(&1.capabilities, :embeddings)))
      embed = Enum.find(models, &MapSet.member?(&1.capabilities, :embeddings))

      assert %Model{provider: :ollama} = chat
      assert %Model{provider: :ollama} = embed
      assert MapSet.member?(chat.capabilities, :tools)
    end

    test "all default models are tagged :free" do
      for model <- Ollama.default_models() do
        assert MapSet.member?(model.capabilities, :free)
      end
    end
  end

  describe "fetch_catalog/1" do
    test "returns :not_supported when localhost is unreachable" do
      # Localhost on a port nothing is listening on — Req returns :error.
      # Override env to make sure we hit a dead port.
      original = System.get_env("OLLAMA_HOST")
      System.put_env("OLLAMA_HOST", "http://127.0.0.1:1")

      try do
        assert Ollama.fetch_catalog(%AgentEx.LLM.Credentials{}) == :not_supported
      after
        if original, do: System.put_env("OLLAMA_HOST", original), else: System.delete_env("OLLAMA_HOST")
      end
    end
  end
end
