defmodule Khymeia.Application do
  @moduledoc false

  use Application

  require Logger

  @impl true
  def start(_type, _args) do
    children = [
      KhymeiaWeb.Telemetry,
      Khymeia.Repo,
      {Ecto.Migrator,
       repos: Application.fetch_env!(:khymeia, :ecto_repos), skip: skip_migrations?()},
      {Task, &recover_interrupted_sessions/0},
      {Phoenix.PubSub, name: Khymeia.PubSub},
      Khymeia.Runtime.Supervisor,
      KhymeiaWeb.Endpoint
    ]

    opts = [strategy: :one_for_one, name: Khymeia.Supervisor]
    Supervisor.start_link(children, opts)
  end

  @impl true
  def config_change(changed, _new, removed) do
    KhymeiaWeb.Endpoint.config_change(changed, removed)
    :ok
  end

  # Sessions a previous run left active cannot be re-attached to.
  defp recover_interrupted_sessions do
    if Application.get_env(:khymeia, :recover_sessions_on_boot, true) do
      case Khymeia.Sessions.fail_interrupted() do
        {0, _} -> :ok
        {n, _} -> Logger.info("marked #{n} interrupted session(s) from a previous run as failed")
      end

      case Khymeia.Workflow.Store.fail_interrupted() do
        {0, _} -> :ok
        {n, _} -> Logger.info("marked #{n} interrupted workflow(s) from a previous run as failed")
      end

      case Khymeia.Terminals.close_interrupted() do
        {0, _} -> :ok
        {n, _} -> Logger.info("closed #{n} terminal(s) left open by a previous run")
      end
    end
  end

  defp skip_migrations? do
    # Releases (e.g. `brew services`) migrate on boot; `mix` users run ecto.migrate.
    System.get_env("RELEASE_NAME") == nil
  end
end
