[workspace_root] = Application.fetch_env!(:khymeia, :workspace_roots)
File.rm_rf!(workspace_root)
File.mkdir_p!(workspace_root)

{:ok, _} = Khymeia.MemorySecrets.start_link([])

ExUnit.start()
Ecto.Adapters.SQL.Sandbox.mode(Khymeia.Repo, :manual)
