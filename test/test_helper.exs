ExUnit.start()
# Disable interop test in the CI (docker test for yamux)
if System.get_env("CI") do
  ExUnit.configure(exclude: [:interop])
end

# DB-TESTS-DISABLED: commented to remove database requirements for tests.
# Re-enable when Ferri.Repo is added back to the supervision tree.
# Ecto.Adapters.SQL.Sandbox.mode(Ferri.Repo, :manual)
