[workspace_root] = Application.fetch_env!(:khymeia, :workspace_roots)
File.rm_rf!(workspace_root)
File.mkdir_p!(workspace_root)

ExUnit.start()
Ecto.Adapters.SQL.Sandbox.mode(Khymeia.Repo, :manual)
