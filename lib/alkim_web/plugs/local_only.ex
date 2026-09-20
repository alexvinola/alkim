defmodule AlkimWeb.Plugs.LocalOnly do
  @moduledoc """
  Rejects HTTP requests whose `Host` header is not a loopback name.

  Alkim controls processes with filesystem access, and binds to
  127.0.0.1. Binding alone does not stop DNS rebinding, where a web page on
  `evil.example` re-points its own hostname at 127.0.0.1 and then talks to
  local services as "same origin". Checking the `Host` header closes that
  hole for HTTP; LiveView sockets are additionally protected by the
  endpoint's `check_origin`.

  Extra host names can be allowed with `config :alkim, :allowed_hosts`.
  """

  import Plug.Conn

  @loopback ~w(localhost 127.0.0.1 ::1 [::1])

  def init(opts), do: opts

  def call(conn, _opts) do
    if conn.host in @loopback or conn.host in Application.get_env(:alkim, :allowed_hosts, []) do
      conn
    else
      conn
      |> put_resp_content_type("text/plain")
      |> send_resp(403, "Alkim only answers requests addressed to localhost.\n")
      |> halt()
    end
  end
end
