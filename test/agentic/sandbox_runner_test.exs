defmodule Agentic.Sandbox.RunnerTest do
  use ExUnit.Case, async: true

  describe "script_bind_roots/1" do
    test "extracts a tool prefix from a shebang shim's exec target" do
      root = Path.join(System.tmp_dir!(), "agentic-shim-#{:rand.uniform(9999)}")
      File.mkdir_p!(Path.join(root, "sbin"))
      shim = Path.join([root, "sbin", "claude"])

      File.write!(shim, """
      #!/bin/sh
      export DISABLE_UPDATES=1
      exec /opt/claude-code/bin/claude "$@"
      """)

      # The shim lives "at" /usr/sbin/claude conceptually; pass the file path
      # directly — the scan is path-independent, it reads the script text.
      assert Agentic.Sandbox.Runner.script_bind_roots(shim) == ["/opt/claude-code"]

      File.rm_rf!(root)
    end

    test "ignores already-bound base paths" do
      root = Path.join(System.tmp_dir!(), "agentic-shim-#{:rand.uniform(9999)}")
      File.mkdir_p!(root)
      shim = Path.join(root, "wrap")
      File.write!(shim, "#!/bin/sh\nexec /usr/bin/node /opt/claude-code/cli.js \"$@\"\n")

      # /usr/bin is covered by the base ro-binds; only /opt/claude-code remains.
      assert Agentic.Sandbox.Runner.script_bind_roots(shim) == ["/opt/claude-code"]

      File.rm_rf!(root)
    end

    test "returns nothing for binaries that are not scripts" do
      root = Path.join(System.tmp_dir!(), "agentic-shim-#{:rand.uniform(9999)}")
      File.mkdir_p!(root)
      path = Path.join(root, "binary")
      File.write!(path, <<0, 1, 2, 3>>)

      assert Agentic.Sandbox.Runner.script_bind_roots(path) == []

      File.rm_rf!(root)
    end

    test "returns nothing for missing files" do
      assert Agentic.Sandbox.Runner.script_bind_roots("/nonexistent/shim") == []
    end
  end
end
