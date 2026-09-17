# Build from repository root: docker build -f deploy/Dockerfile .
FROM hexpm/elixir:1.18.4-erlang-27.3.4.16-debian-bookworm-20260824-slim AS build

RUN apt-get update -y && apt-get install -y build-essential git curl ca-certificates \
  && mix local.hex --force && mix local.rebar --force

ENV MIX_ENV=prod
WORKDIR /app

COPY apps/web/mix.exs apps/web/mix.lock ./
COPY apps/web/config config
RUN mix deps.get --only prod && mix deps.compile

COPY apps/web/priv priv
COPY apps/web/assets assets
COPY apps/web/lib lib

RUN mix compile \
  && mix assets.deploy \
  && mix release

FROM debian:bookworm-slim AS app

RUN apt-get update -y \
  && apt-get install -y openssl libncurses6 ffmpeg ca-certificates python3 python3-pip \
  && pip3 install --break-system-packages --no-cache-dir klvdata==0.0.3 \
  && rm -rf /var/lib/apt/lists/*

WORKDIR /app
RUN useradd --create-home app

COPY --from=build --chown=app:app /app/_build/prod/rel/drone_feed ./
COPY --chmod=755 scripts/mux_to_stanag.py scripts/extract_klv_track.py /app/scripts/
COPY --chmod=755 deploy/entrypoint.sh /app/entrypoint.sh
# Start as root so entrypoint can chown the storage volume, then runuser → app.

ENV HOME=/app
ENV MIX_ENV=prod
ENV PHX_SERVER=true
ENV MUX_SCRIPT=/app/scripts/mux_to_stanag.py
ENV EXTRACT_KLV_SCRIPT=/app/scripts/extract_klv_track.py
ENV PYTHON_PATH=python3

EXPOSE 4000

CMD ["/app/entrypoint.sh"]
