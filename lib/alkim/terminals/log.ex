defmodule Alkim.Terminals.Log do
  @moduledoc """
  What a terminal printed, kept on disk so a session survives Alkim
  restarting — not just the browser closing.

  This is the one place Alkim stores raw harness output, and it deserves
  care: a terminal shows whatever the agent and the user put on screen, which
  can include tokens, file contents or anything else typed into a prompt.
  So the directory is `0700`, each file is `0600`, files are capped, and
  deleting a terminal deletes its log.

  The cap is enforced by rewriting the file from the terminal's in-memory
  scrollback rather than by trimming in place: cutting a file mid-escape
  sequence would corrupt everything replayed after it.
  """

  require Logger

  @max_bytes 1_000_000

  def max_bytes, do: @max_bytes

  @doc "Directory holding the logs, beside the database by default."
  def dir do
    Application.get_env(:alkim, :terminal_log_dir) ||
      Alkim.Repo.config()
      |> Keyword.fetch!(:database)
      |> Path.dirname()
      |> Path.join("terminal-logs")
  end

  def path(id), do: Path.join(dir(), id <> ".log")

  @doc "Opens (creating) a terminal's log for appending. `:error` if it cannot be written."
  @spec open(String.t()) :: {:ok, File.io_device()} | :error
  def open(id) do
    with :ok <- ensure_dir(),
         {:ok, device} <- File.open(path(id), [:append, :binary, :raw]) do
      _ = File.chmod(path(id), 0o600)
      {:ok, device}
    else
      error ->
        Logger.warning("terminal #{id}: output will not be saved (#{inspect(error)})")
        :error
    end
  end

  def write(nil, _data), do: :ok
  def write(device, data), do: IO.binwrite(device, data)

  def close(nil), do: :ok
  def close(device), do: File.close(device)

  @doc """
  Replaces the log with `scrollback`, used once a log grows past the cap.
  Returns a fresh device positioned at the end.
  """
  @spec rewrite(String.t(), File.io_device() | nil, binary()) :: File.io_device() | nil
  def rewrite(id, device, scrollback) do
    close(device)

    with :ok <- ensure_dir(),
         :ok <- File.write(path(id), scrollback),
         :ok <- File.chmod(path(id), 0o600),
         {:ok, fresh} <- File.open(path(id), [:append, :binary, :raw]) do
      fresh
    else
      _ -> nil
    end
  end

  @doc "Everything saved for a terminal, or `\"\"` when nothing was."
  @spec read(String.t()) :: binary()
  def read(id) do
    case File.read(path(id)) do
      {:ok, contents} -> contents
      {:error, _} -> ""
    end
  end

  @doc "Forgets a terminal's output."
  def delete(id), do: File.rm(path(id))

  defp ensure_dir do
    directory = dir()

    with :ok <- File.mkdir_p(directory) do
      _ = File.chmod(directory, 0o700)
      :ok
    end
  end
end
