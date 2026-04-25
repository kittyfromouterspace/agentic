defmodule Agentic.LLM.ProviderAccountTest do
  use ExUnit.Case, async: true

  alias Agentic.LLM.ProviderAccount

  describe "default/1" do
    test "returns a pay-per-token, ready account for the given provider" do
      account = ProviderAccount.default(:anthropic)

      assert account.provider == :anthropic
      assert account.account_id == "anthropic"
      assert account.cost_profile == :pay_per_token
      assert account.availability == :ready
      assert account.credentials_status == :ready
      assert account.subscription == nil
      assert account.quotas == nil
    end
  end

  describe "for_provider/2" do
    test "finds the matching account in a list" do
      accounts = [
        ProviderAccount.default(:anthropic),
        %ProviderAccount{provider: :openai, account_id: "personal", cost_profile: :pay_per_token}
      ]

      account = ProviderAccount.for_provider(accounts, :openai)
      assert account.provider == :openai
      assert account.account_id == "personal"
    end

    test "falls back to default/1 when no match" do
      account = ProviderAccount.for_provider([], :openrouter)
      assert account.provider == :openrouter
      assert account.cost_profile == :pay_per_token
    end

    test "nil account list yields the default" do
      account = ProviderAccount.for_provider(nil, :groq)
      assert account.provider == :groq
    end
  end

  describe "quota_pressure/1" do
    test "returns 0.0 when quotas are nil" do
      account = ProviderAccount.default(:anthropic)
      assert ProviderAccount.quota_pressure(account) == 0.0
    end

    test "returns 0.0 below 70% utilization" do
      account = %ProviderAccount{
        provider: :anthropic,
        quotas: %{tokens_used: 60_000, tokens_limit: 100_000, period_end: DateTime.utc_now()}
      }

      assert ProviderAccount.quota_pressure(account) == 0.0
    end

    test "ramps between 70% and 90%" do
      account = %ProviderAccount{
        provider: :anthropic,
        quotas: %{tokens_used: 80_000, tokens_limit: 100_000, period_end: DateTime.utc_now()}
      }

      pressure = ProviderAccount.quota_pressure(account)
      assert pressure > 0.0
      assert pressure < 3.0
    end

    test "cliffs above 90%" do
      account = %ProviderAccount{
        provider: :anthropic,
        quotas: %{tokens_used: 95_000, tokens_limit: 100_000, period_end: DateTime.utc_now()}
      }

      assert ProviderAccount.quota_pressure(account) > 5.0
    end

    test "saturated quota returns a large but bounded value" do
      account = %ProviderAccount{
        provider: :anthropic,
        quotas: %{tokens_used: 200_000, tokens_limit: 100_000, period_end: DateTime.utc_now()}
      }

      pressure = ProviderAccount.quota_pressure(account)
      assert pressure > 0.0
      assert pressure <= 60.0
    end
  end
end
