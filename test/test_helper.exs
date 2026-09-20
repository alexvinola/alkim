[workspace_root] = Application.fetch_env!(:alkim, :workspace_roots)
File.rm_rf!(workspace_root)
File.mkdir_p!(workspace_root)

# Terminals write what they print to disk; the suite starts from nothing.
File.rm_rf!(Application.fetch_env!(:alkim, :terminal_log_dir))

{:ok, _} = Alkim.MemorySecrets.start_link([])

ExUnit.start()
Ecto.Adapters.SQL.Sandbox.mode(Alkim.Repo, :manual)
