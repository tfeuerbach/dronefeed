defmodule DroneFeed.Accounts do
  @moduledoc """
  The Accounts context — registration requests, admin approval, and sessions.
  """

  import Ecto.Query, warn: false
  alias DroneFeed.Repo
  alias DroneFeed.Accounts.{User, UserToken, UserNotifier, AdminNotification}

  @admin_inbox_topic "admin:inbox"

  def subscribe_admin_inbox do
    Phoenix.PubSub.subscribe(DroneFeed.PubSub, @admin_inbox_topic)
  end

  defp broadcast_admin_inbox(message) do
    Phoenix.PubSub.broadcast(DroneFeed.PubSub, @admin_inbox_topic, message)
  end

  ## Database getters

  def get_user_by_email(email) when is_binary(email) do
    Repo.get_by(User, email: email)
  end

  @doc """
  Gets a user by email and password when the account is active and verified.
  Returns `{:error, reason}` for inactive accounts so the UI can explain why.
  """
  def authenticate_user(email, password)
      when is_binary(email) and is_binary(password) do
    user = Repo.get_by(User, email: email)

    cond do
      not User.valid_password?(user, password) ->
        {:error, :invalid_credentials}

      user.status == "pending_approval" ->
        {:error, :pending_approval}

      user.status == "pending_verification" ->
        {:error, :pending_verification}

      user.status == "rejected" ->
        {:error, :rejected}

      not User.active?(user) ->
        {:error, :inactive}

      true ->
        {:ok, user}
    end
  end

  def get_user_by_email_and_password(email, password)
      when is_binary(email) and is_binary(password) do
    case authenticate_user(email, password) do
      {:ok, user} -> user
      _ -> nil
    end
  end

  def get_user!(id), do: Repo.get!(User, id)

  def list_admins do
    from(u in User, where: u.role == "admin" and u.status == "active", order_by: [asc: u.email])
    |> Repo.all()
  end

  def list_users do
    from(u in User, order_by: [desc: u.inserted_at], preload: [:approved_by])
    |> Repo.all()
  end

  def list_pending_approval_users do
    from(u in User,
      where: u.status == "pending_approval",
      order_by: [asc: u.inserted_at]
    )
    |> Repo.all()
  end

  def count_pending_approvals do
    Repo.aggregate(from(u in User, where: u.status == "pending_approval"), :count)
  end

  def list_admin_notifications(limit \\ 50) do
    from(n in AdminNotification,
      order_by: [desc: n.inserted_at],
      limit: ^limit,
      preload: [:subject_user]
    )
    |> Repo.all()
  end

  def count_unread_admin_notifications do
    Repo.aggregate(from(n in AdminNotification, where: is_nil(n.read_at)), :count)
  end

  def mark_notification_read(%AdminNotification{} = notification) do
    notification
    |> AdminNotification.changeset(%{read_at: DateTime.utc_now(:second)})
    |> Repo.update()
    |> tap(fn
      {:ok, _} -> broadcast_admin_inbox({:admin_inbox_updated, :read})
      _ -> :ok
    end)
  end

  def mark_all_notifications_read do
    now = DateTime.utc_now(:second)

    {count, _} =
      from(n in AdminNotification, where: is_nil(n.read_at))
      |> Repo.update_all(set: [read_at: now])

    if count > 0, do: broadcast_admin_inbox({:admin_inbox_updated, :read_all})
    {:ok, count}
  end

  ## Account requests

  def change_account_request(attrs \\ %{}, opts \\ []) do
    User.account_request_changeset(%User{}, attrs, opts)
  end

  @doc """
  Creates a pending account request, notifies admins (inbox + email).
  """
  def request_account(attrs, review_url_fun) when is_function(review_url_fun, 0) do
    changeset = User.account_request_changeset(%User{}, attrs)

    Repo.transact(fn ->
      with {:ok, user} <- Repo.insert(changeset),
           {:ok, notification} <- insert_account_request_notification(user) do
        {:ok, {user, notification}}
      end
    end)
    |> case do
      {:ok, {user, notification}} ->
        deliver_admin_request_emails(user, review_url_fun.())
        broadcast_admin_inbox({:admin_inbox_updated, notification})
        {:ok, user}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:error, changeset}
    end
  end

  defp insert_account_request_notification(user) do
    name = User.display_name(user)

    %AdminNotification{}
    |> AdminNotification.changeset(%{
      kind: "account_request",
      title: "Account request: #{name}",
      body:
        "#{name} (#{user.email}) from #{user.organization} in #{user.location} requested access.",
      subject_user_id: user.id
    })
    |> Repo.insert()
  end

  defp deliver_admin_request_emails(user, review_url) do
    admins = list_admins()

    recipients =
      if admins == [] do
        contact = Application.get_env(:drone_feed, :admin_contact)

        if is_binary(contact) and String.contains?(contact, "@"),
          do: [contact],
          else: []
      else
        Enum.map(admins, & &1.email)
      end

    Enum.each(recipients, fn email ->
      UserNotifier.deliver_admin_account_request(user, email, review_url)
    end)
  end

  @doc """
  Admin approves a pending request and emails a verification link.

  `opts` may include `:role` (default `"user"`) and must include `:verify_url_fun`.
  """
  def approve_account(%User{} = admin, %User{} = user, opts) when is_list(opts) do
    unless User.admin?(admin), do: raise("only admins can approve accounts")

    role = Keyword.get(opts, :role, "user")
    verify_url_fun = Keyword.fetch!(opts, :verify_url_fun)

    user
    |> User.approve_changeset(admin, role)
    |> Repo.update()
    |> case do
      {:ok, user} ->
        maybe_mark_request_notifications_read(user)
        {:ok, _} = deliver_user_verification_instructions(user, verify_url_fun)
        broadcast_admin_inbox({:admin_inbox_updated, :approved})
        {:ok, user}

      error ->
        error
    end
  end

  def reject_account(%User{} = admin, %User{} = user) do
    unless User.admin?(admin), do: raise("only admins can reject accounts")

    contact = Application.get_env(:drone_feed, :admin_contact, "your system administrator")

    user
    |> User.reject_changeset()
    |> Repo.update()
    |> case do
      {:ok, user} ->
        maybe_mark_request_notifications_read(user)
        UserNotifier.deliver_account_rejected(user, contact)
        broadcast_admin_inbox({:admin_inbox_updated, :rejected})
        {:ok, user}

      error ->
        error
    end
  end

  defp maybe_mark_request_notifications_read(user) do
    now = DateTime.utc_now(:second)

    from(n in AdminNotification,
      where: n.subject_user_id == ^user.id and is_nil(n.read_at)
    )
    |> Repo.update_all(set: [read_at: now])
  end

  def update_user_role(%User{} = admin, %User{} = user, role) do
    unless User.admin?(admin), do: raise("only admins can change roles")

    if user.id == admin.id and role != "admin" do
      {:error, :cannot_demote_self}
    else
      user
      |> User.role_changeset(%{role: role})
      |> Repo.update()
    end
  end

  def change_user_profile(%User{} = user, attrs \\ %{}, opts \\ []) do
    User.profile_changeset(user, attrs, opts)
  end

  def update_user_profile(%User{} = admin, %User{} = user, attrs) do
    unless User.admin?(admin), do: raise("only admins can update profiles")

    user
    |> User.profile_changeset(attrs)
    |> Repo.update()
  end

  ## Registration (tests / fixtures)

  def register_user(attrs) do
    status = Map.get(attrs, :status) || Map.get(attrs, "status") || "pending_verification"
    role = Map.get(attrs, :role) || Map.get(attrs, "role") || "user"

    confirmed_at =
      cond do
        Map.has_key?(attrs, :confirmed_at) -> Map.get(attrs, :confirmed_at)
        Map.has_key?(attrs, "confirmed_at") -> Map.get(attrs, "confirmed_at")
        status == "active" -> DateTime.utc_now(:second)
        true -> nil
      end

    %User{}
    |> User.email_changeset(attrs)
    |> Ecto.Changeset.put_change(:status, status)
    |> Ecto.Changeset.put_change(:role, role)
    |> Ecto.Changeset.put_change(:confirmed_at, confirmed_at)
    |> Repo.insert()
  end

  ## Settings

  def sudo_mode?(user, minutes \\ -20)

  def sudo_mode?(%User{authenticated_at: ts}, minutes) when is_struct(ts, DateTime) do
    DateTime.after?(ts, DateTime.utc_now() |> DateTime.add(minutes, :minute))
  end

  def sudo_mode?(_user, _minutes), do: false

  def change_user_email(user, attrs \\ %{}, opts \\ []) do
    User.email_changeset(user, attrs, opts)
  end

  def update_user_email(user, token) do
    context = "change:#{user.email}"

    Repo.transact(fn ->
      with {:ok, query} <- UserToken.verify_change_email_token_query(token, context),
           %UserToken{sent_to: email} <- Repo.one(query),
           {:ok, user} <- Repo.update(User.email_changeset(user, %{email: email})),
           {_count, _result} <-
             Repo.delete_all(from(UserToken, where: [user_id: ^user.id, context: ^context])) do
        {:ok, user}
      else
        _ -> {:error, :transaction_aborted}
      end
    end)
  end

  def change_user_password(user, attrs \\ %{}, opts \\ []) do
    User.password_changeset(user, attrs, opts)
  end

  def update_user_password(user, attrs) do
    user
    |> User.password_changeset(attrs)
    |> update_user_and_delete_all_tokens()
  end

  ## Session

  def generate_user_session_token(user) do
    {token, user_token} = UserToken.build_session_token(user)
    Repo.insert!(user_token)
    token
  end

  def get_user_by_session_token(token) do
    {:ok, query} = UserToken.verify_session_token_query(token)
    Repo.one(query)
  end

  def get_user_by_magic_link_token(token) do
    with {:ok, query} <- UserToken.verify_magic_link_token_query(token),
         {user, _token} <- Repo.one(query) do
      user
    else
      _ -> nil
    end
  end

  def login_user_by_magic_link(token) do
    {:ok, query} = UserToken.verify_magic_link_token_query(token)

    case Repo.one(query) do
      {%User{confirmed_at: nil, hashed_password: hash}, _token} when not is_nil(hash) ->
        raise """
        magic link log in is not allowed for unconfirmed users with a password set!
        """

      {%User{confirmed_at: nil} = user, _token} ->
        user
        |> User.confirm_changeset()
        |> update_user_and_delete_all_tokens()

      {user, token} ->
        Repo.delete!(token)
        {:ok, {user, []}}

      nil ->
        {:error, :not_found}
    end
  end

  def deliver_user_update_email_instructions(%User{} = user, current_email, update_email_url_fun)
      when is_function(update_email_url_fun, 1) do
    {encoded_token, user_token} = UserToken.build_email_token(user, "change:#{current_email}")

    Repo.insert!(user_token)
    UserNotifier.deliver_update_email_instructions(user, update_email_url_fun.(encoded_token))
  end

  def deliver_login_instructions(%User{} = user, magic_link_url_fun)
      when is_function(magic_link_url_fun, 1) do
    {encoded_token, user_token} = UserToken.build_email_token(user, "login")
    Repo.insert!(user_token)
    UserNotifier.deliver_login_instructions(user, magic_link_url_fun.(encoded_token))
  end

  def deliver_user_verification_instructions(%User{} = user, verify_url_fun)
      when is_function(verify_url_fun, 1) do
    {encoded_token, user_token} = UserToken.build_email_token(user, "confirm")
    Repo.insert!(user_token)
    UserNotifier.deliver_verification_instructions(user, verify_url_fun.(encoded_token))
  end

  @doc """
  Confirms a user from a verification token and sends the "account ready" email.
  """
  def confirm_user(token, login_url) when is_binary(token) and is_binary(login_url) do
    with {:ok, query} <- UserToken.verify_email_token_query(token, "confirm"),
         {user, token_row} <- Repo.one(query) do
      Repo.transact(fn ->
        with {:ok, user} <- Repo.update(User.confirm_changeset(user)),
             {_count, _} <-
               Repo.delete_all(
                 from(t in UserToken, where: t.user_id == ^user.id and t.context == "confirm")
               ) do
          _ = token_row
          {:ok, user}
        end
      end)
      |> case do
        {:ok, user} ->
          UserNotifier.deliver_account_ready(user, login_url)
          {:ok, user}

        error ->
          error
      end
    else
      _ -> {:error, :invalid_token}
    end
  end

  def delete_user_session_token(token) do
    Repo.delete_all(from(UserToken, where: [token: ^token, context: "session"]))
    :ok
  end

  defp update_user_and_delete_all_tokens(changeset) do
    Repo.transact(fn ->
      with {:ok, user} <- Repo.update(changeset) do
        tokens_to_expire = Repo.all_by(UserToken, user_id: user.id)

        Repo.delete_all(from(t in UserToken, where: t.id in ^Enum.map(tokens_to_expire, & &1.id)))

        {:ok, {user, tokens_to_expire}}
      end
    end)
  end
end
