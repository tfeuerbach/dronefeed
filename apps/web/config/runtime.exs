import Config

# config/runtime.exs is executed for all environments, including
# during releases. It is executed after compilation and before the
# system starts, so it is typically used to load production configuration
# and secrets from environment variables or elsewhere. Do not define
# any compile-time configuration in here, as it won't be applied.
# The block below contains prod specific runtime configuration.

# ## Using releases
#
# If you use `mix release`, you need to explicitly enable the server
# by passing the PHX_SERVER=true when you start it:
#
#     PHX_SERVER=true bin/drone_feed start
#
# Alternatively, you can use `mix phx.gen.release` to generate a `bin/server`
# script that automatically sets the env var above.
if System.get_env("PHX_SERVER") do
  config :drone_feed, DroneFeedWeb.Endpoint, server: true
end

config :drone_feed, DroneFeedWeb.Endpoint,
  http: [port: String.to_integer(System.get_env("PORT", "4000"))]

if config_env() == :prod do
  host =
    System.get_env("PHX_HOST") ||
      raise """
      environment variable PHX_HOST is missing.
      Example: feeds.example.com
      """

  media_host =
    case System.get_env("MEDIA_HOST") do
      nil -> host
      "" -> host
      value -> value
    end

  # Best-effort public IPv4 via EC2 IMDSv2 when MEDIA_IP is unset.
  # Note: often unreachable from Docker bridge networking — set MEDIA_IP explicitly.
  detect_public_ipv4 = fn ->
    _ = Application.ensure_all_started(:inets)
    http_opts = [timeout: 400, connect_timeout: 400]

    with {:ok, {{_, 200, _}, _, token_body}} <-
           :httpc.request(
             :put,
             {~c"http://169.254.169.254/latest/api/token",
              [{~c"X-aws-ec2-metadata-token-ttl-seconds", ~c"60"}], ~c"", []},
             http_opts,
             []
           ),
         token = token_body |> IO.iodata_to_binary() |> String.trim() |> String.to_charlist(),
         {:ok, {{_, 200, _}, _, ip_body}} <-
           :httpc.request(
             :get,
             {~c"http://169.254.169.254/latest/meta-data/public-ipv4",
              [{~c"X-aws-ec2-metadata-token", token}], ~c"", []},
             http_opts,
             []
           ) do
      ip_body |> IO.iodata_to_binary() |> String.trim()
    else
      _ -> nil
    end
  end

  media_ip =
    case System.get_env("MEDIA_IP") do
      v when is_binary(v) and v != "" -> v
      _ -> detect_public_ipv4.() || media_host
    end

  config :drone_feed,
    storage_root: System.get_env("STORAGE_ROOT") || "/var/lib/drone-feed/storage",
    media_host: media_host,
    media_ip: media_ip,
    web_host: host,
    web_scheme: "https",
    web_port: 443,
    rtmp_port: String.to_integer(System.get_env("RTMP_PORT") || "1935"),
    rtsp_port: String.to_integer(System.get_env("RTSP_PORT") || "8554"),
    srt_port: String.to_integer(System.get_env("SRT_PORT") || "8890"),
    mediamtx_rtmp_url: System.get_env("MEDIAMTX_RTMP_URL") || "rtmp://mediamtx:1935",
    mediamtx_rtsp_url: System.get_env("MEDIAMTX_RTSP_URL") || "rtsp://mediamtx:8554",
    mediamtx_api_url: System.get_env("MEDIAMTX_API_URL") || "http://mediamtx:9997",
    mediamtx_host: System.get_env("MEDIAMTX_HOST") || "mediamtx",
    mediamtx_api_enabled: System.get_env("MEDIAMTX_API_ENABLED", "true") not in ~w(false 0 no),
    udp_ingest_port_min: String.to_integer(System.get_env("UDP_INGEST_PORT_MIN") || "8900"),
    udp_ingest_port_max: String.to_integer(System.get_env("UDP_INGEST_PORT_MAX") || "8999"),
    ffmpeg_path: System.get_env("FFMPEG_PATH") || System.find_executable("ffmpeg") || "ffmpeg",
    retention_days: String.to_integer(System.get_env("RETENTION_DAYS") || "5"),
    show_dev_login_hint: false,
    admin_contact:
      System.get_env("ADMIN_CONTACT") || "your system administrator",
    mux_script: System.get_env("MUX_SCRIPT") || "/app/scripts/mux_to_stanag.py",
    extract_klv_script:
      System.get_env("EXTRACT_KLV_SCRIPT") || "/app/scripts/extract_klv_track.py",
    python_path: System.get_env("PYTHON_PATH") || System.find_executable("python3") || "python3"

  database_url =
    System.get_env("DATABASE_URL") ||
      raise """
      environment variable DATABASE_URL is missing.
      For example: ecto://USER:PASS@HOST/DATABASE
      """

  maybe_ipv6 = if System.get_env("ECTO_IPV6") in ~w(true 1), do: [:inet6], else: []

  config :drone_feed, DroneFeed.Repo,
    url: database_url,
    pool_size: String.to_integer(System.get_env("POOL_SIZE") || "10"),
    socket_options: maybe_ipv6

  secret_key_base =
    System.get_env("SECRET_KEY_BASE") ||
      raise """
      environment variable SECRET_KEY_BASE is missing.
      You can generate one by calling: mix phx.gen.secret
      """

  config :drone_feed, :dns_cluster_query, System.get_env("DNS_CLUSTER_QUERY")

  config :drone_feed, DroneFeedWeb.Endpoint,
    url: [host: host, port: 443, scheme: "https"],
    http: [ip: {0, 0, 0, 0}, port: String.to_integer(System.get_env("PORT", "4000"))],
    secret_key_base: secret_key_base,
    check_origin: ["https://#{host}"]

  mail_from_name =
    System.get_env("SMTP_FROM_NAME") || System.get_env("MAIL_FROM_NAME") || "DroneFeed"

  mail_from_address =
    System.get_env("SMTP_FROM_EMAIL") ||
      System.get_env("MAIL_FROM_ADDRESS") ||
      "dronefeed@tfeuerbach.dev"

  config :drone_feed, mail_from: {mail_from_name, mail_from_address}

  smtp_relay = System.get_env("SMTP_HOST") || System.get_env("SMTP_RELAY")
  smtp_username = System.get_env("SMTP_USER") || System.get_env("SMTP_USERNAME")
  smtp_password = System.get_env("SMTP_PASSWORD")

  smtp_configured? =
    is_binary(smtp_relay) and String.trim(smtp_relay) != "" and
      is_binary(smtp_username) and String.trim(smtp_username) != "" and
      is_binary(smtp_password) and String.trim(smtp_password) != ""

  if smtp_configured? do
    # Port 465 = implicit SSL; 587 = STARTTLS (SMTP_USE_TLS=true).
    use_ssl = System.get_env("SMTP_SSL") in ~w(true 1)
    use_tls = System.get_env("SMTP_USE_TLS", "true") in ~w(true 1)

    tls_opt =
      cond do
        use_ssl -> :never
        use_tls -> :always
        true -> :never
      end

    mailer =
      [
        adapter: Swoosh.Adapters.SMTP,
        relay: smtp_relay,
        username: smtp_username,
        password: smtp_password,
        port: String.to_integer(System.get_env("SMTP_PORT") || "587"),
        ssl: use_ssl,
        tls: tls_opt,
        auth: :always,
        retries: 2
      ]

    mailer =
      if tls_opt == :always do
        Keyword.put(mailer, :tls_options, [
          versions: [:"tlsv1.2", :"tlsv1.3"],
          verify: :verify_peer,
          cacerts: :public_key.cacerts_get(),
          server_name_indication: String.to_charlist(smtp_relay),
          depth: 99
        ])
      else
        mailer
      end

    config :drone_feed, DroneFeed.Mailer, mailer
  else
    IO.puts(:stderr, "SMTP_* not fully set; outbound email disabled (Local adapter)")

    config :drone_feed, DroneFeed.Mailer, adapter: Swoosh.Adapters.Local
  end
end
