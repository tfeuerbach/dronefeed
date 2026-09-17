defmodule DroneFeed.AccountsFixtures do
  @moduledoc """
  This module defines test helpers for creating
  entities via the `DroneFeed.Accounts` context.
  """

  import Ecto.Query

  alias DroneFeed.Accounts
  alias DroneFeed.Accounts.Scope
  alias DroneFeed.Accounts.User
  alias DroneFeed.Repo

  def unique_user_email, do: "user#{System.unique_integer()}@example.com"
  def valid_user_password, do: "hello world1!"

  def valid_user_attributes(attrs \\ %{}) do
    Enum.into(attrs, %{
      email: unique_user_email()
    })
  end

  def valid_account_request_attributes(attrs \\ %{}) do
    Enum.into(attrs, %{
      email: unique_user_email(),
      password: valid_user_password(),
      password_confirmation: valid_user_password(),
      first_name: "Ada",
      last_name: "Researcher",
      organization: "Lab One",
      location: "Cambridge, MA"
    })
  end

  def unconfirmed_user_fixture(attrs \\ %{}) do
    {:ok, user} =
      attrs
      |> valid_user_attributes()
      |> Map.put_new(:status, "pending_verification")
      |> Map.put_new(:confirmed_at, nil)
      |> Accounts.register_user()

    user
  end

  def user_fixture(attrs \\ %{}) do
    attrs = valid_user_attributes(attrs)
    now = DateTime.utc_now(:second)
    password = Map.get(attrs, :password) || valid_user_password()

    %User{}
    |> Ecto.Changeset.change(%{
      email: attrs.email,
      first_name: Map.get(attrs, :first_name, "Test"),
      last_name: Map.get(attrs, :last_name, "User"),
      organization: Map.get(attrs, :organization, "Test Org"),
      location: Map.get(attrs, :location, "Test Lab"),
      hashed_password: Bcrypt.hash_pwd_salt(password),
      confirmed_at: now,
      role: Map.get(attrs, :role, "user"),
      status: Map.get(attrs, :status, "active"),
      approved_at: now
    })
    |> Repo.insert!()
  end

  def admin_fixture(attrs \\ %{}) do
    user_fixture(Map.put(attrs, :role, "admin"))
  end

  def user_scope_fixture do
    user = user_fixture()
    user_scope_fixture(user)
  end

  def user_scope_fixture(user) do
    Scope.for_user(user)
  end

  def set_password(user) do
    {:ok, {user, _expired_tokens}} =
      Accounts.update_user_password(user, %{password: valid_user_password()})

    user
  end

  def extract_user_token(fun) do
    {:ok, captured_email} = fun.(&"[TOKEN]#{&1}[TOKEN]")
    [_, token | _] = String.split(captured_email.text_body, "[TOKEN]")
    token
  end

  def override_token_authenticated_at(token, authenticated_at) when is_binary(token) do
    DroneFeed.Repo.update_all(
      from(t in Accounts.UserToken,
        where: t.token == ^token
      ),
      set: [authenticated_at: authenticated_at]
    )
  end

  def generate_user_magic_link_token(user) do
    {encoded_token, user_token} = Accounts.UserToken.build_email_token(user, "login")
    DroneFeed.Repo.insert!(user_token)
    {encoded_token, user_token.token}
  end

  def offset_user_token(token, amount_to_add, unit) do
    dt = DateTime.add(DateTime.utc_now(:second), amount_to_add, unit)

    DroneFeed.Repo.update_all(
      from(ut in Accounts.UserToken, where: ut.token == ^token),
      set: [inserted_at: dt, authenticated_at: dt]
    )
  end
end
