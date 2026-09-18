defmodule Khymeia.Repo do
  use Ecto.Repo,
    otp_app: :khymeia,
    adapter: Ecto.Adapters.SQLite3
end
