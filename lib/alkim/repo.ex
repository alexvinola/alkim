defmodule Alkim.Repo do
  use Ecto.Repo,
    otp_app: :alkim,
    adapter: Ecto.Adapters.SQLite3
end
