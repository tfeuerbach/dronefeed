# This file is responsible for configuring your application
# and its dependencies with the aid of the Config module.
#
# This configuration file is loaded before any dependency and
# is restricted to this project.

# General application configuration
import Config

config :drone_feed, :scopes,
  user: [
    default: true,
    module: DroneFeed.Accounts.Scope,
    assign_key: :current_scope,
    access_path: [:user, :id],
    schema_key: :user_id,
    schema_type: :binary_id,
    schema_table: :users,
    test_data_fixture: DroneFeed.AccountsFixtures,
    test_setup_helper: :register_and_log_in_user
  ]

config :drone_feed,
  ecto_repos: [DroneFeed.Repo],
  generators: [timestamp_type: :utc_datetime, binary_id: true],
  dev_routes: false

# Configure the endpoint
config :drone_feed, DroneFeedWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [html: DroneFeedWeb.ErrorHTML, json: DroneFeedWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: DroneFeed.PubSub,
  live_view: [signing_salt: "8zMVerie"]

# Configure LiveView
config :phoenix_live_view,
  # the attribute set on all root tags. Used for Phoenix.LiveView.ColocatedCSS.
  root_tag_attribute: "phx-r"

# Configure esbuild (the version is required)
config :esbuild,
  version: "0.25.4",
  drone_feed: [
    args:
      ~w(js/app.js --bundle --target=es2022 --outdir=../priv/static/assets/js --external:/fonts/* --external:/images/* --alias:@=.),
    cd: Path.expand("../assets", __DIR__),
    env: %{"NODE_PATH" => [Path.expand("../deps", __DIR__), Mix.Project.build_path()]}
  ]

# Configure tailwind (the version is required)
config :tailwind,
  version: "4.3.0",
  drone_feed: [
    args: ~w(
      --input=assets/css/app.css
      --output=priv/static/assets/css/app.css
    ),
    cd: Path.expand("..", __DIR__),
    env: %{"NODE_PATH" => [Path.expand("../deps", __DIR__), Mix.Project.build_path()]}
  ]

# Configure Elixir's Logger
config :logger, :default_formatter,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

# Use Jason for JSON parsing in Phoenix
config :phoenix, :json_library, Jason

config :mime, :types, %{
  "video/x-matroska" => ["mkv"],
  "video/mp2t" => ["ts"],
  "application/octet-stream" => ["klv", "bin", "data"],
  "application/x-subrip" => ["srt"]
}

config :drone_feed, DroneFeed.Mailer, adapter: Swoosh.Adapters.Local

config :drone_feed,
  storage_root: Path.expand("../../../storage", __DIR__),
  retention_days: 5,
  media_host: "localhost",
  media_ip: "127.0.0.1",
  rtmp_port: 1935,
  rtsp_port: 8554,
  srt_port: 8890,
  hls_port: 8888,
  # Haivision/gosrt public pull (ms). ~2s ARQ headroom for WAN research tools.
  # Lower to 1000 on a very clean path; raise to 3000–4000 if you still see stalls.
  srt_pull_latency_ms: 2000,
  # FFmpeg→MediaMTX SRT publish (µs). Docker-local; keep buffers at SRT defaults.
  publish_srt_latency_us: 500_000,
  web_host: "localhost",
  web_scheme: "http",
  web_port: 4000,
  mediamtx_rtmp_url: "rtmp://127.0.0.1:1935",
  mediamtx_rtsp_url: "rtsp://127.0.0.1:8554",
  mediamtx_api_url: "http://127.0.0.1:9997",
  mediamtx_host: "127.0.0.1",
  mediamtx_api_enabled: true,
  udp_ingest_port_min: 8900,
  udp_ingest_port_max: 8999,
  ffmpeg_path: System.find_executable("ffmpeg") || "ffmpeg",
  mux_script: Path.expand("../../../scripts/mux_to_stanag.py", __DIR__),
  extract_klv_script: Path.expand("../../../scripts/extract_klv_track.py", __DIR__),
  python_path: System.find_executable("python3") || "python3",
  # Public-feed distribution encode — CBR-ish CFR for smooth SRT pulls.
  publish_video_height: 720,
  publish_video_bitrate: "2.5M",
  publish_video_maxrate: "2.5M",
  publish_video_bufsize: "5M",
  publish_gop: 30,
  publish_x264_preset: "veryfast",
  publish_x264_profile: "main",
  # Cross-origin iframe embeds (research tools). Override via env in prod.
  session_same_site: "Lax",
  session_cookie_secure: false,
  frame_ancestors: nil,
  show_dev_login_hint: false,
  admin_contact: "admin@example.com",
  mail_from: {"DroneFeed", "noreply@example.com"}

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"
