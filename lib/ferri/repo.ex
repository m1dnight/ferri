defmodule Ferri.Repo do
  use Ecto.Repo,
    otp_app: :ferri,
    adapter: Ecto.Adapters.Postgres
end
