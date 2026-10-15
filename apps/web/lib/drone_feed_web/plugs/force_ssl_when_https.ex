defmodule DroneFeedWeb.Plugs.ForceSslWhenHttps do
  @moduledoc """
  Optional Plug.SSL for on-box TLS (Caddy Let's Encrypt).

  Enable with `PHX_FORCE_SSL=true`. Do **not** enable behind CloudFront +
  `Caddyfile.http`: CloudFront already redirects HTTP→HTTPS, and origin `Host`
  is the EC2 public DNS — Plug.SSL would 301 to `https://ec2-…amazonaws.com`.

  `PHX_SCHEME=https` alone only affects URL generation (safe with edge TLS).
  """

  @behaviour Plug

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(conn, _opts) do
    case System.get_env("PHX_FORCE_SSL", "") |> String.downcase() do
      v when v in ["1", "true", "yes"] ->
        opts =
          Plug.SSL.init(
            rewrite_on: [:x_forwarded_proto],
            hsts: true,
            exclude: [
              hosts: ["localhost", "127.0.0.1", "web"],
              paths: ["/api/mediamtx/auth"]
            ]
          )

        Plug.SSL.call(conn, opts)

      _ ->
        conn
    end
  end
end
