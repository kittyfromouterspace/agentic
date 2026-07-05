defmodule Agentic.LLM.Provider.MoonshotAndKimiCodingTest do
  @moduledoc """
  Contract tests for the two new direct-API Kimi providers.

  These are intentionally network-free: they lock in the provider
  identity, transport, base URL, env vars, mandatory headers, and the
  shape of the static model catalog. A live API call is an integration
  concern (see the z.ai live test for the pattern).
  """

  use ExUnit.Case, async: true

  alias Agentic.LLM.{Credentials, Provider}
  alias Agentic.LLM.Provider.{KimiCoding, Moonshot}

  describe "Moonshot (Kimi direct, OpenAI-compatible)" do
    test "identity and transport" do
      assert Moonshot.id() == :moonshot
      assert Moonshot.label() == "Moonshot AI"
      assert Moonshot.transport() == Agentic.LLM.Transport.OpenAIChatCompletions
    end

    test "default base URL is the global Moonshot endpoint" do
      assert Moonshot.default_base_url() == "https://api.moonshot.ai/v1"
    end

    test "base URL is overridable via MOONSHOT_BASE_URL (China endpoint)" do
      prev = System.get_env("MOONSHOT_BASE_URL")
      System.put_env("MOONSHOT_BASE_URL", "https://api.moonshot.cn/v1")

      try do
        assert Moonshot.default_base_url() == "https://api.moonshot.cn/v1"
      after
        if prev,
          do: System.put_env("MOONSHOT_BASE_URL", prev),
          else: System.delete_env("MOONSHOT_BASE_URL")
      end
    end

    test "env vars and capabilities" do
      assert Moonshot.env_vars() == ["MOONSHOT_API_KEY", "MOONSHOT_KEY"]
      assert :chat in Moonshot.supports()
      assert :tools in Moonshot.supports()
      assert :vision in Moonshot.supports()
    end

    test "catalog seeds the coding models" do
      models = Moonshot.default_models()
      ids = Enum.map(models, & &1.id)

      assert "kimi-k2.7-code" in ids
      assert "kimi-k2.7-code-highspeed" in ids
      assert "kimi-k2.6" in ids
    end

    test "kimi-k2.7-code is marked primary with tools + reasoning" do
      model = Enum.find(Moonshot.default_models(), &(&1.id == "kimi-k2.7-code"))

      assert model.tier_hint == :primary
      assert MapSet.member?(model.capabilities, :tools)
      assert MapSet.member?(model.capabilities, :reasoning)
    end

    test "no extra request headers required" do
      assert Moonshot.request_headers(%Credentials{api_key: "k"}) == []
    end
  end

  describe "KimiCoding (Kimi For Coding, Anthropic-compatible)" do
    test "identity and transport" do
      assert KimiCoding.id() == :kimi_coding
      assert KimiCoding.label() == "Kimi For Coding"
      assert KimiCoding.transport() == Agentic.LLM.Transport.AnthropicMessages
    end

    test "default base URL includes /v1 so the transport appends /messages" do
      base = KimiCoding.default_base_url()
      assert String.ends_with?(base, "/v1")
      assert String.starts_with?(base, "https://api.kimi.com/coding")
    end

    test "base URL is overridable via KIMI_CODING_BASE_URL" do
      prev = System.get_env("KIMI_CODING_BASE_URL")
      System.put_env("KIMI_CODING_BASE_URL", "https://api.kimi.com/coding/v2")

      try do
        assert KimiCoding.default_base_url() == "https://api.kimi.com/coding/v2"
      after
        if prev,
          do: System.put_env("KIMI_CODING_BASE_URL", prev),
          else: System.delete_env("KIMI_CODING_BASE_URL")
      end
    end

    test "auth env var is KIMI_API_KEY" do
      assert KimiCoding.env_vars() == ["KIMI_API_KEY"]
    end

    test "mandatory User-Agent header is attached to every request" do
      headers = KimiCoding.request_headers(%Credentials{api_key: "k"})

      assert {"User-Agent", "KimiCLI/1.5"} in headers
    end

    test "catalog seeds the canonical coding alias" do
      ids = Enum.map(KimiCoding.default_models(), & &1.id)

      assert "kimi-for-coding" in ids
      assert "k2p7" in ids
    end

    test "coding-plan models report zero per-token cost" do
      for model <- KimiCoding.default_models() do
        assert model.cost.input == 0.0
        assert model.cost.output == 0.0
      end
    end
  end

  describe "Provider.chat/3 credential resolution" do
    test "Moonshot reports not_configured without an api key" do
      prev = System.get_env("MOONSHOT_API_KEY")
      System.delete_env("MOONSHOT_API_KEY")
      prev2 = System.get_env("MOONSHOT_KEY")
      System.delete_env("MOONSHOT_KEY")

      try do
        assert match?({:error, _}, Provider.chat(Moonshot, %{"messages" => []}))
      after
        if prev, do: System.put_env("MOONSHOT_API_KEY", prev), else: :ok
        if prev2, do: System.put_env("MOONSHOT_KEY", prev2), else: :ok
      end
    end

    test "KimiCoding reports not_configured without an api key" do
      prev = System.get_env("KIMI_API_KEY")
      System.delete_env("KIMI_API_KEY")

      try do
        assert match?({:error, _}, Provider.chat(KimiCoding, %{"messages" => []}))
      after
        if prev, do: System.put_env("KIMI_API_KEY", prev), else: :ok
      end
    end
  end
end
