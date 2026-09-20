defmodule Mix.Tasks.Compile.Native do
  @moduledoc """
  Builds the small C helpers in `c_src/` into `priv/bin/`.

  Only `khymeia-pty` needs C: the BEAM cannot allocate a pseudo-terminal or
  resize one, and an interactive harness needs both. Everything else Khymeia
  spawns goes through the POSIX shell wrapper instead.

  It lives in `mix.exs` because a compiler must exist before `lib/` is built.
  """

  use Mix.Task.Compiler

  @sources %{"khymeia_pty.c" => "khymeia-pty"}

  @impl true
  def run(_args) do
    File.mkdir_p!("priv/bin")

    Enum.reduce(@sources, {:noop, []}, fn {source, binary}, acc ->
      case build(Path.join("c_src", source), Path.join("priv/bin", binary)) do
        :noop -> acc
        :ok -> merge(acc, {:ok, []})
        {:error, diagnostic} -> merge(acc, {:error, [diagnostic]})
      end
    end)
  end

  @impl true
  def clean, do: Enum.each(@sources, fn {_, bin} -> File.rm(Path.join("priv/bin", bin)) end)

  defp merge({:error, a}, {_, b}), do: {:error, a ++ b}
  defp merge({_, a}, {:error, b}), do: {:error, a ++ b}
  defp merge(_, result), do: result

  defp build(source, target) do
    if stale?(source, target) do
      Mix.shell().info("Compiling #{source}")

      # Libraries go after the source: GNU ld resolves in command order.
      argv = flags() ++ ["-o", target, source] ++ libraries()

      case System.cmd(compiler(), argv, stderr_to_stdout: true) do
        {_output, 0} -> :ok
        {output, _} -> {:error, diagnostic(source, output)}
      end
    else
      :noop
    end
  end

  defp stale?(source, target) do
    case {File.stat(source), File.stat(target)} do
      {{:ok, src}, {:ok, bin}} -> src.mtime > bin.mtime
      {{:ok, _}, _} -> true
      _ -> false
    end
  end

  defp compiler, do: System.get_env("CC") || "cc"

  defp flags, do: ["-O2", "-Wall", "-Wextra", "-std=c11", "-D_GNU_SOURCE"]

  # forkpty lives in libutil on Linux; on macOS and the BSDs it is in libc.
  defp libraries do
    if match?({:unix, :linux}, :os.type()), do: ["-lutil"], else: []
  end

  defp diagnostic(source, output) do
    Mix.shell().error(output)

    %Mix.Task.Compiler.Diagnostic{
      compiler_name: "native",
      file: Path.absname(source),
      message: "could not compile #{source}. Is a C compiler installed?\n\n#{output}",
      position: 0,
      severity: :error
    }
  end
end

defmodule Khymeia.MixProject do
  use Mix.Project

  def project do
    [
      app: :khymeia,
      version: "0.1.0",
      elixir: "~> 1.17",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      aliases: aliases(),
      deps: deps(),
      compilers: [:native, :phoenix_live_view] ++ Mix.compilers(),
      listeners: [Phoenix.CodeReloader],
      releases: releases(),
      name: "Khymeia",
      description: "Local-first runtime to supervise coding-agent harnesses"
    ]
  end

  # Configuration for the OTP application.
  #
  # Type `mix help compile.app` for more information.
  def application do
    [
      mod: {Khymeia.Application, []},
      extra_applications: [:logger, :runtime_tools]
    ]
  end

  def cli do
    [
      preferred_envs: [precommit: :test]
    ]
  end

  defp releases do
    [
      khymeia: [
        include_executables_for: [:unix],
        applications: [runtime_tools: :permanent]
      ]
    ]
  end

  # Specifies which paths to compile per environment.
  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  # Specifies your project dependencies.
  #
  # Type `mix help deps` for examples and options.
  defp deps do
    [
      {:phoenix, "~> 1.8.14"},
      {:phoenix_ecto, "~> 4.5"},
      {:ecto_sql, "~> 3.13"},
      {:ecto_sqlite3, ">= 0.0.0"},
      {:phoenix_html, "~> 4.1"},
      {:phoenix_live_reload, "~> 1.2", only: :dev},
      {:phoenix_live_view, "~> 1.2.0"},
      {:lazy_html, ">= 0.1.0", only: :test},
      {:esbuild, "~> 0.10", runtime: Mix.env() == :dev},
      {:tailwind, "~> 0.5", runtime: Mix.env() == :dev},
      {:heroicons,
       github: "tailwindlabs/heroicons",
       tag: "v2.2.0",
       sparse: "optimized",
       app: false,
       compile: false,
       depth: 1},
      {:daisyui,
       github: "saadeghi/daisyui",
       tag: "v5.5.20",
       sparse: "packages/bundle",
       app: false,
       compile: false,
       depth: 1},
      {:telemetry_metrics, "~> 1.0"},
      {:telemetry_poller, "~> 1.0"},
      {:jason, "~> 1.2"},
      {:bandit, "~> 1.5"}
    ]
  end

  # Aliases are shortcuts or tasks specific to the current project.
  # For example, to install project dependencies and perform other setup tasks, run:
  #
  #     $ mix setup
  #
  # See the documentation for `Mix` for more info on aliases.
  defp aliases do
    [
      setup: ["deps.get", "ecto.setup", "assets.setup", "assets.build"],
      "ecto.setup": ["ecto.create", "ecto.migrate", "run priv/repo/seeds.exs"],
      "ecto.reset": ["ecto.drop", "ecto.setup"],
      test: ["ecto.create --quiet", "ecto.migrate --quiet", "test"],
      "assets.setup": ["tailwind.install --if-missing", "esbuild.install --if-missing"],
      "assets.build": ["compile", "tailwind khymeia", "esbuild khymeia"],
      "assets.deploy": [
        "tailwind khymeia --minify",
        "esbuild khymeia --minify",
        "phx.digest"
      ],
      precommit: ["compile --warnings-as-errors", "deps.unlock --unused", "format", "test"]
    ]
  end
end
