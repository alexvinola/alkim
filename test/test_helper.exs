[workspace_root] = Application.fetch_env!(:khymeia, :workspace_roots)
File.rm_rf!(workspace_root)
File.mkdir_p!(workspace_root)

# Terminals write what they print to disk; the suite starts from nothing.
File.rm_rf!(Application.fetch_env!(:khymeia, :terminal_log_dir))

{:ok, _} = Khymeia.MemorySecrets.start_link([])

ExUnit.start()
Ecto.Adapters.SQL.Sandbox.mode(Khymeia.Repo, :manual)
