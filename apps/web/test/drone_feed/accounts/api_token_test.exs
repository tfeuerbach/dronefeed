defmodule DroneFeed.Accounts.ApiTokenTest do
  use DroneFeed.DataCase, async: true

  import Ecto.Query

  alias DroneFeed.Accounts
  alias DroneFeed.Accounts.ApiToken
  alias DroneFeed.AccountsFixtures
  alias DroneFeed.Repo

  setup do
    %{user: AccountsFixtures.user_fixture()}
  end

  test "create shows plaintext once; lookup works; revoke blocks", %{user: user} do
    assert {:ok, token} = Accounts.create_api_token(user, %{name: " laptop "})
    assert token.name == "laptop"
    assert String.starts_with?(token.plaintext, "df_")
    assert String.starts_with?(token.prefix, "df_")
    assert token.expires_at
    assert DateTime.diff(token.expires_at, DateTime.utc_now(:second), :day) in 364..365

    assert Accounts.get_user_by_api_token(token.plaintext).id == user.id

    listed = Accounts.list_api_tokens(user)
    assert length(listed) == 1
    assert hd(listed).plaintext == nil

    assert {:ok, _} = Accounts.revoke_api_token(user, token.id)
    assert Accounts.get_user_by_api_token(token.plaintext) == nil
  end

  test "rejects blank name", %{user: user} do
    assert {:error, changeset} = Accounts.create_api_token(user, %{name: "  "})
    assert %{name: _} = errors_on(changeset)
  end

  test "limits to two tokens per user", %{user: user} do
    assert {:ok, _} = Accounts.create_api_token(user, %{name: "one"})
    assert {:ok, _} = Accounts.create_api_token(user, %{name: "two"})
    assert {:error, :limit_reached} = Accounts.create_api_token(user, %{name: "three"})
    assert Accounts.count_api_tokens(user) == ApiToken.max_per_user()
  end

  test "expired tokens cannot authenticate", %{user: user} do
    assert {:ok, token} = Accounts.create_api_token(user, %{name: "stale"})
    past = DateTime.utc_now(:second) |> DateTime.add(-1, :day)

    from(t in ApiToken, where: t.id == ^token.id)
    |> Repo.update_all(set: [expires_at: past])

    assert Accounts.get_user_by_api_token(token.plaintext) == nil
  end
end
