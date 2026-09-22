defmodule DroneFeed.Accounts.ApiTokenTest do
  use DroneFeed.DataCase, async: true

  alias DroneFeed.Accounts
  alias DroneFeed.AccountsFixtures

  setup do
    %{user: AccountsFixtures.user_fixture()}
  end

  test "create shows plaintext once; lookup works; revoke blocks", %{user: user} do
    assert {:ok, token} = Accounts.create_api_token(user, %{name: " laptop "})
    assert token.name == "laptop"
    assert String.starts_with?(token.plaintext, "df_")
    assert String.starts_with?(token.prefix, "df_")

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
end
