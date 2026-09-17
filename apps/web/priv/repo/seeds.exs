# Script for populating the database. You can run it as:
#
#     mix run priv/repo/seeds.exs
#
# Local default account (dev): admin@localhost / admin

alias DroneFeed.Accounts.User
alias DroneFeed.Repo

email = "admin@localhost"
password = "admin"
now = DateTime.utc_now(:second)

case Repo.get_by(User, email: email) do
  nil ->
    %User{}
    |> Ecto.Changeset.change(%{
      email: email,
      first_name: "Local",
      last_name: "Admin",
      organization: "DroneFeed Dev",
      location: "localhost",
      hashed_password: Bcrypt.hash_pwd_salt(password),
      confirmed_at: now,
      role: "admin",
      status: "active",
      approved_at: now
    })
    |> Repo.insert!()

    IO.puts("Seeded local admin: #{email} / #{password}")

  user ->
    user
    |> Ecto.Changeset.change(%{
      role: "admin",
      status: "active",
      confirmed_at: user.confirmed_at || now,
      first_name: user.first_name || "Local",
      last_name: user.last_name || "Admin",
      organization: user.organization || "DroneFeed Dev",
      location: user.location || "localhost"
    })
    |> Repo.update!()

    IO.puts("Admin already present (ensured admin role): #{email}")
end
