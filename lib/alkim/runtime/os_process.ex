defmodule Alkim.Runtime.OSProcess do
  @moduledoc """
  Starts harness processes through `priv/bin/alkim-exec` using an Erlang
  port, and decodes what comes back.

  This is a plain module, not a process: the port is owned (and linked) by
  the calling session process, which receives its messages.

  The wrapper tags every line with its stream (`"o "`/`"e "`), gives the
  harness `/dev/null` as stdin, and terminates it when the port is closed,
  so stopping a session — or the VM dying — never leaves orphans behind.
  """

  # Lines longer than this arrive in chunks and are reassembled by `collect/2`.
  @line_chunk 16_384
  # Hard cap on a single reassembled line; beyond this it is truncated.
  @max_line 4 * 1024 * 1024

  # Environment the daemon holds that harnesses have no business seeing.
  @scrubbed_env ~w(SECRET_KEY_BASE RELEASE_COOKIE DATABASE_PATH PHX_SERVER PHX_HOST)

  @type buffer :: iodata()

  @doc """
  Opens a port running `launch` inside `cwd`. Arguments are passed as argv —
  no shell ever parses them.
  """
  @spec open(Alkim.Harness.launch(), String.t()) :: {:ok, port()} | {:error, term()}
  def open(%{executable: executable, args: args} = launch, cwd) do
    env =
      [{"PATH", Alkim.Harness.Executable.search_path()}] ++
        Enum.map(@scrubbed_env, &{&1, false}) ++ Map.get(launch, :env, [])

    port =
      Port.open({:spawn_executable, "/bin/sh"}, [
        :binary,
        :exit_status,
        :use_stdio,
        :hide,
        {:line, @line_chunk},
        {:cd, cwd},
        {:args, [wrapper() | [executable | args]]},
        {:env, Enum.map(env, &charlist_env/1)}
      ])

    {:ok, port}
  rescue
    error in ArgumentError -> {:error, Exception.message(error)}
    error in ErlangError -> {:error, inspect(error.original)}
  end

  @doc "OS pid of the wrapper process, if the port is still open."
  def os_pid(port) do
    case Port.info(port, :os_pid) do
      {:os_pid, pid} -> pid
      nil -> nil
    end
  end

  @doc "Closes the port; the wrapper then terminates the harness."
  def close(port) do
    Port.close(port)
    :ok
  rescue
    ArgumentError -> :ok
  end

  @doc """
  Feeds one `{:eol, _}` / `{:noeol, _}` port payload into the line buffer.
  Returns `{:line, stream, text, new_buffer}` when a line is complete, or
  `{:partial, new_buffer}`.
  """
  @spec collect({:eol | :noeol, binary()}, buffer()) ::
          {:line, :stdout | :stderr, String.t(), buffer()} | {:partial, buffer()}
  def collect({:noeol, chunk}, buffer) do
    if IO.iodata_length(buffer) < @max_line,
      do: {:partial, [buffer, chunk]},
      else: {:partial, buffer}
  end

  def collect({:eol, chunk}, buffer) do
    {stream, text} = decode(IO.iodata_to_binary([buffer, chunk]))
    {:line, stream, text, []}
  end

  @doc "Splits a wrapper-tagged line into its stream and a valid UTF-8 text."
  def decode("o " <> text), do: {:stdout, sanitize(text)}
  def decode("e " <> text), do: {:stderr, sanitize(text)}
  def decode("o"), do: {:stdout, ""}
  def decode("e"), do: {:stderr, ""}
  def decode(text), do: {:stdout, sanitize(text)}

  defp sanitize(text) do
    text
    |> String.replace_invalid()
    |> String.replace(~r/\e\[[0-9;?]*[ -\/]*[@-~]/, "")
  end

  defp charlist_env({key, false}), do: {String.to_charlist(key), false}
  defp charlist_env({key, value}), do: {String.to_charlist(key), String.to_charlist(value)}

  defp wrapper, do: Application.app_dir(:alkim, "priv/bin/alkim-exec")
end
