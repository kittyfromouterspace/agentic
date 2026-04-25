defmodule Agentic.LLM.Provider.OpenRouterTest do
  use ExUnit.Case, async: true

  alias Agentic.LLM.Provider.OpenRouter

  defp raw(overrides) do
    base = %{
      "id" => "test/model",
      "name" => "Test Model",
      "context_length" => 128_000,
      "pricing" => %{"prompt" => "0.000001", "completion" => "0.000002"},
      "supported_parameters" => ["tools"],
      "architecture" => %{
        "input_modalities" => ["text"],
        "output_modalities" => ["text"]
      },
      "top_provider" => %{"max_completion_tokens" => 8192}
    }

    deep_merge(base, overrides)
  end

  defp deep_merge(left, right) do
    Map.merge(left, right, fn
      _k, l, r when is_map(l) and is_map(r) -> deep_merge(l, r)
      _k, _l, r -> r
    end)
  end

  describe "parse_model/1 — conversational models" do
    test "tags a chat+tools text model with :chat and :tools and :primary tier" do
      m = OpenRouter.__parse_model__(raw(%{}))

      assert MapSet.member?(m.capabilities, :chat)
      assert MapSet.member?(m.capabilities, :tools)
      assert m.tier_hint == :primary
    end

    test "demotes mid-context conversational models to :lightweight" do
      m = OpenRouter.__parse_model__(raw(%{"context_length" => 16_000}))

      assert m.tier_hint == :lightweight
      assert MapSet.member?(m.capabilities, :chat)
      assert MapSet.member?(m.capabilities, :tools)
    end

    test "vision-augmented chat (text+image in, text out) keeps :chat and adds :vision" do
      m =
        OpenRouter.__parse_model__(
          raw(%{
            "architecture" => %{
              "input_modalities" => ["text", "image"],
              "output_modalities" => ["text"]
            }
          })
        )

      assert MapSet.member?(m.capabilities, :chat)
      assert MapSet.member?(m.capabilities, :vision)
      assert m.tier_hint == :primary
    end

    test "free conversational models still earn a tier hint but are tagged :free" do
      m =
        OpenRouter.__parse_model__(
          raw(%{"pricing" => %{"prompt" => "0", "completion" => "0"}})
        )

      assert MapSet.member?(m.capabilities, :free)
      assert MapSet.member?(m.capabilities, :chat)
      assert m.tier_hint == :primary
    end
  end

  describe "parse_model/1 — specialty models lose :chat" do
    test "image-only input model (no text input) is not :chat" do
      m =
        OpenRouter.__parse_model__(
          raw(%{
            "architecture" => %{
              "input_modalities" => ["image"],
              "output_modalities" => ["text"]
            }
          })
        )

      refute MapSet.member?(m.capabilities, :chat)
      refute MapSet.member?(m.capabilities, :tools)
      assert MapSet.member?(m.capabilities, :vision)
      assert m.tier_hint == nil
    end

    test "image-generation model is tagged :image_gen and is not :chat" do
      m =
        OpenRouter.__parse_model__(
          raw(%{
            "architecture" => %{
              "input_modalities" => ["text"],
              "output_modalities" => ["image"]
            }
          })
        )

      assert MapSet.member?(m.capabilities, :image_gen)
      refute MapSet.member?(m.capabilities, :chat)
      refute MapSet.member?(m.capabilities, :tools)
      assert m.tier_hint == nil
    end

    test "audio-output model is tagged :audio_out and is not :chat" do
      m =
        OpenRouter.__parse_model__(
          raw(%{
            "architecture" => %{
              "input_modalities" => ["text", "audio"],
              "output_modalities" => ["audio"]
            }
          })
        )

      assert MapSet.member?(m.capabilities, :audio_out)
      assert MapSet.member?(m.capabilities, :audio_in)
      refute MapSet.member?(m.capabilities, :chat)
      assert m.tier_hint == nil
    end

    test "embedding-only model is tagged :embeddings and is not :chat" do
      m =
        OpenRouter.__parse_model__(
          raw(%{
            "architecture" => %{
              "input_modalities" => ["text"],
              "output_modalities" => ["embeddings"]
            }
          })
        )

      assert MapSet.member?(m.capabilities, :embeddings)
      refute MapSet.member?(m.capabilities, :chat)
      refute MapSet.member?(m.capabilities, :tools)
      assert m.tier_hint == nil
    end
  end

  describe "parse_model/1 — :tools requires :chat" do
    test "tools advertised on a non-chat model are dropped" do
      m =
        OpenRouter.__parse_model__(
          raw(%{
            "supported_parameters" => ["tools"],
            "architecture" => %{
              "input_modalities" => ["text"],
              "output_modalities" => ["image"]
            }
          })
        )

      refute MapSet.member?(m.capabilities, :tools)
    end
  end

  describe "parse_model/1 — reasoning + free flags" do
    test "reasoning is preserved on chat models" do
      m =
        OpenRouter.__parse_model__(
          raw(%{"supported_parameters" => ["tools", "reasoning"]})
        )

      assert MapSet.member?(m.capabilities, :reasoning)
    end
  end

  describe "request_body_extras/1" do
    test "defaults to data_collection allow + fallbacks true with no sort" do
      extras = OpenRouter.request_body_extras(%{model: "test/model"})

      assert extras["provider"]["data_collection"] == "allow"
      assert extras["provider"]["allow_fallbacks"] == true
      refute Map.has_key?(extras["provider"], "sort")
    end

    test "sets sort to price when preference is :optimize_price" do
      extras = OpenRouter.request_body_extras(%{model: "test/model", preference: :optimize_price})

      assert extras["provider"]["sort"] == "price"
    end

    test "sets sort to throughput when preference is :optimize_speed" do
      extras = OpenRouter.request_body_extras(%{model: "test/model", preference: :optimize_speed})

      assert extras["provider"]["sort"] == "throughput"
    end
  end
end
