defmodule DroneFeedWeb.UserLive.Settings do
  use DroneFeedWeb, :live_view

  on_mount {DroneFeedWeb.UserAuth, :require_sudo_mode}

  alias DroneFeed.Accounts
  alias DroneFeed.Accounts.ApiToken

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <div class="df-settings space-y-8">
        <.header>
          Account settings
          <:subtitle>
            Signed in as <span class="font-mono text-sm">{@current_email}</span>.
            Email changes are handled by an administrator.
          </:subtitle>
        </.header>

        <div class="df-panel space-y-4">
          <h2 class="text-sm font-semibold uppercase tracking-wide text-base-content/50">
            Password
          </h2>
          <.form
            for={@password_form}
            id="password_form"
            action={~p"/users/update-password"}
            method="post"
            phx-change="validate_password"
            phx-submit="update_password"
            phx-trigger-action={@trigger_submit}
            class="space-y-3"
          >
            <input
              name={@password_form[:email].name}
              type="hidden"
              id="hidden_user_email"
              spellcheck="false"
              value={@current_email}
            />
            <.input
              field={@password_form[:password]}
              type="password"
              label="New password"
              autocomplete="new-password"
              spellcheck="false"
              required
            />
            <p class="df-field-hint -mt-1 mb-2">
              At least 8 characters, with one number and one symbol.
            </p>
            <.input
              field={@password_form[:password_confirmation]}
              type="password"
              label="Confirm new password"
              autocomplete="new-password"
              spellcheck="false"
            />
            <.button variant="primary" phx-disable-with="Saving...">
              Save password
            </.button>
          </.form>
        </div>

        <div class="df-panel df-api-tokens space-y-5">
          <div class="space-y-1">
            <h2 class="text-sm font-semibold uppercase tracking-wide text-base-content/50">
              API tokens
            </h2>
            <p class="text-sm text-base-content/60">
              Programmatic access for curl / wget / scripts against
              <span class="font-mono text-xs">/api/v1/*</span>.
              Up to {@max_tokens} tokens per account · each expires after 1 year.
            </p>
          </div>

          <div
            :if={@new_token_plaintext}
            class="df-api-token-reveal space-y-2"
            id="api-token-reveal"
          >
            <p class="text-sm font-medium text-warning">
              Copy this token now — it won’t be shown again.
            </p>
            <div
              id="api-token-copy"
              class="flex flex-wrap items-center gap-2"
              phx-hook="CopyField"
              data-copy-value={@new_token_plaintext}
            >
              <input
                type="text"
                readonly
                class="df-api-token-value input input-bordered font-mono text-xs"
                value={@new_token_plaintext}
              />
              <button type="button" class="btn btn-sm" data-copy-btn>Copy</button>
              <button type="button" class="btn btn-sm btn-ghost" phx-click="dismiss_new_token">
                Dismiss
              </button>
            </div>
          </div>

          <.form
            :if={length(@api_tokens) < @max_tokens}
            for={@token_form}
            id="api-token-form"
            phx-submit="create_api_token"
            phx-change="validate_api_token"
            class="df-api-token-form"
          >
            <div class="df-api-token-form-field">
              <.input
                field={@token_form[:name]}
                type="text"
                label="Token name"
                placeholder="CI laptop"
                required
                class="w-full input"
              />
            </div>
            <.button
              variant="primary"
              class="btn btn-primary df-api-token-form-submit"
              phx-disable-with="Creating…"
            >
              Create token
            </.button>
          </.form>
          <p
            :if={length(@api_tokens) >= @max_tokens}
            class="text-sm text-base-content/55"
          >
            Token limit reached ({@max_tokens}). Revoke one to create another.
          </p>

          <ul :if={@api_tokens != []} class="df-api-token-list">
            <li
              :for={token <- @api_tokens}
              id={"api-token-#{token.id}"}
              class="df-api-token-row"
            >
              <div class="min-w-0 flex-1 space-y-0.5">
                <p class="truncate font-medium">{token.name}</p>
                <p class="font-mono text-xs text-base-content/50">
                  {token.prefix}… · created {Calendar.strftime(token.inserted_at, "%Y-%m-%d")}
                  · expires {Calendar.strftime(token.expires_at, "%Y-%m-%d")}
                  <span :if={token.last_used_at}>
                    · last used {Calendar.strftime(token.last_used_at, "%Y-%m-%d %H:%M")}
                  </span>
                  <span :if={ApiToken.expired?(token)} class="text-error"> · expired</span>
                </p>
              </div>
              <button
                type="button"
                class="btn btn-ghost btn-sm text-error shrink-0"
                phx-click="revoke_api_token"
                phx-value-id={token.id}
                data-confirm={"Revoke token “#{token.name}”? Scripts using it will stop working."}
              >
                Revoke
              </button>
            </li>
          </ul>
          <p :if={@api_tokens == []} class="text-sm text-base-content/50">
            No API tokens yet.
          </p>

          <div class="df-api-examples space-y-2 border-t border-base-content/10 pt-4">
            <p class="text-xs font-semibold uppercase tracking-wide text-base-content/45">
              Examples
            </p>
            <pre class="df-api-example">{@curl_example}</pre>
            <pre class="df-api-example">{@wget_example}</pre>
          </div>
        </div>
      </div>
    </Layouts.app>
    """
  end

  @impl true
  def mount(_params, _session, socket) do
    user = socket.assigns.current_scope.user
    password_changeset = Accounts.change_user_password(user, %{}, hash_password: false)

    {:ok,
     socket
     |> assign(:page_title, "Settings")
     |> assign(:current_email, user.email)
     |> assign(:password_form, to_form(password_changeset))
     |> assign(:trigger_submit, false)
     |> assign(:api_tokens, Accounts.list_api_tokens(user))
     |> assign(:token_form, to_form(Accounts.change_api_token(%ApiToken{})))
     |> assign(:new_token_plaintext, nil)
     |> assign(:max_tokens, ApiToken.max_per_user())
     |> assign(:api_base, api_base())
     |> assign_api_examples()}
  end

  defp assign_api_examples(socket) do
    base = socket.assigns.api_base

    socket
    |> assign(
      :curl_example,
      ~s|curl -sS -H "Authorization: Bearer $DF_TOKEN" #{base}/api/v1/feeds|
    )
    |> assign(
      :wget_example,
      ~s|wget -qO- --header="X-Api-Key: $DF_TOKEN" #{base}/api/v1/flights|
    )
  end

  @impl true
  def handle_event("validate_password", params, socket) do
    %{"user" => user_params} = params

    password_form =
      socket.assigns.current_scope.user
      |> Accounts.change_user_password(user_params, hash_password: false)
      |> Map.put(:action, :validate)
      |> to_form()

    {:noreply, assign(socket, password_form: password_form)}
  end

  def handle_event("update_password", params, socket) do
    %{"user" => user_params} = params
    user = socket.assigns.current_scope.user
    true = Accounts.sudo_mode?(user)

    case Accounts.change_user_password(user, user_params) do
      %{valid?: true} = changeset ->
        {:noreply, assign(socket, trigger_submit: true, password_form: to_form(changeset))}

      changeset ->
        {:noreply, assign(socket, password_form: to_form(changeset, action: :insert))}
    end
  end

  def handle_event("validate_api_token", %{"api_token" => params}, socket) do
    form =
      %ApiToken{}
      |> Accounts.change_api_token(params)
      |> Map.put(:action, :validate)
      |> to_form()

    {:noreply, assign(socket, token_form: form)}
  end

  def handle_event("create_api_token", %{"api_token" => params}, socket) do
    user = socket.assigns.current_scope.user

    case Accounts.create_api_token(user, params) do
      {:ok, token} ->
        {:noreply,
         socket
         |> assign(:api_tokens, Accounts.list_api_tokens(user))
         |> assign(:token_form, to_form(Accounts.change_api_token(%ApiToken{})))
         |> assign(:new_token_plaintext, token.plaintext)
         |> put_flash(:info, "API token created — copy it now")}

      {:error, :limit_reached} ->
        {:noreply,
         put_flash(
           socket,
           :error,
           "You can have at most #{ApiToken.max_per_user()} API tokens. Revoke one first."
         )}

      {:error, changeset} ->
        {:noreply, assign(socket, token_form: to_form(changeset, action: :insert))}
    end
  end

  def handle_event("revoke_api_token", %{"id" => id}, socket) do
    user = socket.assigns.current_scope.user

    case Accounts.revoke_api_token(user, id) do
      {:ok, _} ->
        {:noreply,
         socket
         |> assign(:api_tokens, Accounts.list_api_tokens(user))
         |> put_flash(:info, "API token revoked")}

      {:error, :not_found} ->
        {:noreply, put_flash(socket, :error, "Token not found")}
    end
  end

  def handle_event("dismiss_new_token", _params, socket) do
    {:noreply, assign(socket, :new_token_plaintext, nil)}
  end

  defp api_base do
    host = Application.get_env(:drone_feed, DroneFeedWeb.Endpoint)[:url][:host] || "localhost"
    scheme = if host in ["localhost", "127.0.0.1"], do: "http", else: "https"
    port = Application.get_env(:drone_feed, DroneFeedWeb.Endpoint)[:url][:port]

    cond do
      port in [80, 443, nil] -> "#{scheme}://#{host}"
      true -> "#{scheme}://#{host}:#{port}"
    end
  end
end
