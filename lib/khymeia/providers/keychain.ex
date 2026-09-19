defmodule Khymeia.Providers.Keychain do
  @moduledoc """
  macOS Keychain backend, via the system `security` tool.

  Writing uses `security -i` and sends the command on stdin, so the secret
  never appears in any process's arguments (visible with `ps`). Items are
  generic passwords with service `khymeia`.
  """

  @behaviour Khymeia.Providers.Secrets

  @service "khymeia"
  @security "/usr/bin/security"

  @impl true
  def available?, do: match?({:unix, :darwin}, :os.type()) and File.exists?(@security)

  @impl true
  def put(account, secret) do
    with true <- available?() || {:error, :unavailable},
         true <- Khymeia.Providers.Secrets.valid_secret?(secret) || {:error, :invalid_secret} do
      port =
        Port.open({:spawn_executable, @security}, [:binary, :exit_status, :hide, args: ["-i"]])

      Port.command(
        port,
        ~s(add-generic-password -U -s #{@service} -a #{account} -l "Khymeia provider" -w "#{secret}"\n)
      )

      # `security -i` has no exit command: EOF ends it. Closing the port
      # delivers EOF; the command already written is still executed.
      Port.close(port)

      if wait_until(fn -> exists?(account) end), do: :ok, else: {:error, :keychain_write_failed}
    end
  end

  @impl true
  def get(account) do
    case System.cmd(@security, ["find-generic-password", "-s", @service, "-a", account, "-w"],
           stderr_to_stdout: false
         ) do
      {secret, 0} -> {:ok, String.trim_trailing(secret, "\n")}
      _ -> {:error, :not_found}
    end
  rescue
    _ -> {:error, :unavailable}
  end

  @impl true
  def exists?(account) do
    match?(
      {_, 0},
      System.cmd(@security, ["find-generic-password", "-s", @service, "-a", account],
        stderr_to_stdout: true
      )
    )
  rescue
    _ -> false
  end

  @impl true
  def delete(account) do
    System.cmd(@security, ["delete-generic-password", "-s", @service, "-a", account],
      stderr_to_stdout: true
    )

    :ok
  rescue
    _ -> :ok
  end

  defp wait_until(fun, attempts \\ 20) do
    cond do
      fun.() -> true
      attempts == 0 -> false
      true -> Process.sleep(50) && wait_until(fun, attempts - 1)
    end
  end
end
