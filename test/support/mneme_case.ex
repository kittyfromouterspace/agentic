defmodule AgentEx.MnemeCase do
  @moduledoc """
  Test case for Mneme-backed knowledge tests.

  Sets up Ecto SQL Sandbox for each test. Only runs when Mneme TestRepo
  is available (Postgres running, migrations applied).
  """

  use ExUnit.CaseTemplate

  using do
    quote do
      import AgentEx.MnemeCase
    end
  end

  setup tags do
    pid = Ecto.Adapters.SQL.Sandbox.start_owner!(Mneme.TestRepo, shared: not tags[:async])
    on_exit(fn -> Ecto.Adapters.SQL.Sandbox.stop_owner(pid) end)
    :ok
  end

  def scope_id, do: Ecto.UUID.generate()
  def owner_id, do: Ecto.UUID.generate()
end
