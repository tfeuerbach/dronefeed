defmodule DroneFeed.Accounts.User do
  use Ecto.Schema
  import Ecto.Changeset

  @roles ~w(user admin)
  @statuses ~w(pending_approval pending_verification active rejected)

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "users" do
    field :email, :string
    field :password, :string, virtual: true, redact: true
    field :password_confirmation, :string, virtual: true, redact: true
    field :hashed_password, :string, redact: true
    field :confirmed_at, :utc_datetime
    field :authenticated_at, :utc_datetime, virtual: true

    field :first_name, :string
    field :last_name, :string
    field :organization, :string
    field :location, :string
    field :role, :string, default: "user"
    field :status, :string, default: "pending_approval"
    field :approved_at, :utc_datetime

    belongs_to :approved_by, __MODULE__

    timestamps(type: :utc_datetime)
  end

  def roles, do: @roles
  def statuses, do: @statuses

  def admin?(%__MODULE__{role: "admin"}), do: true
  def admin?(_), do: false

  def active?(%__MODULE__{status: "active", confirmed_at: %DateTime{}}), do: true
  def active?(_), do: false

  def can_upload?(%__MODULE__{} = user), do: active?(user)

  def display_name(%__MODULE__{first_name: first, last_name: last, email: email}) do
    name = [first, last] |> Enum.reject(&(is_nil(&1) or &1 == "")) |> Enum.join(" ")
    if name == "", do: email, else: name
  end

  @doc """
  Changeset for a public account request (pending admin approval).
  """
  def account_request_changeset(user, attrs, opts \\ []) do
    user
    |> cast(attrs, [
      :email,
      :password,
      :password_confirmation,
      :first_name,
      :last_name,
      :organization,
      :location
    ])
    |> validate_required([
      :email,
      :password,
      :first_name,
      :last_name,
      :organization,
      :location
    ])
    |> validate_length(:first_name, min: 1, max: 80)
    |> validate_length(:last_name, min: 1, max: 80)
    |> validate_length(:organization, min: 1, max: 160)
    |> validate_length(:location, min: 1, max: 160)
    |> validate_confirmation(:password, message: "does not match password")
    |> validate_email(opts)
    |> validate_password(opts)
    |> put_change(:role, "user")
    |> put_change(:status, "pending_approval")
    |> put_change(:confirmed_at, nil)
  end

  @doc """
  A user changeset for registering or changing the email.

  ## Options

    * `:validate_unique` - Set to false if you don't want to validate the
      uniqueness of the email, useful when displaying live validations.
      Defaults to `true`.
  """
  def email_changeset(user, attrs, opts \\ []) do
    user
    |> cast(attrs, [:email])
    |> validate_email(opts)
  end

  defp validate_email(changeset, opts) do
    changeset =
      changeset
      |> validate_required([:email])
      |> validate_format(:email, ~r/^[^@,;\s]+@[^@,;\s]+$/,
        message: "must have the @ sign and no spaces"
      )
      |> validate_length(:email, max: 160)

    if Keyword.get(opts, :validate_unique, true) do
      changeset
      |> unsafe_validate_unique(:email, DroneFeed.Repo)
      |> unique_constraint(:email)
      |> validate_email_changed()
    else
      changeset
    end
  end

  defp validate_email_changed(changeset) do
    if get_field(changeset, :email) && get_change(changeset, :email) == nil do
      add_error(changeset, :email, "did not change")
    else
      changeset
    end
  end

  @doc """
  A user changeset for changing the password.

  ## Options

    * `:hash_password` - Hashes the password so it can be stored securely
      in the database and ensures the password field is cleared to prevent
      leaks in the logs. If password hashing is not needed and clearing the
      password field is not desired (like when using this changeset for
      validations on a LiveView form), this option can be set to `false`.
      Defaults to `true`.
  """
  def password_changeset(user, attrs, opts \\ []) do
    user
    |> cast(attrs, [:password])
    |> validate_confirmation(:password, message: "does not match password")
    |> validate_password(opts)
  end

  defp validate_password(changeset, opts) do
    changeset
    |> validate_required([:password])
    |> validate_length(:password, min: 12, max: 72)
    |> maybe_hash_password(opts)
  end

  defp maybe_hash_password(changeset, opts) do
    hash_password? = Keyword.get(opts, :hash_password, true)
    password = get_change(changeset, :password)

    if hash_password? && password && changeset.valid? do
      changeset
      |> validate_length(:password, max: 72, count: :bytes)
      |> put_change(:hashed_password, Bcrypt.hash_pwd_salt(password))
      |> delete_change(:password)
    else
      changeset
    end
  end

  def role_changeset(user, attrs) do
    user
    |> cast(attrs, [:role])
    |> validate_required([:role])
    |> validate_inclusion(:role, @roles)
  end

  def approve_changeset(user, admin, role \\ "user") do
    now = DateTime.utc_now(:second)

    user
    |> change(%{
      status: "pending_verification",
      role: role,
      approved_at: now,
      approved_by_id: admin.id
    })
    |> validate_inclusion(:role, @roles)
  end

  def reject_changeset(user) do
    change(user, status: "rejected", approved_at: nil, approved_by_id: nil)
  end

  @doc """
  Confirms the account by setting `confirmed_at` and marking status active.
  """
  def confirm_changeset(user) do
    now = DateTime.utc_now(:second)
    change(user, confirmed_at: now, status: "active")
  end

  @doc """
  Verifies the password.

  If there is no user or the user doesn't have a password, we call
  `Bcrypt.no_user_verify/0` to avoid timing attacks.
  """
  def valid_password?(%DroneFeed.Accounts.User{hashed_password: hashed_password}, password)
      when is_binary(hashed_password) and byte_size(password) > 0 do
    Bcrypt.verify_pass(password, hashed_password)
  end

  def valid_password?(_, _) do
    Bcrypt.no_user_verify()
    false
  end
end
