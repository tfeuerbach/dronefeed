defmodule DroneFeed.Accounts.UserNotifier do
  @moduledoc false

  import Swoosh.Email

  alias DroneFeed.Mailer
  alias DroneFeed.Accounts.User

  @ink "#0F1419"
  @slate "#1C2430"
  @slate_border "#2A3444"
  @fog "#E8EDF2"
  @paper "#F4F7FA"
  @signal "#0D9F8F"
  @signal_deep "#042A26"
  @mute "#64748B"
  @body "#C5CED8"

  defp mail_from do
    Application.get_env(:drone_feed, :mail_from, {"DroneFeed", "dronefeed@tfeuerbach.dev"})
  end

  defp site_url do
    cond do
      url = Application.get_env(:drone_feed, :public_url) ->
        String.trim_trailing(url, "/")

      host = System.get_env("PHX_HOST") ->
        if host in [nil, "", "localhost"] do
          "http://localhost:4000"
        else
          "https://" <> host
        end

      true ->
        "http://localhost:4000"
    end
  end

  defp deliver(recipient, subject, text_body, html_body) do
    email =
      new()
      |> to(recipient)
      |> from(mail_from())
      |> subject(subject)
      |> text_body(text_body)
      |> html_body(html_body)

    with {:ok, _metadata} <- Mailer.deliver(email) do
      {:ok, email}
    end
  end

  defp wrap_html(title, inner, opts) do
    preheader = Keyword.get(opts, :preheader, title)

    """
    <!DOCTYPE html>
    <html lang="en" xmlns="http://www.w3.org/1999/xhtml">
    <head>
      <meta charset="utf-8" />
      <meta name="viewport" content="width=device-width, initial-scale=1" />
      <meta name="color-scheme" content="dark light" />
      <meta name="supported-color-schemes" content="dark light" />
      <title>#{escape(title)} · DroneFeed</title>
      <!--[if mso]>
      <style type="text/css">
        body, table, td { font-family: Arial, sans-serif !important; }
      </style>
      <![endif]-->
      <style type="text/css">
        @import url('https://fonts.googleapis.com/css2?family=IBM+Plex+Mono:wght@400;500&family=Sora:wght@400;500;600;700&display=swap');
        body { margin: 0 !important; padding: 0 !important; }
        a { color: #{@signal}; }
        @media (prefers-color-scheme: light) {
          .df-shell { background: #E8EDF2 !important; }
          .df-card { background: #F4F7FA !important; border-color: #D5DEE8 !important; }
          .df-title { color: #0F1419 !important; }
          .df-body { color: #3A4656 !important; }
          .df-mute { color: #64748B !important; }
          .df-strong { color: #0F1419 !important; }
          .df-rule { border-color: #D5DEE8 !important; }
          .df-meta-box { background: #E8EDF2 !important; border-color: #D5DEE8 !important; }
        }
      </style>
    </head>
    <body style="margin:0;padding:0;background:#{@ink};font-family:'Sora',ui-sans-serif,system-ui,-apple-system,'Segoe UI',Roboto,Helvetica,Arial,sans-serif;color:#{@fog};-webkit-font-smoothing:antialiased;">
      <div style="display:none;max-height:0;overflow:hidden;mso-hide:all;">
        #{escape(preheader)}&nbsp;&zwnj;&nbsp;&zwnj;&nbsp;&zwnj;&nbsp;&zwnj;&nbsp;&zwnj;
      </div>
      <table role="presentation" class="df-shell" width="100%" cellspacing="0" cellpadding="0" style="background:#{@ink};padding:40px 16px;">
        <tr>
          <td align="center">
            <table role="presentation" class="df-card" width="100%" cellspacing="0" cellpadding="0" style="max-width:560px;background:#{@slate};border:1px solid #{@slate_border};border-radius:8px;overflow:hidden;">
              <tr>
                <td style="height:3px;line-height:3px;font-size:0;background:#{@signal};">&nbsp;</td>
              </tr>
              <tr>
                <td style="padding:24px 28px 20px;border-bottom:1px solid #{@slate_border};" class="df-rule">
                  <table role="presentation" width="100%" cellspacing="0" cellpadding="0">
                    <tr>
                      <td valign="middle" width="40" style="padding-right:12px;">
                        <table role="presentation" cellspacing="0" cellpadding="0" width="32" height="32" style="width:32px;height:32px;border-collapse:collapse;">
                          <tr>
                            <td width="32" height="32" bgcolor="#2a9d8f" style="width:32px;height:32px;background-color:#2a9d8f;background:linear-gradient(135deg,#2a9d8f,#3a4f6a);border-radius:6px;text-align:right;vertical-align:bottom;padding:0 5px 5px 0;">
                              <span style="display:inline-block;width:11px;height:10px;background:#f4fbf9;border-radius:2px;font-size:0;line-height:0;">&nbsp;</span>
                            </td>
                          </tr>
                        </table>
                      </td>
                      <td valign="middle">
                        <div style="font-size:15px;font-weight:600;letter-spacing:-0.01em;color:#{@paper};" class="df-title">DroneFeed</div>
                        <div style="margin-top:2px;font-size:11px;letter-spacing:0.08em;text-transform:uppercase;color:#{@signal};font-weight:600;">Research flight feeds</div>
                      </td>
                    </tr>
                  </table>
                  <div class="df-title" style="margin-top:22px;font-size:22px;font-weight:600;letter-spacing:-0.02em;line-height:1.25;color:#{@paper};">#{escape(title)}</div>
                </td>
              </tr>
              <tr>
                <td class="df-body" style="padding:28px;font-size:15px;line-height:1.65;color:#{@body};">
                  #{inner}
                </td>
              </tr>
              <tr>
                <td class="df-mute df-rule" style="padding:18px 28px;border-top:1px solid #{@slate_border};font-size:12px;line-height:1.5;color:#{@mute};">
                  DroneFeed · research flight ingest &amp; public feeds<br/>
                  <span style="font-family:'IBM Plex Mono',ui-monospace,monospace;font-size:11px;">#{escape(site_url())}</span>
                </td>
              </tr>
            </table>
            <p class="df-mute" style="margin:20px 0 0;font-size:11px;line-height:1.5;color:#{@mute};text-align:center;max-width:560px;">
              This message was sent by an automated system. If you did not expect it, you can ignore it.
            </p>
          </td>
        </tr>
      </table>
    </body>
    </html>
    """
  end

  defp cta(url, label) do
    """
    <table role="presentation" cellspacing="0" cellpadding="0" style="margin:28px 0 12px;">
      <tr>
        <td align="center" bgcolor="#{@signal}" style="border-radius:6px;background:#{@signal};">
          <a href="#{url}" style="display:inline-block;padding:12px 22px;font-family:'Sora',ui-sans-serif,system-ui,sans-serif;font-size:14px;font-weight:600;line-height:1.2;color:#{@signal_deep};text-decoration:none;border-radius:6px;">
            #{escape(label)}
          </a>
        </td>
      </tr>
    </table>
    <p class="df-mute" style="margin:0;font-size:12px;line-height:1.5;color:#{@mute};">
      Or open this link:<br/>
      <a href="#{url}" style="color:#{@signal};font-family:'IBM Plex Mono',ui-monospace,monospace;font-size:11px;word-break:break-all;text-decoration:none;">#{escape(url)}</a>
    </p>
    """
  end

  defp meta_rows(rows) do
    items =
      Enum.map_join(rows, "", fn {label, value} ->
        """
        <tr>
          <td style="padding:10px 14px;border-bottom:1px solid #{@slate_border};font-size:12px;letter-spacing:0.06em;text-transform:uppercase;color:#{@mute};width:38%;" class="df-mute df-rule">#{escape(label)}</td>
          <td style="padding:10px 14px;border-bottom:1px solid #{@slate_border};font-size:14px;color:#{@fog};font-family:'IBM Plex Mono',ui-monospace,monospace;" class="df-strong df-rule">#{escape(value)}</td>
        </tr>
        """
      end)

    """
    <table role="presentation" class="df-meta-box" cellspacing="0" cellpadding="0" style="margin:20px 0;width:100%;background:#{@ink};border:1px solid #{@slate_border};border-radius:6px;overflow:hidden;">
      #{items}
    </table>
    """
  end

  def deliver_admin_account_request(%User{} = requester, admin_email, review_url)
      when is_binary(admin_email) do
    name = User.display_name(requester)

    text = """
    DroneFeed — new account request

    #{name} (#{requester.email}) requested access.

    Organization: #{requester.organization}
    Location: #{requester.location}

    Review and approve in the admin console:
    #{review_url}

    Accounts are approved before a verification email is sent to the requester.
    """

    html =
      wrap_html(
        "New account request",
        """
        <p style="margin:0 0 12px;"><strong class="df-strong" style="color:#{@paper};">#{escape(name)}</strong>
        <span class="df-mute" style="color:#{@mute};">·</span>
        <span style="font-family:'IBM Plex Mono',ui-monospace,monospace;font-size:13px;color:#{@signal};">#{escape(requester.email)}</span></p>
        #{meta_rows([
          {"Organization", requester.organization},
          {"Location", requester.location}
        ])}
        <p style="margin:0;">Approve the request in the admin console first. Only then will the requester receive a verification email.</p>
        #{cta(review_url, "Open admin inbox")}
        """,
        preheader: "#{name} requested DroneFeed access"
      )

    deliver(admin_email, "DroneFeed: account request from #{name}", text, html)
  end

  def deliver_verification_instructions(%User{} = user, url) do
    name = User.display_name(user)

    text = """
    DroneFeed — verify your email

    Hi #{name},

    An administrator approved your DroneFeed account request.
    Confirm your email to finish setup and start uploading flights:

    #{url}

    If you did not request this account, you can ignore this message.
    """

    html =
      wrap_html(
        "Verify your email",
        """
        <p style="margin:0 0 14px;">Hi #{escape(name)},</p>
        <p style="margin:0;">An administrator approved your DroneFeed account request. Confirm your email to finish setup — you will be able to log in and upload flights after verification.</p>
        #{cta(url, "Verify email")}
        <p class="df-mute" style="margin:24px 0 0;font-size:13px;color:#{@mute};">If you did not request this account, you can ignore this message.</p>
        """,
        preheader: "Confirm your email to activate your DroneFeed account"
      )

    deliver(user.email, "Verify your DroneFeed account", text, html)
  end

  def deliver_account_ready(%User{} = user, login_url) do
    name = User.display_name(user)

    text = """
    DroneFeed — you're ready to log in

    Hi #{name},

    Your account has been approved and verified. You can log in and upload flights:

    #{login_url}

    Welcome aboard.
    """

    html =
      wrap_html(
        "You're ready to log in",
        """
        <p style="margin:0 0 14px;">Hi #{escape(name)},</p>
        <p style="margin:0;">Your account has been <strong style="color:#{@signal};">approved and verified</strong>. You can log in and upload research flights.</p>
        #{cta(login_url, "Log in to DroneFeed")}
        <p style="margin:24px 0 0;">Welcome aboard.</p>
        """,
        preheader: "Your DroneFeed account is ready"
      )

    deliver(user.email, "Your DroneFeed account is ready", text, html)
  end

  def deliver_account_rejected(%User{} = user, contact) do
    name = User.display_name(user)

    text = """
    DroneFeed — account request update

    Hi #{name},

    Your request for a DroneFeed account was not approved.
    If you believe this is a mistake, contact #{contact}.
    """

    html =
      wrap_html(
        "Account request update",
        """
        <p style="margin:0 0 14px;">Hi #{escape(name)},</p>
        <p style="margin:0 0 14px;">Your request for a DroneFeed account was not approved.</p>
        <p style="margin:0;">If you believe this is a mistake, contact <strong class="df-strong" style="color:#{@fog};">#{escape(contact)}</strong>.</p>
        """,
        preheader: "Update on your DroneFeed account request"
      )

    deliver(user.email, "DroneFeed account request update", text, html)
  end

  def deliver_update_email_instructions(user, url) do
    text = """
    Hi #{user.email},

    You can change your email by visiting:

    #{url}

    If you didn't request this change, ignore this message.
    """

    html =
      wrap_html(
        "Update email",
        """
        <p style="margin:0 0 14px;">Hi <span style="font-family:'IBM Plex Mono',ui-monospace,monospace;font-size:13px;color:#{@signal};">#{escape(user.email)}</span>,</p>
        <p style="margin:0;">You can change your email using the button below.</p>
        #{cta(url, "Update email")}
        """,
        preheader: "Confirm your new email address"
      )

    deliver(user.email, "Update email instructions", text, html)
  end

  def deliver_login_instructions(user, url) do
    case user do
      %User{confirmed_at: nil} -> deliver_verification_instructions(user, url)
      _ -> deliver_magic_link_instructions(user, url)
    end
  end

  defp deliver_magic_link_instructions(user, url) do
    text = """
    Hi #{user.email},

    Log in by visiting:

    #{url}

    If you didn't request this email, ignore it.
    """

    html =
      wrap_html(
        "Log in",
        """
        <p style="margin:0 0 14px;">Hi <span style="font-family:'IBM Plex Mono',ui-monospace,monospace;font-size:13px;color:#{@signal};">#{escape(user.email)}</span>,</p>
        <p style="margin:0;">Use the button below to log in.</p>
        #{cta(url, "Log in")}
        """,
        preheader: "Your DroneFeed login link"
      )

    deliver(user.email, "Log in instructions", text, html)
  end

  defp escape(nil), do: ""

  defp escape(value) when is_binary(value) do
    value
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
    |> String.replace("\"", "&quot;")
  end
end
