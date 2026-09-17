defmodule DroneFeedWeb.AdminLive.Index do
  use DroneFeedWeb, :live_view

  alias DroneFeed.Accounts
  alias DroneFeed.Accounts.User

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} main_class="df-main--wide">
      <div class="df-reveal space-y-10">
        <.header>
          Admin
          <:subtitle>
            Approve account requests, manage roles, and review inbox notifications.
          </:subtitle>
          <:actions>
            <button
              :if={@unread_count > 0}
              type="button"
              class="btn btn-ghost btn-sm"
              phx-click="mark_all_read"
            >
              Mark inbox read
            </button>
          </:actions>
        </.header>

        <section class="df-reveal-item space-y-3" style="--df-i: 0">
          <h2 class="df-section-label">
            Inbox
            <span :if={@unread_count > 0} class="df-count-pill">{@unread_count}</span>
          </h2>

          <div class="df-panel df-admin-panel overflow-hidden p-0">
            <div
              :if={@notifications == []}
              class="px-5 py-10 text-center text-sm text-base-content/50"
            >
              No notifications yet.
            </div>
            <article
              :for={{n, i} <- Enum.with_index(@notifications)}
              class={[
                "df-admin-row df-reveal-item",
                is_nil(n.read_at) && "df-admin-row--unread"
              ]}
              style={"--df-i: #{i + 1}"}
            >
              <div class="df-admin-col df-admin-col--id min-w-0">
                <div class="flex flex-wrap items-center gap-2">
                  <span
                    :if={is_nil(n.read_at)}
                    class="inline-block size-1.5 shrink-0 rounded-full bg-primary"
                    title="Unread"
                  />
                  <h3 class="truncate font-medium text-base-content">{n.title}</h3>
                </div>
                <p class="truncate text-sm text-base-content/65">{n.body}</p>
              </div>

              <div class="df-admin-col df-admin-col--status">
                <span
                  :if={n.subject_user}
                  class={status_pill_class(n.subject_user.status)}
                  title={human_status(n.subject_user.status)}
                >
                  {short_status(n.subject_user.status)}
                </span>
              </div>

              <div class="df-admin-col df-admin-col--role">
                <%= if n.kind == "account_request" && n.subject_user &&
                         n.subject_user.status == "pending_approval" do %>
                  <form id={"inbox-approve-#{n.id}"} phx-submit="approve" class="contents">
                    <input type="hidden" name="user_id" value={n.subject_user.id} />
                    <select
                      name="role"
                      form={"inbox-approve-#{n.id}"}
                      class="df-role-select"
                      aria-label="Assign group on approval"
                    >
                      <option value="user" selected>User</option>
                      <option value="admin">Admin</option>
                    </select>
                  </form>
                <% end %>
              </div>

              <div class="df-admin-col df-admin-col--actions">
                <%= if n.kind == "account_request" && n.subject_user &&
                         n.subject_user.status == "pending_approval" do %>
                  <button type="submit" form={"inbox-approve-#{n.id}"} class="btn btn-primary btn-sm">
                    Approve
                  </button>
                  <button
                    type="button"
                    class="btn btn-ghost btn-sm text-error"
                    phx-click="reject"
                    phx-value-user_id={n.subject_user.id}
                    data-confirm="Reject this account request?"
                  >
                    Reject
                  </button>
                <% else %>
                  <button
                    :if={is_nil(n.read_at)}
                    type="button"
                    class="btn btn-ghost btn-sm"
                    phx-click="mark_read"
                    phx-value-id={n.id}
                  >
                    Mark read
                  </button>
                <% end %>
              </div>

              <div class="df-admin-col df-admin-col--meta">
                <span class="df-admin-meta">{format_dt(n.inserted_at)}</span>
              </div>
            </article>
          </div>
        </section>

        <section class="df-reveal-item space-y-3" style="--df-i: 1">
          <h2 class="df-section-label">
            Pending approval
            <span :if={@pending != []} class="df-count-pill">{length(@pending)}</span>
          </h2>

          <div class="df-panel df-admin-panel overflow-hidden p-0">
            <div
              :if={@pending == []}
              class="px-5 py-10 text-center text-sm text-base-content/50"
            >
              No pending requests.
            </div>
            <article
              :for={{user, i} <- Enum.with_index(@pending)}
              class="df-admin-row df-reveal-item"
              style={"--df-i: #{i + 2}"}
            >
              <div class="df-admin-col df-admin-col--id min-w-0">
                <p class="truncate font-medium text-base-content">{User.display_name(user)}</p>
                <p class="truncate font-mono text-xs text-base-content/55">{user.email}</p>
                <p class="truncate text-xs text-base-content/45">
                  {user.organization}
                  <span class="text-base-content/30">·</span>
                  {user.location}
                </p>
              </div>

              <div class="df-admin-col df-admin-col--status">
                <span class={status_pill_class(user.status)} title={human_status(user.status)}>
                  {short_status(user.status)}
                </span>
              </div>

              <div class="df-admin-col df-admin-col--role">
                <form id={"pending-approve-#{user.id}"} phx-submit="approve" class="contents">
                  <input type="hidden" name="user_id" value={user.id} />
                  <select
                    name="role"
                    form={"pending-approve-#{user.id}"}
                    class="df-role-select"
                    aria-label="Assign group on approval"
                  >
                    <option value="user" selected>User</option>
                    <option value="admin">Admin</option>
                  </select>
                </form>
              </div>

              <div class="df-admin-col df-admin-col--actions">
                <button
                  type="submit"
                  form={"pending-approve-#{user.id}"}
                  class="btn btn-primary btn-sm"
                >
                  Approve
                </button>
                <button
                  type="button"
                  class="btn btn-ghost btn-sm text-error"
                  phx-click="reject"
                  phx-value-user_id={user.id}
                  data-confirm="Reject this account request?"
                >
                  Reject
                </button>
              </div>

              <div class="df-admin-col df-admin-col--meta">
                <span class="df-admin-meta">{format_dt(user.inserted_at)}</span>
              </div>
            </article>
          </div>
        </section>

        <section class="df-reveal-item space-y-3" style="--df-i: 2">
          <h2 class="df-section-label">Users</h2>

          <div class="df-panel df-admin-panel overflow-hidden p-0">
            <div class="df-admin-row df-admin-row--head">
              <div class="df-admin-col df-admin-col--id">User</div>
              <div class="df-admin-col df-admin-col--status">Status</div>
              <div class="df-admin-col df-admin-col--role">Group</div>
              <div class="df-admin-col df-admin-col--actions">Actions</div>
              <div class="df-admin-col df-admin-col--meta">Joined</div>
            </div>

            <article
              :for={{user, i} <- Enum.with_index(@users)}
              class="df-admin-row df-reveal-item"
              style={"--df-i: #{i + 3}"}
            >
              <div class="df-admin-col df-admin-col--id min-w-0">
                <p class="truncate font-medium">{User.display_name(user)}</p>
                <p class="truncate font-mono text-xs text-base-content/50">{user.email}</p>
                <p class="truncate text-xs text-base-content/45">
                  {user.organization || "—"}
                </p>
              </div>

              <div class="df-admin-col df-admin-col--status">
                <span class={status_pill_class(user.status)} title={human_status(user.status)}>
                  {short_status(user.status)}
                </span>
              </div>

              <div class="df-admin-col df-admin-col--role">
                <form phx-change="set_role" class="m-0 contents">
                  <input type="hidden" name="user_id" value={user.id} />
                  <label class="sr-only" for={"role-#{user.id}"}>Group</label>
                  <select
                    id={"role-#{user.id}"}
                    name="role"
                    class="df-role-select"
                    disabled={user.id == @current_scope.user.id}
                    title={
                      if(user.id == @current_scope.user.id,
                        do: "You cannot change your own group",
                        else: "Change group"
                      )
                    }
                  >
                    <option value="user" selected={user.role == "user"}>User</option>
                    <option value="admin" selected={user.role == "admin"}>Admin</option>
                  </select>
                </form>
              </div>

              <div class="df-admin-col df-admin-col--actions" aria-hidden="true"></div>

              <div class="df-admin-col df-admin-col--meta">
                <span class="df-admin-meta">{format_dt(user.inserted_at)}</span>
              </div>
            </article>
          </div>
        </section>
      </div>
    </Layouts.app>
    """
  end

  defp format_dt(nil), do: "—"

  defp format_dt(%DateTime{} = dt) do
    Calendar.strftime(dt, "%Y-%m-%d %H:%M UTC")
  end

  defp human_status("pending_approval"), do: "Pending approval"
  defp human_status("pending_verification"), do: "Pending verification"
  defp human_status("active"), do: "Active"
  defp human_status("rejected"), do: "Rejected"
  defp human_status(other), do: other

  defp short_status("pending_approval"), do: "Pending"
  defp short_status("pending_verification"), do: "Verify"
  defp short_status("active"), do: "Active"
  defp short_status("rejected"), do: "Rejected"
  defp short_status(other), do: other

  defp status_pill_class("active"), do: "df-status df-status--active"
  defp status_pill_class("pending_approval"), do: "df-status df-status--pending"
  defp status_pill_class("pending_verification"), do: "df-status df-status--verify"
  defp status_pill_class("rejected"), do: "df-status df-status--rejected"
  defp status_pill_class(_), do: "df-status"

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: Accounts.subscribe_admin_inbox()

    {:ok,
     socket
     |> assign(:page_title, "Admin")
     |> refresh_admin_assigns()}
  end

  @impl true
  def handle_info({:admin_inbox_updated, _}, socket) do
    {:noreply, refresh_admin_assigns(socket)}
  end

  @impl true
  def handle_event("mark_read", %{"id" => id}, socket) do
    notification = Enum.find(socket.assigns.notifications, &(&1.id == id))

    if notification do
      Accounts.mark_notification_read(notification)
    end

    {:noreply, refresh_admin_assigns(socket)}
  end

  def handle_event("mark_all_read", _params, socket) do
    Accounts.mark_all_notifications_read()
    {:noreply, refresh_admin_assigns(socket)}
  end

  def handle_event("approve", %{"user_id" => id} = params, socket) do
    admin = socket.assigns.current_scope.user
    user = Accounts.get_user!(id)
    role = Map.get(params, "role", "user")

    case Accounts.approve_account(admin, user,
           role: role,
           verify_url_fun: &url(~p"/users/verify/#{&1}")
         ) do
      {:ok, user} ->
        {:noreply,
         socket
         |> put_flash(:info, "Approved #{User.display_name(user)}. Verification email sent.")
         |> refresh_admin_assigns()}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Could not approve that account.")}
    end
  end

  def handle_event("reject", %{"user_id" => id}, socket) do
    admin = socket.assigns.current_scope.user
    user = Accounts.get_user!(id)

    case Accounts.reject_account(admin, user) do
      {:ok, user} ->
        {:noreply,
         socket
         |> put_flash(:info, "Rejected #{User.display_name(user)}.")
         |> refresh_admin_assigns()}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Could not reject that account.")}
    end
  end

  def handle_event("set_role", %{"user_id" => id, "role" => role}, socket) do
    admin = socket.assigns.current_scope.user
    user = Accounts.get_user!(id)

    case Accounts.update_user_role(admin, user, role) do
      {:ok, user} ->
        {:noreply,
         socket
         |> put_flash(:info, "Updated #{User.display_name(user)} to #{role}.")
         |> refresh_admin_assigns()}

      {:error, :cannot_demote_self} ->
        {:noreply, put_flash(socket, :error, "You cannot remove your own admin role.")}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Could not update role.")}
    end
  end

  defp refresh_admin_assigns(socket) do
    socket
    |> assign(:notifications, Accounts.list_admin_notifications())
    |> assign(:unread_count, Accounts.count_unread_admin_notifications())
    |> assign(:pending, Accounts.list_pending_approval_users())
    |> assign(:users, Accounts.list_users())
  end
end
