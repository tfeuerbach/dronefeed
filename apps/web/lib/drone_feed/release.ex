defmodule DroneFeed.Release do
  @moduledoc """
  Used for executing DB release tasks when run in production without Mix
  installed (e.g. Docker).
  """
  @app :drone_feed

  def migrate do
    load_app()

    for repo <- repos() do
      {:ok, _, _} = Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :up, all: true))
    end

    ensure_admin()
  end

  def rollback(repo, version) do
    load_app()
    {:ok, _, _} = Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :down, to: version))
  end

  @doc """
  Creates or promotes an admin user when ADMIN_EMAIL + ADMIN_PASSWORD are set.
  Password must be at least 12 characters for new accounts.
  Existing accounts with the same email are promoted to the admin group.
  """
  def ensure_admin do
    email = System.get_env("ADMIN_EMAIL")
    password = System.get_env("ADMIN_PASSWORD")

    cond do
      not present?(email) ->
        :ok

      true ->
        load_app()
        {:ok, _, _} =
          Ecto.Migrator.with_repo(DroneFeed.Repo, fn _repo ->
            bootstrap_admin(email, password)
          end)

        :ok
    end
  end

  defp bootstrap_admin(email, password) do
    now = DateTime.utc_now(:second)

    case DroneFeed.Repo.get_by(DroneFeed.Accounts.User, email: email) do
      nil ->
        if not present?(password) or String.length(password) < 12 do
          IO.puts(
            :stderr,
            "ADMIN_PASSWORD must be at least 12 characters to bootstrap a new admin; skipping"
          )

          :ok
        else
          %DroneFeed.Accounts.User{}
          |> Ecto.Changeset.change(%{
            email: email,
            first_name: "Site",
            last_name: "Admin",
            organization: "DroneFeed",
            location: System.get_env("PHX_HOST") || "production",
            hashed_password: Bcrypt.hash_pwd_salt(password),
            confirmed_at: now,
            role: "admin",
            status: "active",
            approved_at: now
          })
          |> DroneFeed.Repo.insert!()

          IO.puts("Bootstrapped admin user: #{email}")
          :ok
        end

      user ->
        attrs = %{
          role: "admin",
          status: "active",
          confirmed_at: user.confirmed_at || now,
          approved_at: user.approved_at || now
        }

        attrs =
          if present?(password) and String.length(password) >= 12 do
            Map.put(attrs, :hashed_password, Bcrypt.hash_pwd_salt(password))
          else
            attrs
          end

        user
        |> Ecto.Changeset.change(attrs)
        |> DroneFeed.Repo.update!()

        IO.puts("Ensured admin group membership: #{email}")
        :ok
    end
  end

  defp present?(value) when is_binary(value), do: String.trim(value) != ""
  defp present?(_), do: false

  defp repos do
    Application.fetch_env!(@app, :ecto_repos)
  end

  defp load_app do
    Application.load(@app)
  end
end
