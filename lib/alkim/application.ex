defmodule Alkim.Application do
  @moduledoc false

  use Application

  require Logger

  @impl true
  def start(_type, _args) do
    children = [
      AlkimWeb.Telemetry,
      Alkim.Repo,
      {Ecto.Migrator,
       repos: Application.fetch_env!(:alkim, :ecto_repos), skip: skip_migrations?()},
      {Task, &recover_interrupted_sessions/0},
      {Phoenix.PubSub, name: Alkim.PubSub},
      Alkim.Runtime.Supervisor,
      AlkimWeb.Endpoint
    ]

    opts = [strategy: :one_for_one, name: Alkim.Supervisor]
    Supervisor.start_link(children, opts)
  end

  @impl true
  def config_change(changed, _new, removed) do
    AlkimWeb.Endpoint.config_change(changed, removed)
    :ok
  end

  # Sessions a previous run left active cannot be re-attached to.
  defp recover_interrupted_sessions do
    if Application.get_env(:alkim, :recover_sessions_on_boot, true) do
      case Alkim.Sessions.fail_interrupted() do
        {0, _} -> :ok
        {n, _} -> Logger.info("marked #{n} interrupted session(s) from a previous run as failed")
      end

      case Alkim.Workflow.Store.fail_interrupted() do
        {0, _} -> :ok
        {n, _} -> Logger.info("marked #{n} interrupted workflow(s) from a previous run as failed")
      end

      case Alkim.Terminals.close_interrupted() do
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
