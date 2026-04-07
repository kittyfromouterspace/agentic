defmodule AgentEx.Integration.MnemeKnowledgeTest do
  @moduledoc """
  Integration tests for the Mneme-backed Knowledge backend.

  These tests require a running PostgreSQL with the `mneme_test` database
  and tables already created. One-time setup:

      mix agent_ex.test_setup_mneme

  Then run with:

      mix test --include integration test/agent_ex/integration/mneme_knowledge_test.exs
  """

  use ExUnit.Case, async: false

  @moduletag :integration

  alias AgentEx.Persistence.Knowledge.Mneme, as: Backend

  setup_all do
    Application.ensure_all_started(:mneme)
    {:ok, _} = Mneme.TestRepo.start_link()

    migrations =
      case Application.app_dir(:mneme, "priv/repo/migrations") do
        {:error, _} ->
          Path.join([File.cwd!(), "..", "mneme", "priv", "repo", "migrations"])

        path ->
          path
      end

    :ok = Ecto.Migrator.run(Mneme.TestRepo, migrations, :up, all: true)
  end

  setup do
    pid = Ecto.Adapters.SQL.Sandbox.start_owner!(Mneme.TestRepo, shared: true)
    on_exit(fn -> Ecto.Adapters.SQL.Sandbox.stop_owner(pid) end)
    :ok
  end

  describe "create_entry/2" do
    test "stores an entry and returns behaviour-compliant map" do
      scope = Ecto.UUID.generate()
      owner = Ecto.UUID.generate()

      entry = %{
        content: "The deploy script is at scripts/deploy.sh",
        entry_type: "observation",
        source: "agent",
        scope_id: scope,
        owner_id: owner,
        metadata: %{file: "deploy.sh"},
        confidence: 0.9
      }

      assert {:ok, result} = Backend.create_entry(entry, scope_id: scope, owner_id: owner)
      assert is_binary(result.id)
      assert result.content == "The deploy script is at scripts/deploy.sh"
      assert result.entry_type == "observation"
      assert result.source == "agent"
      assert result.scope_id == scope
      assert result.owner_id == owner
      assert result.confidence == 0.9
      assert result.inserted_at != nil
    end

    test "uses opts for scope_id and owner_id when not in entry" do
      scope = Ecto.UUID.generate()
      owner = Ecto.UUID.generate()

      assert {:ok, result} =
               Backend.create_entry(%{content: "A note", entry_type: "note"},
                 scope_id: scope,
                 owner_id: owner
               )

      assert result.scope_id == scope
      assert result.owner_id == owner
    end
  end

  describe "get_entry/2" do
    test "retrieves an existing entry" do
      scope = Ecto.UUID.generate()
      owner = Ecto.UUID.generate()

      {:ok, created} =
        Backend.create_entry(
          %{content: "Test entry", entry_type: "note", scope_id: scope, owner_id: owner},
          []
        )

      assert {:ok, found} = Backend.get_entry(created.id, [])
      assert found.content == "Test entry"
      assert found.id == created.id
    end

    test "returns not_found for missing entry" do
      assert {:error, :not_found} = Backend.get_entry(Ecto.UUID.generate(), [])
    end
  end

  describe "search/2" do
    test "finds entries by content" do
      scope = Ecto.UUID.generate()
      owner = Ecto.UUID.generate()

      Backend.create_entry(
        %{
          content: "Redis connection string is redis://localhost:6379",
          entry_type: "observation",
          scope_id: scope,
          owner_id: owner
        },
        []
      )

      Backend.create_entry(
        %{
          content: "PostgreSQL runs on port 5432",
          entry_type: "observation",
          scope_id: scope,
          owner_id: owner
        },
        []
      )

      assert {:ok, results} = Backend.search("Redis", scope_id: scope, owner_id: owner)
      assert length(results) >= 1
    end
  end

  describe "create_edge/4 and get_edges/3" do
    test "creates an edge and retrieves it" do
      scope = Ecto.UUID.generate()
      owner = Ecto.UUID.generate()

      {:ok, e1} =
        Backend.create_entry(
          %{content: "Entry one", entry_type: "note", scope_id: scope, owner_id: owner},
          []
        )

      {:ok, e2} =
        Backend.create_entry(
          %{content: "Entry two", entry_type: "note", scope_id: scope, owner_id: owner},
          []
        )

      assert {:ok, edge} = Backend.create_edge(e1.id, e2.id, "supports", weight: 0.8)
      assert edge.source_entry_id == e1.id
      assert edge.target_entry_id == e2.id
      assert edge.relation == "supports"
      assert edge.weight == 0.8

      assert {:ok, edges} = Backend.get_edges(e1.id, :from, [])
      assert length(edges) >= 1
    end
  end

  describe "recent/2" do
    test "returns recent entries for a scope" do
      scope = Ecto.UUID.generate()
      owner = Ecto.UUID.generate()

      for i <- 1..5 do
        Backend.create_entry(
          %{content: "Recent entry #{i}", entry_type: "note", scope_id: scope, owner_id: owner},
          []
        )
      end

      assert {:ok, entries} = Backend.recent(scope, limit: 3)
      assert length(entries) == 3
    end

    test "excludes archived entries" do
      scope = Ecto.UUID.generate()
      owner = Ecto.UUID.generate()

      Backend.create_entry(
        %{content: "Active note", entry_type: "note", scope_id: scope, owner_id: owner},
        []
      )

      Backend.create_entry(
        %{content: "Old note", entry_type: "archived", scope_id: scope, owner_id: owner},
        []
      )

      assert {:ok, entries} = Backend.recent(scope, [])
      assert length(entries) == 1
      assert hd(entries).content == "Active note"
    end
  end

  describe "supersede/4" do
    test "demotes entries matching the pattern" do
      scope = Ecto.UUID.generate()
      owner = Ecto.UUID.generate()

      Backend.create_entry(
        %{
          content: "The API endpoint is /v1/users",
          entry_type: "observation",
          scope_id: scope,
          owner_id: owner,
          confidence: 1.0
        },
        []
      )

      Backend.create_entry(
        %{
          content: "Unrelated note",
          entry_type: "note",
          scope_id: scope,
          owner_id: owner,
          confidence: 1.0
        },
        []
      )

      assert {:ok, []} = Backend.supersede(scope, "API endpoint", "endpoint", "/v2/users")

      {:ok, entries} = Backend.recent(scope, [])
      demoted = Enum.filter(entries, &(&1.confidence < 1.0))
      assert length(demoted) == 1
    end
  end
end
